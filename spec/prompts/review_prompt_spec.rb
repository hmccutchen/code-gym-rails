require "rails_helper"

RSpec.describe ReviewPrompt do
  let(:long) { "The loop loads each order's user separately, so the page runs one query per order; preload users first." }
  let(:day_a) do
    [ { key: "code_review", rung: "senior",
        section: { "question" => "What is wrong here?", "snippet" => "Order.all.each { |o| o.user.name }", "concept" => "n_plus_one", "pitched_at" => "senior" },
        answer: long, rating: "right_level" },
      { key: "design_comparison", rung: "junior",
        section: { "title" => "Rates", "scenario" => "A rates file read nightly.", "question" => "Which would you ship?",
                   "piece_a" => "a", "piece_b" => "b", "concept" => "information_hiding",
                   "answer_key" => { "better" => "b", "deciding_fact" => "The rates file format changes every quarter.",
                                     "principle" => "information_hiding", "why_other_fails" => "A spreads the format across every caller." } },
        answer: ExerciseSection::DesignComparison.encode_answer("b", "The rates file format changes, and B hides it behind one reader."),
        rating: nil },
      { key: "pattern", rung: "junior",
        section: { "title" => "Memoize", "question" => "When would you cache this?", "concept" => "memoization" },
        answer: long, rating: "too_easy" },
      { key: "parsons_problem", rung: "junior",
        section: { "title" => "Order", "question" => "Put these in order.", "blocks" => %w[a b c], "concept" => "guard_clauses", "pitched_at" => "junior" },
        answer: "order:0,2,1", rating: "too_hard" } ]
  end

  def day_sections(entries) = entries.map { |entry| entry.slice(:key, :section, :answer, :rating).merge(section: entry[:section].merge("rounds" => {})) }

  it "shares every kind's composed baseline with generation, in grading and unanswered walkthroughs at every rung" do
    ExerciseSection.all.product(KindDifficulty::LEVELS).each do |kind, rung|
      section = { "blocks" => %w[a b c] }
      definition = kind.difficulty_definition(rung: rung, section: section)
      generated = GenerationPrompt::DifficultyGuidance.render(rungs: { kind => rung }, difficulty: KindDifficulty.none, ladders: {})
      graded = described_class.section_prompt(key: kind.key, section: section, answer: long, rung: rung)
      walked = described_class.walkthrough_prompt(key: kind.key, section: section, rung: rung)

      expect([ generated, graded, walked ]).to all(include(definition.standard, definition.expectation)), "#{kind.key}/#{rung}"
      expect([ graded, walked ]).to all(include("Pitched at: #{rung} — #{definition}"))
    end
  end

  it "keeps principal bug hunts bounded in both review paths and reads no hidden key to choose the definition" do
    section = { "purpose" => "Sum all prices.", "snippet" => "prices.sum", "answer_key" => { "issue" => "SECRET_KEY" } }
    definition = ExerciseSection::CodeReview.difficulty_definition(rung: "principal_engineer", mode: :bug_hunt)
    graded = described_class.section_prompt(key: "code_review", section: section, answer: long, rung: "principal_engineer")
    walked = described_class.walkthrough_prompt(key: "code_review", section: section, rung: "principal_engineer")

    expect([ graded, walked ]).to all(include(definition.to_s))
    [ graded, walked ].each { |text| expect(text).not_to include("system scale", "SECRET_KEY") }
  end

  it "describes the task without telling a reviewer to pitch it or conceal missed ambiguities", :aggregate_failures do
    [ [ "pattern", "mid_level", {} ], [ "ambiguity_hunt", "junior", {} ],
      [ "code_review", "principal_engineer", { "purpose" => "Remove even numbers." } ] ].each do |key, rung, section|
      graded = described_class.section_prompt(key: key, section: section, answer: long, rung: rung)
      walked = described_class.walkthrough_prompt(key: key, section: section, rung: rung)

      [ graded, walked ].each do |text|
        expect(text).not_to include("Keep the pattern named", "Pitch it so", "without hinting at its answers", "keep the full planted set")
      end
    end
  end

  it "renders a keyed section's review exactly as it renders the same section without its key, for every kind that plants one" do
    ExerciseSection.all.select(&:planted_key?).each do |kind|
      keyed = FakeService::EXERCISE_PROBLEM_SET.fetch(kind.key).deep_dup.merge("rounds" => {})
      keyless = keyed.except("answer_key")
      render = lambda do |section|
        [ described_class.day_system(coach: "Rails", sections: [ { key: kind.key, section: section, answer: long, rating: "right_level" } ]),
          described_class.section_prompt(key: kind.key, section: section, answer: long, rung: "senior"),
          described_class.walkthrough_prompt(key: kind.key, section: section, rung: "senior") ]
      end

      expect(render.call(keyed)).to eq(render.call(keyless)), "#{kind.key} changed its review once keyed"
    end
  end

  it "renders a four-section day's system prompt exactly as recorded" do
    expect_prompt_snapshot("review__day_a__system", described_class.day_system(coach: "Rails", sections: day_sections(day_a)))
  end

  it "renders each section's prompt exactly as recorded, at the rung it is handed" do
    day_a.each do |entry|
      prompt = described_class.section_prompt(key: entry[:key], section: entry[:section], answer: entry[:answer], rung: entry[:rung])

      expect_prompt_snapshot("review__day_a__#{entry[:key]}__prompt", prompt)
    end
  end

  it "renders a one-section day, which names no other section, exactly as recorded" do
    section = { "question" => "What breaks?", "snippet" => "items.map(i => fetch(i))", "concept" => "n_plus_one", "pitched_at" => "mid_level" }

    expect_prompt_snapshot("review__day_b__system",
                           described_class.day_system(coach: "JavaScript/React",
                                                      sections: [ { key: "code_review", section: section.merge("rounds" => {}), answer: nil, rating: nil } ]))
    expect_prompt_snapshot("review__day_b__code_review__prompt",
                           described_class.section_prompt(key: "code_review", section: section, answer: nil, rung: "mid_level"))
  end

  describe "the approach paragraph" do
    let(:start_line) { "how an experienced engineer would start on this kind of problem" }
    let(:walkthrough_section) { day_a.first[:section] }

    def recorded(name) = File.read(PromptSnapshotHelpers::PROMPT_SNAPSHOT_DIR.join("#{name}.txt"))

    it "renders the baseline snapshots byte for byte when approach is off" do
      day_a.each do |entry|
        args = { key: entry[:key], section: entry[:section], answer: entry[:answer], rung: entry[:rung] }
        today = recorded("review__day_a__#{entry[:key]}__prompt")

        expect(described_class.section_prompt(**args, approach: false)).to eq(today), entry[:key]
        expect(described_class.section_prompt(**args)).to eq(today), entry[:key]
      end
      expect(described_class.walkthrough_prompt(key: "code_review", section: walkthrough_section, rung: "senior", approach: false))
        .to eq(recorded("review__day_a__code_review__walkthrough_nothing_written"))
    end

    it "asks for the approach paragraph on a graded section when approach is on" do
      entry = day_a.first
      prompt = described_class.section_prompt(key: entry[:key], section: entry[:section], answer: entry[:answer], rung: entry[:rung], approach: true)

      expect(prompt).to include(start_line, "where this answer followed that start and where it did not")
      expect(prompt).not_to include(%("next_step": string — one specific thing to study))
      expect_prompt_snapshot("review__day_a__code_review__approach__prompt", prompt)
    end

    it "asks a walkthrough for the approach without mentioning an answer" do
      prompt = described_class.walkthrough_prompt(key: "code_review", section: walkthrough_section, rung: "senior", approach: true)

      expect(prompt).to include(start_line)
      expect(prompt).not_to include("this answer")
      expect_prompt_snapshot("review__day_a__code_review__approach__walkthrough", prompt)
    end

    it "passes approach through for_section to both shapes" do
      entry = day_a.first
      graded = described_class.for_section(key: entry[:key], section: entry[:section], answer: entry[:answer], answered: true, rung: "senior", approach: true)
      walked = described_class.for_section(key: entry[:key], section: entry[:section], answer: nil, answered: false, rung: "senior", approach: true)

      expect([ graded, walked ]).to all(include(start_line))
    end

    it "never reads the environment, so the switch is a value it is handed" do
      expect(File.read(Rails.root.join("app/prompts/review_prompt.rb"))).not_to include("ENV")
    end
  end

  describe "the miss reason" do
    let(:opted_in) { %w[challenge architecture pattern ambiguity_hunt pseudocode_to_code] }

    def fake_section(key) = FakeService::EXERCISE_PROBLEM_SET.fetch(key).deep_dup.merge("rounds" => {})

    let(:opening) { %(In each "missed" entry, after naming the gap) }

    def recorded(name) = File.read(PromptSnapshotHelpers::PROMPT_SNAPSHOT_DIR.join("#{name}.txt"))

    def graded(key, section: fake_section(key), **switches)
      described_class.section_prompt(key: key, section: section, answer: long, rung: "mid_level", **switches)
    end

    it "records the graded prompt as it is today for each opted-in kind with no other recorded one" do
      %w[challenge architecture ambiguity_hunt].each do |key|
        expect_prompt_snapshot("review__#{key}__prompt",
                               described_class.section_prompt(key: key, section: fake_section(key), answer: long, rung: "mid_level"))
      end
    end

    it "renders each opted-in kind's graded prompt byte for byte as recorded when why is off" do
      { "challenge" => "review__challenge__prompt", "architecture" => "review__architecture__prompt",
        "pattern" => "review__pattern__improved_code__prompt", "ambiguity_hunt" => "review__ambiguity_hunt__prompt",
        "pseudocode_to_code" => "review__pseudocode_to_code__improved_code__prompt" }.each do |key, name|
        expect(graded(key, why: false)).to eq(recorded(name)), key
        expect(graded(key)).to eq(recorded(name)), key
      end
      pattern = day_a.find { |entry| entry[:key] == "pattern" }
      expect(described_class.section_prompt(key: "pattern", section: pattern[:section], answer: pattern[:answer], rung: pattern[:rung], why: false))
        .to eq(recorded("review__day_a__pattern__prompt"))
    end

    it "renders each opted-in kind's graded prompt exactly as recorded when why is on" do
      opted_in.each do |key|
        expect_prompt_snapshot("review__#{key}__miss_reason__prompt", graded(key, why: true))
      end
    end

    it "opts in only challenge, architecture, pattern, ambiguity_hunt and pseudocode_to_code" do
      expect(ExerciseSection.all.select(&:miss_reason).map(&:key)).to match_array(opted_in)
    end

    it "puts the kind's line right after its grading note only when why is on and the kind opts in, for every kind" do
      ExerciseSection.all.each do |kind|
        section = fake_section(kind.key)
        note = kind.grading_note(section: section, answer: long)
        on = graded(kind.key, section: section, why: true)

        expect(graded(kind.key, section: section, why: false)).not_to include(opening), kind.key
        if opted_in.include?(kind.key)
          line = format(described_class::MISS_REASON, reason: kind.miss_reason)
          expect(on).to include("#{note}\n#{line}\n\n"), kind.key
          expect(on.scan(opening).size).to eq(1), kind.key
        else
          expect(on).not_to include(opening), kind.key
        end
      end
    end

    it "never asks a walkthrough for a reason, for any kind" do
      ExerciseSection.all.each do |kind|
        walked = described_class.for_section(key: kind.key, section: fake_section(kind.key), answer: nil, answered: false, rung: "senior", why: true)

        expect(walked).not_to include(opening), kind.key
        expect(walked).to eq(described_class.walkthrough_prompt(key: kind.key, section: fake_section(kind.key), rung: "senior")), kind.key
      end
    end

    it "passes why through for_section to the graded prompt" do
      prompt = described_class.for_section(key: "challenge", section: fake_section("challenge"), answer: long, answered: true, rung: "mid_level", why: true)

      expect(prompt).to eq(graded("challenge", why: true))
    end

    it "fills in the kind's reason where the shared line leaves a place for it" do
      opted_in.each do |key|
        expect(graded(key, why: true)).to include("why it matters for this problem: #{ExerciseSection.for(key).miss_reason}. This is your reasoning"), key
      end
    end

    it "shows each kind's own key text exactly as often with why on as off, and none where the grader isn't shown it" do
      planted = "PLANTED_KEY_TEXT_7f3a"
      opted_in.each do |key|
        kind = ExerciseSection.for(key)
        keyed = kind.answer_key_fields.excluding("answer_key").index_with { [ planted ] }
        section = fake_section(key).merge("answer_key" => { "issue" => planted, "missable_requirements" => [ planted ] }, **keyed)
        render = lambda do |why|
          [ described_class.day_system(coach: "Rails", sections: [ { key: key, section: section, answer: long, rating: "right_level" } ]),
            graded(key, section: section, why: why) ].join("\n").scan(planted).size
        end

        expect(render.call(true)).to eq(render.call(false)), key
        expect(render.call(false)).to(key == "ambiguity_hunt" ? be >= 1 : eq(0), key)
      end
    end

    it "names no key field in the shared line or any kind's reason" do
      fields = Regexp.union(ExerciseSection.all_answer_key_fields + %w[answer_key missable planted])
      texts = { "shared" => described_class::MISS_REASON }.merge(opted_in.index_with { |key| ExerciseSection.for(key).miss_reason })
      texts.each do |name, text|
        checked = name == "ambiguity_hunt" ? text.sub("planted ambiguity they missed", "") : text
        expect(checked).not_to match(/#{fields}/i), name
      end
    end

    it "forbids architecture's reason from naming a right option" do
      expect(ExerciseSection::Architecture.miss_reason)
        .to include("There is no single correct option, so never give 'it didn't pick option X' as the reason")
    end

    it "forbids pattern's reason from naming a pattern" do
      expect(ExerciseSection::Pattern.miss_reason).to include("Never give 'it isn't the named pattern' as the reason")
    end

    it "limits ambiguity_hunt's reason to a planted ambiguity they missed" do
      expect(ExerciseSection::AmbiguityHunt.miss_reason).to include("Give this reason only for a planted ambiguity they missed")
    end

    it "ties pseudocode_to_code's reason to the plan, never to the translated code's syntax" do
      expect(ExerciseSection::PseudocodeToCode.miss_reason).to include("Attribute it to the plan, never to the translated code's syntax")
    end

    it "never reads the environment, so the switch is a value it is handed" do
      expect(File.read(Rails.root.join("app/prompts/review_prompt.rb"))).not_to include("ENV", "ReviewMissReason")
    end
  end

  it "takes the rung as a value, so it never reads a user's difficulty settings" do
    expect(described_class.method(:section_prompt).parameters)
      .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :answer ], [ :keyreq, :rung ], [ :key, :approach ], [ :key, :why ] ])
  end

  describe ".walkthrough_prompt" do
    let(:section) { day_a.first[:section] }
    let(:nothing_written) { described_class.walkthrough_prompt(key: "code_review", section: section, rung: "senior") }

    it "takes the rung as a value and no answer text, since a section with any written answer is graded instead" do
      expect(described_class.method(:walkthrough_prompt).parameters)
        .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :rung ], [ :key, :approach ] ])
    end

    it "says no answer was given and asks for no rating" do
      expect(nothing_written).to include("No answer was given", "must not be rated", "Pitched at: senior")
      expect(nothing_written).not_to include("\"rating\"", "essential_gaps", "<engineer_text>", "too short")
    end

    it "asks for every walkthrough field" do
      expect(nothing_written).to include("\"correct\"", "\"missed\"", "\"better_questions\"", "\"next_step\"", "\"improved_code\"")
    end

    it "tells the grader to return an empty correct array" do
      expect(nothing_written).to include("No answer was given for this section", "\"correct\" as an empty array")
    end

    it "carries no grading instruction for any section kind" do
      ExerciseSection.all.each do |kind|
        prompt = described_class.walkthrough_prompt(key: kind.key, section: { "blocks" => %w[a b c] }, rung: "junior")

        expect(prompt).not_to include("\"rating\"", "essential_gaps", "rubric", "Grade ", "out of place", "misplaced"), kind.key
        expect(prompt).not_to match(/rating|already scored|verified result/i), kind.key
      end
    end

    it "leaves no stray blank line for a kind with no walkthrough note" do
      prompt = described_class.walkthrough_prompt(key: "code_review", section: section, rung: "senior")

      expect(prompt).not_to include("\n\n\n")
    end

    context "for a parsons problem" do
      let(:blocks) { [ "total = 0", "items.each { |i| total += i }", "total" ] }
      let(:parsons) { described_class.walkthrough_prompt(key: "parsons_problem", section: { "blocks" => blocks }, rung: "junior") }

      it "lists every block in the correct order" do
        expect(parsons).to include("Correct blocks, in order: 1. total = 0 / 2. items.each { |i| total += i } / 3. total")
      end

      it "asks the grader to explain why each block belongs where it does" do
        expect(parsons).to include("Explain WHY each block belongs where it does", "dependency or logical reason")
      end

      it "says improved_code is empty once, through the shared fields" do
        expect(parsons.scan('"improved_code" must be an empty string').size + parsons.scan("must be an empty string for this section").size).to eq(1)
      end

      it "says the exercise data is unavailable when the exercise has no blocks" do
        prompt = described_class.walkthrough_prompt(key: "parsons_problem", section: {}, rung: "junior")

        expect(prompt).to include("exercise data is unavailable")
        expect(prompt).not_to include("Correct blocks")
      end

      it "renders exactly as recorded" do
        expect_prompt_snapshot("review__parsons__walkthrough_nothing_written", parsons)
      end
    end

    it "renders exactly as recorded" do
      expect_prompt_snapshot("review__day_a__code_review__walkthrough_nothing_written", nothing_written)
    end
  end

  describe ".for_section" do
    let(:entry) { day_a.first }

    def prompt_for(answered:)
      described_class.for_section(key: entry[:key], section: entry[:section], answer: entry[:answer], answered: answered, rung: entry[:rung])
    end

    it "grades an answered section with the section prompt" do
      expect(prompt_for(answered: true))
        .to eq(described_class.section_prompt(key: entry[:key], section: entry[:section], answer: entry[:answer], rung: entry[:rung]))
    end

    it "walks through an unanswered section, whatever answer text it is handed" do
      expect(prompt_for(answered: false))
        .to eq(described_class.walkthrough_prompt(key: entry[:key], section: entry[:section], rung: entry[:rung]))
    end

    it "takes the answer state as a value, so it never reads a response" do
      expect(described_class.method(:for_section).parameters)
        .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :answer ], [ :keyreq, :answered ], [ :keyreq, :rung ], [ :key, :approach ], [ :key, :why ] ])
    end
  end

  it "puts each kind's own improved_code instruction on the field line, whether graded or walked through" do
    ExerciseSection.all.each do |kind|
      section = { "blocks" => %w[a b] }
      graded = described_class.section_prompt(key: kind.key, section: section, answer: "order:0,1", rung: "senior")
      walked = described_class.walkthrough_prompt(key: kind.key, section: section, rung: "senior")

      expect(graded).to include(%(- "improved_code": string — #{kind.improved_code_instruction(section: section, answered: true)}\n)), kind.key
      expect(walked).to include(%(- "improved_code": string — #{kind.improved_code_instruction(section: section, answered: false)}\n)), kind.key
    end
  end

  describe "the kinds whose improved_code wording depends on whether they answered" do
    %w[pattern plan_review pseudocode_to_code].each do |key|
      it "renders #{key}'s graded prompt and walkthrough exactly as recorded" do
        section = FakeService::EXERCISE_PROBLEM_SET.fetch(key).deep_dup.merge("rounds" => {})

        expect_prompt_snapshot("review__#{key}__improved_code__prompt",
                               described_class.section_prompt(key: key, section: section, answer: long, rung: "mid_level"))
        expect_prompt_snapshot("review__#{key}__improved_code__walkthrough",
                               described_class.walkthrough_prompt(key: key, section: section, rung: "mid_level"))
      end
    end
  end

  describe "a multi-file code review" do
    let(:files) do
      { "question" => "What breaks?",
        "file_1_path" => "app/models/order.rb", "file_1_code" => "def total\n  0\nend", "file_1_changed_lines" => [ 2 ],
        "file_2_path" => "app/models/line_item.rb", "file_2_code" => "def price\n  0\nend", "file_2_changed_lines" => [] }
    end
    let(:graded) { described_class.section_prompt(key: "code_review", section: files, answer: long, rung: "senior") }
    let(:walked) { described_class.walkthrough_prompt(key: "code_review", section: files, rung: "senior") }

    it "asks for each changed file's improved code under a File: line, whether graded or walked through" do
      [ graded, walked ].each do |prompt|
        expect(prompt).to include(%(start each changed file's part with a line "File: <path>"))
      end
    end

    it "renders exactly as recorded" do
      expect_prompt_snapshot("review__code_review_multi_file__prompt", graded)
      expect_prompt_snapshot("review__code_review_multi_file__walkthrough", walked)
    end

    it "leaves a single-file section's prompts without the File: line" do
      single = day_a.first[:section]

      expect(described_class.section_prompt(key: "code_review", section: single, answer: long, rung: "senior")).not_to include("File: <path>")
      expect(described_class.walkthrough_prompt(key: "code_review", section: single, rung: "senior")).not_to include("File: <path>")
    end
  end
end

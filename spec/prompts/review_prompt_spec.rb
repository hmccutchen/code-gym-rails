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

  it "takes the rung as a value, so it never reads a user's difficulty settings" do
    expect(described_class.method(:section_prompt).parameters)
      .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :answer ], [ :keyreq, :rung ] ])
  end

  describe ".walkthrough_prompt" do
    let(:section) { day_a.first[:section] }
    let(:nothing_written) { described_class.walkthrough_prompt(key: "code_review", section: section, rung: "senior") }

    it "takes the rung as a value and no answer text, since a section with any written answer is graded instead" do
      expect(described_class.method(:walkthrough_prompt).parameters)
        .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :rung ] ])
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
        .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :answer ], [ :keyreq, :answered ], [ :keyreq, :rung ] ])
    end
  end
end

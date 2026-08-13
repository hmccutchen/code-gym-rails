require "rails_helper"

RSpec.describe ExerciseSection do
  describe ".keys" do
    it "lists every section kind in the order the app has always enumerated them" do
      expect(described_class.keys).to eq(%w[
        code_review pattern challenge architecture security_review parsons_problem
        plan_review ambiguity_hunt
      ])
    end
  end

  describe ".find" do
    it "resolves a key to its section kind" do
      expect(described_class.find("architecture")).to eq(ExerciseSection::Architecture)
      expect(described_class.find(:security_review)).to eq(ExerciseSection::SecurityReview)
    end

    # A provider can put arbitrary keys in a jsonb payload, so callers get nil
    # to decide on rather than an exception.
    it "returns nil for a key outside the closed set" do
      expect(described_class.find("bogus")).to be_nil
    end
  end

  describe ".thirds" do
    # Precedence, not enumeration order — DailyExercise#third_key relies on
    # architecture winning over security_review over challenge.
    it "lists the third-slot kinds in resolution precedence order" do
      expect(described_class.thirds.map(&:key)).to eq(%w[architecture security_review challenge parsons_problem])
    end

    it "marks only the third-slot kinds as third?" do
      expect(described_class.find("code_review").third?).to be(false)
      expect(described_class.find("pattern").third?).to be(false)
      expect(described_class.find("challenge").third?).to be(true)
      expect(described_class.find("architecture").third?).to be(true)
      expect(described_class.find("security_review").third?).to be(true)
      expect(described_class.find("parsons_problem").third?).to be(true)
    end

    it "covers every third kind with a roll weight, so the two can't drift apart" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS.keys.map(&:to_s)).to match_array(described_class.thirds.map(&:key))
    end
  end

  describe ".fourths" do
    it "lists the fourth-slot kinds" do
      expect(described_class.fourths).to eq([ ExerciseSection::PlanReview, ExerciseSection::AmbiguityHunt ])
    end

    it "marks only the fourth-slot kinds as fourth?" do
      expect(described_class.find("code_review").fourth?).to be(false)
      expect(described_class.find("challenge").fourth?).to be(false)
      expect(described_class.find("plan_review").fourth?).to be(true)
      expect(described_class.find("ambiguity_hunt").fourth?).to be(true)
    end

    it "covers every fourth kind with a roll weight, so the two can't drift apart" do
      expect(DailyPlan::FOURTH_SECTION_WEIGHTS.keys.map(&:to_s)).to match_array(described_class.fourths.map(&:key))
    end
  end

  describe ".vocabulary_key" do
    it "sends architecture to the language-independent vocabulary" do
      expect(described_class.find("architecture").vocabulary_key).to eq(:architecture)
    end

    it "restricts security_review to the security subset" do
      expect(described_class.find("security_review").vocabulary_key).to eq(:security_concepts)
    end

    it "sends every other kind to the day's full language vocabulary" do
      %w[code_review pattern challenge parsons_problem].each do |key|
        expect(described_class.find(key).vocabulary_key).to eq(:concepts)
      end
    end

    it "sends plan_review to its own vocabulary" do
      expect(described_class.find("plan_review").vocabulary_key).to eq(:plan_review)
    end

    it "sends ambiguity_hunt to its own vocabulary" do
      expect(described_class.find("ambiguity_hunt").vocabulary_key).to eq(:ambiguity_hunt)
    end
  end

  describe ".improved_code?" do
    it "excludes architecture, whose review has no single corrected form" do
      expect(described_class.find("architecture").improved_code?).to be(false)
    end

    it "excludes parsons_problem, whose correct order is already the answer" do
      expect(described_class.find("parsons_problem").improved_code?).to be(false)
    end

    it "excludes ambiguity_hunt, which has no corrected form" do
      expect(described_class.find("ambiguity_hunt").improved_code?).to be(false)
    end

    it "allows plan_review to carry a revised plan" do
      expect(described_class.find("plan_review").improved_code?).to be(true)
    end

    it "allows every other kind to carry corrected code" do
      %w[code_review pattern challenge security_review].each do |key|
        expect(described_class.find(key).improved_code?).to be(true)
      end
    end
  end

  describe ".improved_code_label / .improved_code_prose?" do
    it "describes plan_review's improvement as a revised plan rendered as prose" do
      kind = described_class.find("plan_review")
      expect(kind.improved_code_label).to eq("Revised plan")
      expect(kind.improved_code_prose?).to be(true)
    end

    it "leaves every code-bearing kind as syntax-highlighted improved code" do
      %w[code_review pattern challenge security_review].each do |key|
        kind = described_class.find(key)
        expect(kind.improved_code_label).to eq("Improved code")
        expect(kind.improved_code_prose?).to be(false)
      end
    end
  end

  describe ".for" do
    it "resolves a known key to its kind" do
      expect(described_class.for("plan_review")).to eq(ExerciseSection::PlanReview)
    end

    # A provider can put an arbitrary key in a jsonb payload; a view reading a
    # facet off it wants the default, not a nil to guard.
    it "falls back to the base class's defaults for an unrecognized key" do
      expect(described_class.for("invented_by_a_provider").improved_code_label).to eq("Improved code")
      expect(described_class.for("invented_by_a_provider").improved_code_prose?).to be(false)
    end
  end

  describe ".diagrammable?" do
    # code_review, pattern, and challenge all describe a structure in prose or
    # in code already on screen, so a diagram of it restates what is visible.
    it "marks the kinds whose scenario carries a structure worth diagramming" do
      expect(described_class.find("code_review").diagrammable?).to be(true)
      expect(described_class.find("pattern").diagrammable?).to be(true)
      expect(described_class.find("challenge").diagrammable?).to be(true)
    end

    # security_review's task is finding one exploitable thing in a snippet, so
    # a diagram of that snippet's structure narrows the search. A parsons
    # problem's blocks ARE the structure — diagramming them is the answer.
    # Architecture already carries a diagram inside its reference block.
    it "excludes the kinds where a diagram would narrow the search or be the answer" do
      expect(described_class.find("security_review").diagrammable?).to be(false)
      expect(described_class.find("parsons_problem").diagrammable?).to be(false)
      expect(described_class.find("architecture").diagrammable?).to be(false)
    end

    it "excludes plan_review and ambiguity_hunt, where a diagram would restate prose or hint at the answer" do
      expect(described_class.find("plan_review").diagrammable?).to be(false)
      expect(described_class.find("ambiguity_hunt").diagrammable?).to be(false)
    end
  end

  describe ExerciseSection::ParsonsProblem do
    describe ".parse_order" do
      it "parses the order: prefix into 0-based integer ids" do
        expect(ExerciseSection::ParsonsProblem.parse_order("order:2,0,4,1,3")).to eq([ 2, 0, 4, 1, 3 ])
      end

      it "returns an empty array for a blank answer" do
        expect(ExerciseSection::ParsonsProblem.parse_order("")).to eq([])
        expect(ExerciseSection::ParsonsProblem.parse_order(nil)).to eq([])
      end

      it "returns an empty array for a malformed answer missing the prefix" do
        expect(ExerciseSection::ParsonsProblem.parse_order("2,0,4,1,3")).to eq([])
      end

      it "drops non-integer segments rather than raising" do
        expect(ExerciseSection::ParsonsProblem.parse_order("order:2,x,4")).to eq([ 2, 4 ])
      end
    end

    describe ".grade" do
      it "rates an exact match as strong with zero mismatches" do
        expect(ExerciseSection::ParsonsProblem.grade([ 0, 1, 2, 3, 4 ], 5)).to eq(mismatches: 0, rating: "strong")
      end

      it "rates a single adjacent swap (2 mismatches) as solid" do
        expect(ExerciseSection::ParsonsProblem.grade([ 1, 0, 2, 3, 4 ], 5)).to eq(mismatches: 2, rating: "solid")
      end

      it "rates a 3-cycle (3 mismatches, within half of 6) as developing" do
        expect(ExerciseSection::ParsonsProblem.grade([ 1, 2, 0, 3, 4, 5 ], 6)).to eq(mismatches: 3, rating: "developing")
      end

      it "rates more than half the blocks misplaced as beginner" do
        # A 5-element reversal leaves the middle block in place, so 4 of 5 move.
        expect(ExerciseSection::ParsonsProblem.grade([ 4, 3, 2, 1, 0 ], 5)).to eq(mismatches: 4, rating: "beginner")
      end

      it "treats a fully blank/skipped submission as fully mismatched" do
        expect(ExerciseSection::ParsonsProblem.grade([], 5)).to eq(mismatches: 5, rating: "beginner")
      end

      it "treats an out-of-range or short submission as mismatched for the missing positions" do
        expect(ExerciseSection::ParsonsProblem.grade([ 0, 1 ], 5)).to eq(mismatches: 3, rating: "developing")
      end
    end

    describe ".normalize_order" do
      it "accepts a complete permutation" do
        expect(ExerciseSection::ParsonsProblem.normalize_order([ 2, 0, 1 ], 3)).to eq([ 2, 0, 1 ])
      end

      it "rejects duplicate ids" do
        expect(ExerciseSection::ParsonsProblem.normalize_order([ 0, 0, 0 ], 3)).to eq([])
      end

      it "rejects negative ids, which would otherwise wrap around the block list" do
        expect(ExerciseSection::ParsonsProblem.normalize_order([ -1, 0, 1 ], 3)).to eq([])
      end

      it "rejects ids past the end of the block list" do
        expect(ExerciseSection::ParsonsProblem.normalize_order([ 0, 1, 9 ], 3)).to eq([])
      end

      it "rejects an incomplete order" do
        expect(ExerciseSection::ParsonsProblem.normalize_order([ 0, 1 ], 3)).to eq([])
      end
    end

    describe ".initial_order" do
      it "prefers the learner's saved order" do
        order = ExerciseSection::ParsonsProblem.initial_order(
          answer: "order:2,0,1", display_order: [ 1, 2, 0 ], block_count: 3
        )
        expect(order).to eq([ 2, 0, 1 ])
      end

      it "falls back to the generated scramble when the saved order is corrupted" do
        order = ExerciseSection::ParsonsProblem.initial_order(
          answer: "order:0,0,0", display_order: [ 1, 2, 0 ], block_count: 3
        )
        expect(order).to eq([ 1, 2, 0 ])
      end

      it "falls back to the stored order when neither candidate is a full permutation" do
        order = ExerciseSection::ParsonsProblem.initial_order(
          answer: "order:9,9", display_order: [ 0, 1 ], block_count: 3
        )
        expect(order).to eq([ 0, 1, 2 ])
      end
    end

    describe ".valid_id?" do
      it "accepts only in-range integers" do
        expect(ExerciseSection::ParsonsProblem.valid_id?(0, 3)).to be true
        expect(ExerciseSection::ParsonsProblem.valid_id?(2, 3)).to be true
      end

      it "rejects nil, negative, and out-of-range ids" do
        expect(ExerciseSection::ParsonsProblem.valid_id?(nil, 3)).to be false
        expect(ExerciseSection::ParsonsProblem.valid_id?(-1, 3)).to be false
        expect(ExerciseSection::ParsonsProblem.valid_id?(3, 3)).to be false
      end
    end
  end

  describe "answer scaffolds" do
    it "scaffolds pattern, architecture, and plan_review" do
      expect(ExerciseSection.all.select(&:scaffolded?))
        .to contain_exactly(ExerciseSection::Pattern, ExerciseSection::Architecture, ExerciseSection::PlanReview)
    end

    describe ".scaffold_labels" do
      it "prefers the labels the generator wrote for this problem" do
        data = { "answer_scaffold" => [ "Which cache, and why:", "How you'd invalidate it:" ] }
        expect(ExerciseSection::Architecture.scaffold_labels(data))
          .to eq([ "Which cache, and why:", "How you'd invalidate it:" ])
      end

      # Every pre-scaffold row takes this path, so it is the common case, not
      # an edge case.
      it "falls back to the kind's default when the problem carries none" do
        expect(ExerciseSection::Architecture.scaffold_labels({ "question" => "q" }))
          .to eq(ExerciseSection::Architecture::DEFAULT_SCAFFOLD)
        expect(ExerciseSection::Pattern.scaffold_labels(nil))
          .to eq(ExerciseSection::Pattern::DEFAULT_SCAFFOLD)
      end

      it "falls back when the provider returns an unusable shape" do
        [ "not an array", [], [ "", "   " ], [ nil ], 42 ].each do |bad|
          expect(ExerciseSection::Pattern.scaffold_labels({ "answer_scaffold" => bad }))
            .to eq(ExerciseSection::Pattern::DEFAULT_SCAFFOLD)
        end
      end

      it "never scaffolds an unscaffolded kind, even if a scaffold is present" do
        expect(ExerciseSection::CodeReview.scaffold_labels({ "answer_scaffold" => [ "Nope:" ] })).to eq([])
      end
    end

    describe ".normalize_scaffold" do
      it "strips labels and drops blanks" do
        expect(ExerciseSection::Pattern.normalize_scaffold([ "  A:  ", "", nil, "B:" ])).to eq([ "A:", "B:" ])
      end

      # Dropped, not coerced: to_s would turn 42 into the label "42" and a Hash
      # into its inspect output, both of which read as a real scaffold downstream.
      it "drops non-string elements rather than stringifying them" do
        expect(ExerciseSection::Pattern.normalize_scaffold([ 42, { "a" => 1 }, [ "B:" ], "A:" ]))
          .to eq([ "A:" ])
      end

      it "drops a scaffold made entirely of non-strings" do
        expect(ExerciseSection::Pattern.normalize_scaffold([ 42, true ])).to eq([])
      end

      it "caps the number of labels" do
        expect(ExerciseSection::Pattern.normalize_scaffold((1..10).map { |i| "L#{i}:" }).size)
          .to eq(ExerciseSection::MAX_SCAFFOLD_LABELS)
      end

      it "truncates a label the model let run long" do
        long = ExerciseSection::Pattern.normalize_scaffold([ "x" * 300 ]).first
        expect(long.length).to eq(ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH)
      end
    end

    describe ".scaffold_template" do
      it "lays out the day's labels with room to write under each" do
        data = { "answer_scaffold" => [ "First:", "Second:" ] }
        expect(ExerciseSection::Pattern.scaffold_template(data)).to eq("First:\n\n\nSecond:\n")
      end

      it "is nil for an unscaffolded kind" do
        expect(ExerciseSection::CodeReview.scaffold_template({ "question" => "q" })).to be_nil
      end
    end

    describe ".substantive_answer" do
      let(:data) { { "answer_scaffold" => [ "Which option, and why:", "Tradeoffs you considered:" ] } }

      it "returns the whole stripped answer for an unscaffolded kind" do
        expect(ExerciseSection::CodeReview.substantive_answer("  the N+1 is in the loop  ", nil))
          .to eq("the N+1 is in the loop")
      end

      it "removes untouched labels so only what the user typed is measured" do
        filled = "Which option, and why:\nOption B\n\nTradeoffs you considered:\nSlower writes\n"
        expect(ExerciseSection::Architecture.substantive_answer(filled, data)).to eq("Option B\n\nSlower writes")
      end

      it "is empty for a pristine scaffold" do
        template = ExerciseSection::Architecture.scaffold_template(data)
        expect(ExerciseSection::Architecture.substantive_answer(template, data)).to eq("")
      end

      it "strips this problem's labels, not the kind's defaults" do
        today    = { "answer_scaffold" => [ "Which cache, and why:", "How you'd invalidate it:" ] }
        pristine = ExerciseSection::Architecture.scaffold_template(today)

        expect(ExerciseSection::Architecture.substantive_answer(pristine, today)).to eq("")
        expect(ExerciseSection::Architecture.substantive_answer(pristine, nil)).to eq(pristine.strip)
      end

      it "keeps everything when the user deleted the scaffold and free-typed" do
        expect(ExerciseSection::Pattern.substantive_answer("I would use a registry object", nil))
          .to eq("I would use a registry object")
      end

      # Matching whole lines, not substrings, is what makes an edited label the
      # user's own text rather than scaffolding to discard.
      it "keeps a label the user edited, and indentation the user added" do
        expect(ExerciseSection::Architecture.substantive_answer("Which option, and why: B\n  indented", data))
          .to eq("Which option, and why: B\n  indented")
      end

      it "ignores surrounding whitespace when matching a label" do
        expect(ExerciseSection::Architecture.substantive_answer("   Which option, and why:   \nB", data)).to eq("B")
      end

      it "treats nil as empty" do
        expect(ExerciseSection::Pattern.substantive_answer(nil, nil)).to eq("")
      end
    end
  end

  describe ".for_plan" do
    it "returns the day's kinds in slot order" do
      expect(ExerciseSection.for_plan(third: :architecture, fourth: :ambiguity_hunt))
        .to eq([ ExerciseSection::CodeReview, ExerciseSection::Pattern,
                 ExerciseSection::Architecture, ExerciseSection::AmbiguityHunt ])
    end

    it "accepts the symbols DailyPlan rolls" do
      DailyPlan::THIRD_SECTION_WEIGHTS.each_key do |third|
        DailyPlan::FOURTH_SECTION_WEIGHTS.each_key do |fourth|
          expect(ExerciseSection.for_plan(third: third, fourth: fourth).map(&:key))
            .to eq([ "code_review", "pattern", third.to_s, fourth.to_s ])
        end
      end
    end

    # A set silently missing a section is worse than a failed generation the
    # user can retry, so an ineligible roll raises rather than resolving to nil.
    it "refuses a kind rolled into a slot it cannot occupy" do
      expect { ExerciseSection.for_plan(third: :plan_review, fourth: :plan_review) }
        .to raise_error(ArgumentError, /plan_review is not one of/)
      expect { ExerciseSection.for_plan(third: :challenge, fourth: :challenge) }
        .to raise_error(ArgumentError, /challenge is not one of/)
    end
  end

  describe ".schema_fragment" do
    RUBY_LABEL = "Ruby/Rails".freeze
    JS_LABEL   = "JavaScript/React".freeze

    def parse(kind, label: RUBY_LABEL)
      JSON.parse("{#{kind.schema_fragment(label: label)}}").fetch(kind.key)
    end

    # Invariants every kind's fragment has to satisfy, asserted over .all rather
    # than kind by kind so a ninth kind inherits them without anyone having to
    # remember. These replace the cross-section counts that used to run against
    # the assembled schema (`scan('"scenario"').size == 4`), which could only
    # ever check the four kinds a given day happened to roll.
    shared_examples "a section kind's schema fragment" do |kind|
      it "is keyed by the kind's own key and parses as JSON" do
        expect(JSON.parse("{#{kind.schema_fragment(label: RUBY_LABEL)}}").keys).to eq([ kind.key ])
      end

      it "defines a teaching_note, a concept, and a scenario" do
        expect(parse(kind)).to include("teaching_note", "concept", "scenario")
      end

      # Catches a kind that hardcodes a language instead of interpolating the
      # label it was handed — invisible on a Rails day, wrong every JS day.
      it "names only the language it was given" do
        expect(parse(kind, label: JS_LABEL).to_s).not_to include(RUBY_LABEL)
        expect(parse(kind, label: RUBY_LABEL).to_s).not_to include(JS_LABEL)
      end

      it "asks for a diagram only when the kind is diagrammable" do
        expect(parse(kind).key?("diagram")).to eq(kind.diagrammable?)
      end

      it "asks for an answer_scaffold only when the kind is scaffolded" do
        expect(parse(kind).key?("answer_scaffold")).to eq(kind.scaffolded?)
      end

      # The glossary array was removed from the schema; a kind reintroducing one
      # would put an unrendered field back in every problem set.
      it "asks for no glossary array" do
        expect(parse(kind)).not_to have_key("glossary")
      end
    end

    ExerciseSection.all.each do |kind|
      context kind.key do
        it_behaves_like "a section kind's schema fragment", kind
      end
    end

    it "raises rather than silently omitting a section for a kind that defines none" do
      undefined_kind = Class.new(ExerciseSection)
      expect { undefined_kind.schema_fragment(label: RUBY_LABEL) }
        .to raise_error(NotImplementedError, /schema_fragment/)
    end

    describe ExerciseSection::CodeReview do
      # The snippet's language/framing is mode-specific (an RSpec-style test
      # file, a Prisma schema change, realistic Ruby/Rails code…), so the
      # fragment defers to the content_instruction line above it in the
      # prompt rather than restating a label here — restating it is what
      # made a JS schema-review day describe a Prisma schema as "JavaScript
      # code" (see #content_instruction). `label:` stays part of the
      # contract without appearing in this string.
      it "defers the snippet's language description to the guidance instruction" do
        expect(parse(described_class)["snippet"]).to eq("string — ~10-15 lines, matching the code_review snippet instruction above")
        expect(parse(described_class, label: JS_LABEL)["snippet"]).to eq("string — ~10-15 lines, matching the code_review snippet instruction above")
      end
    end

    describe ExerciseSection::Pattern do
      it "demands a self-contained question that references no snippet" do
        expect(parse(described_class)["question"]).to include("fully self-contained")
      end

      it "asks for no reference block" do
        expect(parse(described_class).keys).to contain_exactly(
          "title", "why", "question", "scenario", "teaching_note", "concept", "answer_scaffold", "diagram"
        )
      end
    end

    describe ExerciseSection::Challenge do
      it "asks for starter code" do
        expect(parse(described_class)).to have_key("starter_code")
      end
    end

    describe ExerciseSection::Architecture do
      it "asks for options and a tradeoffs-plural reference" do
        fragment = parse(described_class)
        expect(fragment).to have_key("options")
        expect(fragment["reference"]).to have_key("tradeoffs")
      end

      it "caps the scenario at 2-3 sentences and 2-3 constraints, with no team size" do
        scenario = parse(described_class)["scenario"]
        expect(scenario).to include("2-3 sentences", "2-3 concrete constraints")
        expect(scenario).not_to include("team size")
      end

      it "caps the question at one sentence" do
        expect(parse(described_class)["question"]).to include("ONE sentence")
      end

      # The one diagram this kind carries lives in its reference, not at the
      # top level — .diagrammable? is false and the shared example enforces that.
      it "asks for a Mermaid diagram inside the reference" do
        expect(parse(described_class)["reference"]["diagram"]).to match(/mermaid/i)
      end

      it "asks for no starter code" do
        expect(parse(described_class)).not_to have_key("starter_code")
      end
    end

    describe ExerciseSection::SecurityReview do
      it "asks for a vulnerable snippet and a mitigation question" do
        fragment = parse(described_class)
        expect(fragment["snippet"]).to include("exploitable vulnerability")
        expect(fragment["question"].downcase).to include("mitigate")
      end

      it "labels both the snippet and the reference's code example" do
        fragment = parse(described_class, label: JS_LABEL)
        expect(fragment["snippet"]).to include("#{JS_LABEL} code")
        expect(fragment["reference"]["code_example"]).to include("#{JS_LABEL} code")
      end

      it "shapes its reference like a normal concept reference, not architecture's" do
        expect(parse(described_class)["reference"].keys)
          .to contain_exactly("tagline", "explanation", "code_example", "senior_lens")
      end
    end

    describe ExerciseSection::ParsonsProblem do
      it "asks for blocks in the correct final order" do
        expect(parse(described_class)["blocks"].join(" ")).to match(/IN THE CORRECT FINAL ORDER/)
      end
    end

    describe ExerciseSection::PlanReview do
      it "asks for a plan excerpt carrying planted flaws" do
        expect(parse(described_class)["plan_excerpt"]).to include("planted flaws")
      end
    end

    describe ExerciseSection::AmbiguityHunt do
      it "asks for a vague request and exactly PLANTED_COUNT planted ambiguities" do
        fragment = parse(described_class)
        expect(fragment["request"]).to include("vague feature request")
        expect(fragment["planted_ambiguities"].join(" "))
          .to include("exactly #{ExerciseSection::AmbiguityHunt::PLANTED_COUNT} total")
      end
    end
  end

  describe ".generation_guidance" do
    RAILS_VOCAB = AiService::RAILS_CONCEPTS.freeze

    def guidance(kind, vocabulary:, label: "Ruby/Rails", mode: nil, artifact: nil, test_framework: nil)
      kind.generation_guidance(vocabulary: vocabulary, label: label, mode: mode,
                                artifact: artifact, test_framework: test_framework)
    end

    # The contract is uniform on purpose: AiService#generation_guidance_for
    # hands every kind the same context and never asks which kind it holds. A
    # kind that narrowed its signature to only what it reads would put that
    # branch back into the shared assembler — which is the thing "adding a
    # kind means adding a class, not editing shared code" rules out.
    it "is accepted by every kind with the full context the assembler passes" do
      ExerciseSection.all.each do |kind|
        expect { guidance(kind, vocabulary: RAILS_VOCAB, mode: :application_code,
                                 artifact: "a Rails migration", test_framework: "an RSpec-style") }
          .not_to raise_error, "#{kind} rejected the assembler's context"
      end
    end

    describe ExerciseSection::CodeReview do
      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the code_review concept from this vocabulary")
        expect(text).to include("n_plus_one")
        expect(text).not_to include("pattern concept")
      end

      # These two modes never receive the data-modeling concepts in
      # production — ProblemSetIngest.vocabulary_for subtracts them — so the
      # test must hand over the same narrowed list, or the vocabulary line
      # renders `unsafe_migration` and the assertions below collide with a
      # substring that has nothing to do with the mode's instruction.
      let(:non_schema_vocabulary) { RAILS_VOCAB - AiService::DATA_MODELING_CONCEPTS }

      it "asks for application code by default" do
        text = guidance(described_class, vocabulary: non_schema_vocabulary, mode: :application_code)
        expect(text).to include("realistic Ruby/Rails code")
        expect(text).not_to include("test file")
        expect(text).not_to include("migration")
      end

      it "asks for a test file on a test-file day" do
        text = guidance(described_class, vocabulary: non_schema_vocabulary, mode: :test_file,
                                          test_framework: "an RSpec-style")
        expect(text).to include("an RSpec-style Ruby/Rails test file")
        expect(text).not_to include("migration")
      end

      # The narrowing above is what production does, not a convenience: prove
      # the two agree, so this block cannot drift from the real resolution.
      it "is handed exactly the vocabulary ingest resolves for these modes" do
        %i[application_code test_file].each do |mode|
          expect(ProblemSetIngest.selectable_vocabulary_for("code_review", "ruby_rails", mode: mode))
            .to eq(non_schema_vocabulary)
        end
      end

      it "asks for the language's schema artifact on a schema-review day" do
        text = guidance(described_class, vocabulary: AiService::DATA_MODELING_CONCEPTS,
                                          label: "Ruby/Rails", mode: :schema_review,
                                          artifact: "a Rails migration")
        expect(text).to include("a Rails migration, ~10-15 lines, containing one planted data-modeling flaw")
        expect(text).to include("missing_index")
        expect(text).not_to include("n_plus_one")
      end
    end

    describe ExerciseSection::Pattern do
      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the pattern concept from this vocabulary")
        expect(text).to include("n_plus_one")
        expect(text).not_to include("code_review concept")
      end
    end

    # Issue #81: every kind's guidance now speaks only for itself.
    it "has no kind stating another kind's vocabulary" do
      ExerciseSection.all.each do |kind|
        next if [ ExerciseSection::CodeReview, ExerciseSection::Pattern ].include?(kind)

        text = guidance(kind, vocabulary: ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails"))
        expect(text).not_to include("code_review and pattern concepts"), "#{kind.key} still speaks for code_review"
        expect(text).not_to include("each section's concept"), "#{kind.key} still speaks for every section"
      end
    end

    describe ExerciseSection::Architecture do
      it "names the architecture vocabulary for its own section" do
        text = guidance(described_class, vocabulary: AiService::ARCHITECTURE_CONCEPTS)
        expect(text).to include("SEPARATE vocabulary", "service_boundaries")
      end

      it "demands a short scenario and drops the old team-size/budget/timeline list" do
        text = guidance(described_class, vocabulary: AiService::ARCHITECTURE_CONCEPTS)
        expect(text).to include("~50 words maximum")
        expect(text).to include("Do NOT stack scale figures")
      end

      it "says the diagram shows the structure under decision, not how to decide" do
        text = guidance(described_class, vocabulary: AiService::ARCHITECTURE_CONCEPTS)
        expect(text).to include("not a flowchart of how to decide")
      end
    end

    describe ExerciseSection::SecurityReview do
      it "frames the section adversarially and restricts the vocabulary to security concepts" do
        text = guidance(described_class, vocabulary: AiService::RAILS_SECURITY_CONCEPTS)
        expect(text).to include("SECURITY REVIEW", "exploitable vulnerability")
        expect(text).to include("these are the ONLY concepts security_review may use")
        expect(text).to include("mass_assignment_protection")
        expect(text).not_to include("memoization")
      end

      it "names the day's language for the snippet's realism bar" do
        text = guidance(described_class, vocabulary: AiService::JS_SECURITY_CONCEPTS, label: "JavaScript/React")
        expect(text).to include("realistic JavaScript/React code")
      end

      it "says nothing about code_review and pattern's vocabulary" do
        text = guidance(described_class, vocabulary: AiService::RAILS_SECURITY_CONCEPTS)
        expect(text).not_to include("Choose the code_review and pattern concepts")
        expect(text).not_to include("Choose each section's concept")
      end
    end

    describe ExerciseSection::ParsonsProblem do
      it "asks for 5-8 correct-order blocks that are never bare tokens" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("5 to 8 short code blocks IN THE CORRECT FINAL ORDER")
        expect(text).to include("never a single token")
      end

      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the parsons_problem concept from this vocabulary")
        expect(text).to include("n_plus_one")
      end
    end

    describe ExerciseSection::Challenge do
      it "asks starter_code to scaffold without giving the answer" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("without giving away the answer")
      end

      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the challenge concept from this vocabulary")
        expect(text).to include("n_plus_one")
      end
    end

    describe ExerciseSection::PlanReview do
      it "asks for 2-3 planted flaws spanning levels, never three of a kind" do
        text = guidance(described_class, vocabulary: AiService::PLAN_REVIEW_CONCEPTS)
        expect(text).to include("2-3 planted flaws that span levels")
        expect(text).to include("never three of the same category")
      end

      it "restricts the concept to the plan_review vocabulary" do
        text = guidance(described_class, vocabulary: AiService::PLAN_REVIEW_CONCEPTS)
        expect(text).to include("scope_creep")
        expect(text).not_to include("memoization")
      end
    end

    describe ExerciseSection::AmbiguityHunt do
      it "asks for exactly PLANTED_COUNT planted ambiguities" do
        text = guidance(described_class, vocabulary: AiService::AMBIGUITY_HUNT_CONCEPTS)
        expect(text).to include("EXACTLY #{ExerciseSection::AmbiguityHunt::PLANTED_COUNT} deliberately planted ambiguities")
      end

      it "forbids leaking the planted list into any field the engineer reads" do
        text = guidance(described_class, vocabulary: AiService::AMBIGUITY_HUNT_CONCEPTS)
        expect(text).to include("HIDDEN test data")
        expect(text).to include('Never restate, hint at, or echo any of it inside "request", "question", or "teaching_note"')
      end

      it "restricts the concept to the ambiguity_hunt vocabulary" do
        text = guidance(described_class, vocabulary: AiService::AMBIGUITY_HUNT_CONCEPTS)
        expect(text).to include("undefined_scope_boundary")
        expect(text).not_to include("memoization")
      end
    end
  end
end

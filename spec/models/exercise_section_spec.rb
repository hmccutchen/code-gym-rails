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
      skip "DailyPlan::FOURTH_SECTION_WEIGHTS lands in Task 5"
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
end

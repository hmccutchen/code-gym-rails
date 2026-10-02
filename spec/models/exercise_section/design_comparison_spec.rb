require "rails_helper"

RSpec.describe ExerciseSection::DesignComparison do
  def provider_section(overrides = {})
    {
      "title" => "Shipping rates",
      "scenario" => "A new carrier is added every month.",
      "question" => "Which piece fits, and why?",
      "better_piece" => "class Better\nend",
      "other_piece" => "class Other\nend",
      "answer_key" => { "deciding_fact" => "A new carrier every month.", "principle" => "open_closed",
                        "why_other_fails" => "Each carrier edits the case statement." },
      "concept" => "open_closed"
    }.merge(overrides)
  end

  def roll_better(position)
    allow(WeightedRoll).to receive(:pick).with(described_class::POSITION_WEIGHTS).and_return(position)
  end

  it "is a fixed kind" do
    expect(described_class.fixed?).to be(true)
    expect(ExerciseSection.fixed).to eq([ ExerciseSection::CodeReview, described_class ])
  end

  it "keeps its answer key out of everything that shows a section before submission" do
    expect(ExerciseSection.all_answer_key_fields).to include("answer_key")
  end

  it "offers no teaching note for the judge to write, since a note before the answer would be the answer" do
    expect(described_class.prose_fields).to eq(%w[title scenario question])
  end

  describe ".reject_unusable!" do
    it "accepts a complete section" do
      expect { described_class.reject_unusable!(provider_section) }.not_to raise_error
    end

    it "refuses a missing, blank or non-string piece" do
      [ nil, "  ", 42 ].each do |value|
        expect { described_class.reject_unusable!(provider_section("other_piece" => value)) }
          .to raise_error(AiService::InvalidResponseError, /other_piece/)
      end
    end

    it "refuses a piece past the line bound and accepts one at it, not counting blank lines" do
      at_bound = Array.new(described_class::MAX_PIECE_LINES, "x").join("\n\n")
      past     = Array.new(described_class::MAX_PIECE_LINES + 1, "x").join("\n")

      expect { described_class.reject_unusable!(provider_section("better_piece" => at_bound)) }.not_to raise_error
      expect { described_class.reject_unusable!(provider_section("better_piece" => past)) }
        .to raise_error(AiService::InvalidResponseError, /#{described_class::MAX_PIECE_LINES} lines/)
    end

    it "refuses an answer key with any field missing, blank or not a string" do
      described_class::PROVIDER_KEY_FIELDS.each do |field|
        [ nil, "", [ "a list" ] ].each do |value|
          section = provider_section
          section["answer_key"] = section["answer_key"].merge(field => value)

          expect { described_class.reject_unusable!(section) }.to raise_error(AiService::InvalidResponseError, /#{field}/)
        end
      end
    end

    it "refuses an answer key that is not an object" do
      expect { described_class.reject_unusable!(provider_section("answer_key" => "b")) }
        .to raise_error(AiService::InvalidResponseError)
    end
  end

  describe ".arrange!" do
    it "shows the better piece as A when the roll says a" do
      roll_better("a")
      section = provider_section
      described_class.arrange!(section)

      expect(section).to include("piece_a" => "class Better\nend", "piece_b" => "class Other\nend")
      expect(section["answer_key"]["better"]).to eq("a")
    end

    it "shows the better piece as B when the roll says b" do
      roll_better("b")
      section = provider_section
      described_class.arrange!(section)

      expect(section).to include("piece_a" => "class Other\nend", "piece_b" => "class Better\nend")
      expect(section["answer_key"]["better"]).to eq("b")
    end

    it "removes the provider's own order, so no field says which piece is better but the key" do
      roll_better("a")
      section = provider_section
      described_class.arrange!(section)

      expect(section.keys).not_to include("better_piece", "other_piece")
    end

    it "replaces a better position the provider wrote, and keeps only the key's known fields" do
      roll_better("b")
      section = provider_section
      section["answer_key"] = section["answer_key"].merge("better" => "a", "extra" => "x")
      described_class.arrange!(section)

      expect(section["answer_key"].keys).to eq(%w[better deciding_fact principle why_other_fails])
      expect(section["answer_key"]["better"]).to eq("b")
    end

    it "rolls even odds" do
      expect(described_class::POSITION_WEIGHTS).to eq("a" => 1, "b" => 1)
    end

    it "fails loudly on a roll outside the two pieces" do
      roll_better(:schema_review)

      expect { described_class.arrange!(provider_section) }.to raise_error(ArgumentError)
    end
  end

  describe "answers" do
    let(:reason) { "A new carrier arrives every month, so a registry avoids editing the case." }

    it "reads the pick and reason back out of the stored string" do
      expect(described_class.parse_answer("pick:b\n#{reason}")).to eq([ "b", reason ])
    end

    it "round-trips through encode_answer" do
      expect(described_class.parse_answer(described_class.encode_answer("a", reason))).to eq([ "a", reason ])
    end

    it "reads no pick from a missing, malformed or out-of-range prefix, and keeps the reason" do
      expect(described_class.parse_answer(nil)).to eq([ nil, "" ])
      expect(described_class.parse_answer("\n#{reason}")).to eq([ nil, reason ])
      expect(described_class.parse_answer("pick:c\n#{reason}")).to eq([ nil, reason ])
      expect(described_class.parse_answer("b\n#{reason}")).to eq([ nil, reason ])
    end

    it "counts as answered only with a pick and a reason of at least the minimum length" do
      short = "x" * (described_class::MIN_REASON_LENGTH - 1)
      long  = "x" * described_class::MIN_REASON_LENGTH

      expect(described_class.answered?("pick:a\n#{long}")).to be(true)
      expect(described_class.answered?("pick:a\n#{short}")).to be(false)
      expect(described_class.answered?("\n#{long}")).to be(false)
      expect(described_class.answered?("pick:a")).to be(false)
    end

    it "is the authority DailyResponse.answered? reads" do
      expect(DailyResponse.answered?("design_comparison", "pick:a\nfine", {})).to be(false)
      expect(DailyResponse.answered?("design_comparison", "pick:a\n#{reason}", {})).to be(true)
    end

    it "shows nothing for a pick with too short a reason" do
      expect(described_class.answer_for("pick:a\nshort")).to be_nil
    end
  end

  describe ".review_context" do
    let(:section) do
      roll_better("b")
      provider_section.tap { |s| described_class.arrange!(s) }
    end

    it "decodes the answer so the raw prefix never reaches the grader" do
      context = described_class.review_context(section: section, answer: "pick:b\nMonthly carriers.", rating: "right_level")

      expect(context).to include("Picked: B. Reason: Monthly carriers.")
      expect(context).not_to include("pick:b")
    end

    it "hands the grader the answer key and both pieces" do
      context = described_class.review_context(section: section, answer: nil, rating: nil)

      expect(context).to include("the better piece is B", "A new carrier every month.", "class Better", "class Other")
      expect(context).to include("Their answer: (skipped)")
    end
  end

  describe ".grading_note" do
    it "names the main point and essential pieces without restating the rubric's levels" do
      note = described_class.grading_note(section: {}, answer: nil)

      expect(note).to include("Main point:", "Essential pieces:", "Grade the reason, never the pick alone")
      levels = AiService::RATING_RUBRIC.scan(/^- "(\w+)":/).flatten
      expect(levels).to eq(%w[beginner developing solid strong])
      levels.each { |level| expect(note).not_to include("\"#{level}\":") }
    end
  end

  describe ".narrow_vocabulary" do
    let(:rails) { AiService::RAILS_CONCEPTS }
    let(:js)    { AiService::JS_CONCEPTS }

    it "offers only its own hosts, intersected with the language vocabulary" do
      offered = described_class.narrow_vocabulary(rails, rung: "senior")

      expect(offered).to include("open_closed", "n_plus_one", "over_mocking", "god_object")
      expect(offered).not_to include("idempotency", "error_handling", "concurrency", "transaction_safety",
                                     "reading_for_intent", "sql_injection_prevention")
      expect(offered - rails).to be_empty
    end

    it "offers the JavaScript hosts on a JavaScript day and none of the excluded ones" do
      offered = described_class.narrow_vocabulary(js, rung: "senior")

      expect(offered).to include("callback_hell", "state_lifting", "generics")
      expect(offered).not_to include("closures_in_loops", "this_binding", "memory_leaks_listeners", "n_plus_one")
    end

    it "offers a tradeoff concept only at principal_engineer, and the strictest list with no rung" do
      tradeoffs = rails & AiService::TRADEOFF_CONCEPTS & described_class.hosted_concepts
      expect(tradeoffs).not_to be_empty

      expect(described_class.narrow_vocabulary(rails, rung: "principal_engineer")).to include(*tradeoffs)
      expect(described_class.narrow_vocabulary(rails, rung: "senior") & tradeoffs).to be_empty
      expect(described_class.narrow_vocabulary(rails) & tradeoffs).to be_empty
    end

    it "names only concepts some language vocabulary holds, so a rename fails here" do
      expect(described_class::HOSTED_CONCEPTS - (rails | js)).to be_empty
    end

    it "is what generation offers it" do
      expect(ProblemSetIngest.selectable_vocabulary_for("design_comparison", "ruby_rails", rung: "junior"))
        .to eq(described_class.narrow_vocabulary(rails, rung: "junior"))
    end
  end

  describe ".generation_guidance" do
    it "states the rung it is pitched at, and every rung when none is known" do
      senior = described_class.generation_guidance(vocabulary: %w[open_closed], label: "Ruby on Rails", rung: "senior")
      unknown = described_class.generation_guidance(vocabulary: %w[open_closed], label: "Ruby on Rails")

      expect(senior).to include("pitched at senior: #{described_class::RUNG_GUIDANCE.fetch('senior')}")
      expect(senior).not_to include(described_class::RUNG_GUIDANCE.fetch("junior"))
      described_class::RUNG_GUIDANCE.each_value { |text| expect(unknown).to include(text) }
    end

    it "has rung guidance for exactly the difficulty levels" do
      expect(described_class::RUNG_GUIDANCE.keys).to eq(KindDifficulty::LEVELS)
    end
  end

  describe "the judge's blind solve" do
    it "asks the judge to choose between the two pieces" do
      expect(described_class.judge_solve_options).to eq(%w[a b])
    end

    it "compares a solve with the stored key" do
      section = { "answer_key" => { "better" => "b" } }

      expect(described_class.solve_matches_key?(section, "b")).to be(true)
      expect(described_class.solve_matches_key?(section, "a")).to be(false)
    end
  end
end

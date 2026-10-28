require "rails_helper"

RSpec.describe "Section kind refusal codes" do
  def code_for(kind, section)
    kind.reject_unusable!(section)
    nil
  rescue ProviderError::UnusableSectionError => e
    e.code
  end

  let(:comparison) { FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").deep_dup }

  {
    "code_review.snippet_missing" => -> { [ ExerciseSection::CodeReview, { "snippet" => " " } ] },
    "code_review.snippet_too_long" => lambda {
      [ ExerciseSection::CodeReview, { "snippet" => Array.new(ExerciseSection::CodeReview::MAX_SNIPPET_LINES + 1, "x = 1").join("\n") } ]
    },
    "design_comparison.piece_missing" => -> { [ ExerciseSection::DesignComparison, comparison.merge("other_piece" => "") ] },
    "design_comparison.piece_too_long" => lambda {
      [ ExerciseSection::DesignComparison,
        comparison.merge("better_piece" => Array.new(ExerciseSection::DesignComparison::MAX_PIECE_LINES + 1, "x").join("\n")) ]
    },
    "design_comparison.answer_key_incomplete" => lambda {
      [ ExerciseSection::DesignComparison, comparison.merge("answer_key" => comparison["answer_key"].merge("principle" => "")) ]
    },
    "pseudocode_to_code.problem_statement_missing" => -> { [ ExerciseSection::PseudocodeToCode, { "problem_statement" => "" } ] },
    "ambiguity_hunt.planted_ambiguities_missing" => -> { [ ExerciseSection::AmbiguityHunt, { "planted_ambiguities" => [] } ] }
  }.each do |code, setup|
    it "names the #{code} refusal with its code" do
      kind, section = instance_exec(&setup)

      expect(code_for(kind, section)).to eq(code)
    end
  end

  it "lists every code a kind refuses with, and nothing else" do
    listed = ExerciseSection.all.flat_map { |kind| kind.refusal_codes.map { |code| "#{kind.key}.#{code}" } }

    expect(listed).to contain_exactly(
      "code_review.snippet_missing", "code_review.snippet_too_long", "design_comparison.piece_missing",
      "design_comparison.piece_too_long", "design_comparison.answer_key_incomplete",
      "pseudocode_to_code.problem_statement_missing", "ambiguity_hunt.planted_ambiguities_missing"
    )
  end

  it "won't refuse with a code its kind doesn't list" do
    expect { ExerciseSection::CodeReview.send(:refuse!, "made_up", "message") }.to raise_error(ArgumentError, /made_up/)
  end
end

require "rails_helper"

RSpec.describe ExerciseSection::PseudocodeToCode do
  it "is a fourth-slot kind" do
    expect(described_class.key).to eq("pseudocode_to_code")
    expect(described_class.fourth?).to be(true)
    expect(described_class.third?).to be(false)
  end

  it "draws its own vocabulary" do
    expect(described_class.vocabulary_key).to eq(:pseudocode_to_code)
  end

  # Not scaffolded: a labelled scaffold would impose a decomposition, and
  # choosing the decomposition is the exercise.
  it "is not scaffolded and shows no diagram" do
    expect(described_class.scaffolded?).to be(false)
    expect(described_class.default_scaffold).to be_nil
    expect(described_class.diagrammable?).to be(false)
  end

  it "carries real source as its improved_code" do
    expect(described_class.improved_code?).to be(true)
    expect(described_class.improved_code_prose?).to be(false)
  end

  it "names its own body and answer partials" do
    expect(described_class.body_partial).to eq("responses/bodies/pseudocode_to_code")
    expect(described_class.answer_partial).to eq("responses/answers/pseudocode_to_code")
  end

  describe ".normalize_critique" do
    it "drops non-strings and blanks, truncates, and caps the list" do
      raw = [ "  a real gap  ", "", "   ", 7, nil, "b" * 500, "c", "d", "e" ]

      points = described_class.normalize_critique(raw)

      expect(points.size).to eq(described_class::MAX_CRITIQUE_POINTS)
      expect(points.first).to eq("a real gap")
      expect(points[1].length).to eq(described_class::MAX_CRITIQUE_POINT_LENGTH)
    end

    it "returns an empty list for anything that is not an array" do
      expect(described_class.normalize_critique(nil)).to eq([])
      expect(described_class.normalize_critique("nope")).to eq([])
    end
  end
end

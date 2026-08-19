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

  describe ".answer_class" do
    # An override returning the base default is dead code, and this one carried a
    # comment claiming it applied the monospace face.
    it "actually differs from the prose default" do
      expect(described_class.answer_class).not_to eq(ExerciseSection.answer_class)
      expect(described_class.answer_class).to eq(ExerciseSection::Challenge.answer_class)
    end
  end

  describe ".review_context translation provenance" do
    def context_for(rounds, answer)
      described_class.review_context(
        section: { "title" => "T", "question" => "Q", "problem_statement" => "P", "rounds" => rounds },
        answer: answer, rating: nil
      )
    end

    it "presents the code as theirs when the plan is unchanged since translating" do
      context = context_for({ "generated_code" => "def f; end", "translated_from" => "sort then walk" }, "sort then walk")

      expect(context).to include("translated literally")
      expect(context).not_to include("earlier draft")
    end

    # grading_note tells the reviewer that any flaw in the code is a flaw in the
    # plan. That is only true while the two still correspond.
    it "warns the reviewer when the plan was revised after translating" do
      context = context_for({ "generated_code" => "def f; end", "translated_from" => "first draft" }, "a rewritten plan")

      expect(context).to include("earlier draft")
      expect(context).to include("do not attribute its flaws to the final plan")
    end

    it "says so plainly when nothing was translated" do
      expect(context_for({}, "sort then walk")).to include("never translated their plan")
    end
  end
end

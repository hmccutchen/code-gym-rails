require "rails_helper"

RSpec.describe PlantedKey, "shared hidden-key line" do
  let(:keyed_kinds) { ExerciseSection.all.select(&:planted_key?) }

  def guidance_for(kind, **options)
    kind.generation_guidance(vocabulary: %w[n_plus_one], label: "Ruby/Rails", mode: :application_code,
                             artifact: "a Rails migration", test_framework: "an RSpec-style", rung: "senior", **options)
  end

  describe "PlantedKey::GROUNDING" do
    it "says every claim follows from what is shown, the scenario included, and the planted flaw is never stated in the scenario" do
      expect(described_class::GROUNDING).to include("follow from what the engineer is shown, the scenario included",
                                                   "itself the planted flaw never appears in the scenario")
    end

    it "asks for each consequence to be traced through guards, early returns, locks and validations" do
      expect(described_class::GROUNDING).to include("guards, early returns, locks and validations",
                                                   "never claim an effect they prevent")
    end

    it "asks for a hidden setting that is itself the flaw to be phrased conditionally, never asserted, and not backticked" do
      expect(described_class::GROUNDING).to include("phrase the key conditionally",
                                                   "both examples can pass only if the test cache stores nothing, so check which store is used",
                                                   "never assert it as fact", "don't put the setting in backticks")
    end

    it "is one line, so it renders as one bullet in every keyed kind's guidance" do
      expect(described_class::GROUNDING).not_to include("\n")
    end
  end

  describe ".hidden_key_line" do
    it "names the fields to keep the key out of, what is shown, the quote rule, and ends with the grounding rules" do
      line = described_class.hidden_key_line(fields: %w[question scenario], shown: "the snippet", quoted: "the code")

      aggregate_failures do
        expect(line).to start_with(%(- "answer_key" is HIDDEN test data))
        expect(line).to include(%("question" or "scenario"), "before the engineer reads the snippet",
                                "Quote the code it points at in backticks, never by line number.")
        expect(line).to end_with(described_class::GROUNDING)
      end
    end

    it "leaves the quote rule out for a kind whose key quotes nothing" do
      line = described_class.hidden_key_line(fields: %w[question], shown: "plans", quoted: nil)

      expect(line).not_to include("in backticks, never by line number")
      expect(line).to end_with(described_class::GROUNDING)
    end
  end

  it "covers the four kinds that plant a key, so a new keyed kind is added here on purpose" do
    expect(keyed_kinds.map(&:key)).to contain_exactly("code_review", "security_review", "plan_review", "pseudocode_to_code")
  end

  it "puts the grounding rules exactly once into every keyed kind's generation guidance" do
    keyed_kinds.each do |kind|
      expect(guidance_for(kind).scan(described_class::GROUNDING).size).to eq(1), "#{kind.key} guidance"
    end
  end

  it "puts the grounding rules into a multi-file code review's guidance too" do
    guidance = guidance_for(ExerciseSection::CodeReview, file_range: 2..3)

    expect(guidance.scan(described_class::GROUNDING).size).to eq(1)
  end

  it "leaves no keyed kind writing its own hidden-key line, so the rule has one home" do
    folders = keyed_kinds.map { |kind| Rails.root.join("app/models/exercise_section", kind.key) }
    files = keyed_kinds.map { |kind| Rails.root.join("app/models/exercise_section/#{kind.key}.rb") }
    sources = (files + folders.flat_map { |folder| folder.glob("**/*.rb") }).select { |path| path.read.include?("is HIDDEN test data") }

    expect(sources).to be_empty
  end
end

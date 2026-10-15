require "rails_helper"

RSpec.describe SectionKindGuide do
  def sentences(text)
    text.scan(/[^.?!]+[.?!][”"]?/).map(&:strip).reject(&:empty?)
  end

  it "has a guide for every registered kind, in registry order" do
    expect(described_class::GUIDES.keys).to eq(ExerciseSection.keys.map(&:to_s))
  end

  it "keeps each summary to two sentences and each example to three" do
    described_class::GUIDES.each do |key, guide|
      expect(sentences(guide[:summary]).size).to be_between(1, 2), "#{key} summary"
      expect(sentences(guide[:example]).size).to be_between(1, 3), "#{key} example"
    end
  end

  it "reads a guide by string or symbol key" do
    expect(described_class.for(:parsons_problem)).to eq(described_class::GUIDES["parsons_problem"])
  end

  it "offers its text to the plain-language checks" do
    expect(HandWrittenLearnText.learn_text).to include("kind:code_review:summary", "kind:pseudocode_to_code:example")
  end

  # Static copy must never reach a prompt, so nothing on the generation or review path may read it.
  it "is read by nothing under app/services or app/jobs" do
    readers = Rails.root.glob("app/{services,jobs}/**/*.rb").select { |path| path.read.include?("SectionKindGuide") }
    expect(readers).to eq([])
  end
end

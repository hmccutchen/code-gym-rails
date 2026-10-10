require "rails_helper"

RSpec.describe ConceptBookSources do
  # A citation keyed on a concept outside these vocabularies can never render.
  TRACKED_CONCEPTS = (
    AiService::RAILS_CONCEPTS + AiService::JS_CONCEPTS + AiService::ARCHITECTURE_CONCEPTS +
    AiService::PLAN_REVIEW_CONCEPTS + AiService::AMBIGUITY_HUNT_CONCEPTS +
    AiService::PSEUDOCODE_TO_CODE_CONCEPTS
  ).uniq.freeze

  describe ".for" do
    it "returns the sources for a cited concept" do
      expect(described_class.for("shotgun_surgery")).to eq(described_class::SOURCES["shotgun_surgery"])
    end

    it "returns an empty list for a concept with no citation" do
      expect(described_class.for("memoization")).to eq([])
    end

    it "returns an empty list for a concept that does not exist" do
      expect(described_class.for("not_a_real_concept")).to eq([])
    end

    it "accepts a symbol as well as a string" do
      expect(described_class.for(:shotgun_surgery)).to be_present
    end
  end

  # A renamed or dropped concept strands its citation silently; the Learn page just stops asking.
  it "keys every entry on a concept that exists in a tracked vocabulary" do
    expect(described_class::SOURCES.keys - TRACKED_CONCEPTS).to be_empty
  end

  # Array-valued so a second book is a line, not a migration.
  it "holds an array of sources for every concept, never a bare source" do
    expect(described_class::SOURCES.values).to all(be_an(Array))
    expect(described_class::SOURCES.values).to all(be_present)
  end

  it "gives every source a title and an author" do
    described_class::SOURCES.each do |concept, sources|
      sources.each do |source|
        expect(source[:title]).to be_present, "#{concept} has a source with no title"
        expect(source[:author]).to be_present, "#{concept} has a source with no author"
      end
    end
  end

  it "never lists the same book twice for one concept" do
    described_class::SOURCES.each do |concept, sources|
      titles = sources.map { |source| source[:title] }

      expect(titles).to eq(titles.uniq), "#{concept} lists a book more than once"
    end
  end

  # A recalled chapter or page number is a fabrication that reads as authoritative.
  it "cites no chapter or page number" do
    numbered = described_class::SOURCES.select do |_concept, sources|
      sources.any? { |source| source[:pointer].to_s.match?(/\d/) }
    end

    expect(numbered.keys).to be_empty
  end

  it "carries a citation for both concepts the four-book audit added" do
    expect(described_class.for("ubiquitous_language")).to be_present
    expect(described_class.for("aggregate_boundaries")).to be_present
  end

  # A generated citation is a hallucinated one, and a ConceptReference row is cached forever.
  it "never reaches a provider prompt" do
    double_class = Class.new(AiService) do
      private def build_connection = nil
    end
    service = double_class.new("key")
    titles  = described_class::SOURCES.values.flatten.map { |source| source[:title] }.uniq

    # Derived from LANGUAGE_CONFIG so a new bucket is covered without editing this.
    AiService::LANGUAGE_CONFIG.each do |language, config|
      described_class::SOURCES.each_key do |concept|
        next unless config[:concepts].include?(concept)

        prompt = service.send(:build_concept_reference_prompt, concept, config)

        titles.each do |title|
          expect(prompt).not_to include(title),
            "#{concept}'s #{language} reference prompt carries #{title}"
        end
      end
    end
  end

  # Makes the loop above exhaustive: a key no vocabulary holds would skip every iteration and pass.
  it "keys every entry on a concept some LANGUAGE_CONFIG vocabulary holds" do
    covered = AiService::LANGUAGE_CONFIG.values.flat_map { |config| config[:concepts] }.uniq

    expect(described_class::SOURCES.keys - covered).to be_empty
  end
end

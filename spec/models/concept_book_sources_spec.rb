require "rails_helper"

RSpec.describe ConceptBookSources do
  # Every vocabulary a concept can be tagged from. A citation keyed on
  # anything else is stranded — it can never render, because no Learn page
  # will ever ask for that concept.
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

  # A concept renamed or dropped leaves its citation behind, and nothing else
  # would notice: the Learn page simply stops asking for that key.
  it "keys every entry on a concept that exists in a tracked vocabulary" do
    expect(described_class::SOURCES.keys - TRACKED_CONCEPTS).to be_empty
  end

  # Pins the shape rather than the contents. The store was array-valued from
  # its first commit precisely so a second book is a line rather than a
  # migration, and shotgun_surgery needed two on day one.
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

  # A pointer names a term the book itself coined. A chapter or page number
  # recalled rather than checked is a fabrication that reads as authoritative,
  # and this is the only half of that rule a machine can check.
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

  # THE structural guarantee this store exists to provide. A generated
  # citation is a hallucinated citation, and a ConceptReference row is cached
  # forever — so no prompt may carry this data at all, rather than being asked
  # to handle it correctly.
  it "never reaches a provider prompt" do
    double_class = Class.new(AiService) do
      private def build_connection = nil
    end
    service = double_class.new("key")
    titles  = described_class::SOURCES.values.flatten.map { |source| source[:title] }.uniq

    # Every vocabulary, not just the Rails one: SOURCES also keys architecture,
    # plan-review, ambiguity-hunt and pseudocode concepts, and a leak reached
    # through any of their configs would be the same leak. Derived from
    # LANGUAGE_CONFIG so a seventh bucket is covered without editing this.
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

  # What makes the loop above provably exhaustive rather than merely wide: a
  # citation keyed on a concept no vocabulary holds would be skipped by every
  # iteration and silently pass. Subsumes the tracked-vocabulary check above,
  # and states the stronger property.
  it "keys every entry on a concept some LANGUAGE_CONFIG vocabulary holds" do
    covered = AiService::LANGUAGE_CONFIG.values.flat_map { |config| config[:concepts] }.uniq

    expect(described_class::SOURCES.keys - covered).to be_empty
  end
end

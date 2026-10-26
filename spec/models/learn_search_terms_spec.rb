require "rails_helper"

RSpec.describe LearnSearchTerms do
  let(:concepts) { ConceptVocabulary.languages.flat_map { |language| ConceptVocabulary.for_language(language) }.uniq }
  let(:names) { concepts.index_by { |concept| concept.humanize.downcase } }

  it "lists synonyms only for concepts in a vocabulary or hand-written lessons" do
    expect(described_class::SYNONYMS.keys - concepts - LearnLessons::LESSONS.keys).to eq([])
  end

  it "keeps each synonym lowercase and short, with at most three per key" do
    described_class::SYNONYMS.each do |key, synonyms|
      expect(synonyms.size).to be_between(1, 3), key
      synonyms.each do |synonym|
        expect(synonym).to eq(synonym.downcase)
        expect(synonym.length).to be <= 30, "#{key}: #{synonym}"
      end
    end
  end

  it "repeats nothing the name or the glossary already gives a concept" do
    described_class::SYNONYMS.each do |key, synonyms|
      already = [ key.humanize.downcase, *Glossary.forms_for(key.humanize) ]
      expect(synonyms & already).to eq([]), key
    end
  end

  it "never names another concept, which would send its search to the wrong entry" do
    described_class::SYNONYMS.each do |key, synonyms|
      synonyms.each do |synonym|
        expect(names.fetch(synonym, key)).to eq(key), "#{key}: #{synonym}"
      end
    end
  end

  it "gives solid to every SOLID principle the vocabulary holds, and to nothing else" do
    principles = %w[single_responsibility open_closed liskov_substitution interface_segregation dependency_inversion]
    carriers = described_class::SYNONYMS.select { |_key, synonyms| synonyms.include?("solid") }.keys

    expect(carriers).to match_array(concepts & principles)
  end

  it "answers an unlisted key with no synonyms" do
    expect(described_class.for("n_plus_one")).to include("n+1")
    expect(described_class.for("caching")).to eq([])
  end

  it "is read by nothing below the views, so it never reaches a prompt" do
    readers = (isolation_scope - %w[app/models/learn_search_terms.rb]).select { |path| Rails.root.join(path).read.include?("LearnSearchTerms") }
    expect(readers).to eq([])
  end
end

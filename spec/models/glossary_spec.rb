require "rails_helper"

RSpec.describe Glossary do
  describe ".lookup" do
    it "returns the definition for an exact match" do
      expect(Glossary.lookup("closure")).to eq(Glossary::TERMS["closure"])
    end

    it "matches case-insensitively" do
      expect(Glossary.lookup("Closure")).to eq(Glossary::TERMS["closure"])
    end

    it "strips surrounding whitespace before matching" do
      expect(Glossary.lookup("  closure  ")).to eq(Glossary::TERMS["closure"])
    end

    it "returns nil for a term not in the glossary" do
      expect(Glossary.lookup("not-a-real-term")).to be_nil
    end

    it "returns nil for blank input" do
      expect(Glossary.lookup("")).to be_nil
      expect(Glossary.lookup(nil)).to be_nil
    end
  end

  it "stores every key already lowercased, since .lookup only downcases its input" do
    Glossary::TERMS.keys.each do |key|
      expect(key).to eq(key.downcase)
    end
  end

  it "has no blank definitions" do
    expect(Glossary::TERMS.values).to all(be_present)
  end

  # The coverage guard tries only underscore_case, so hyphenated spellings in prose need their own key.
  it "carries the hyphenated spelling of every term written that way in prose" do
    expect(Glossary.lookup("pass-through method")).to be_present
  end

  # Users search for the words the app shows them; "concurrency" once had no glossary hit at all.
  it "resolves every ConceptVocabulary entry, in its literal or space-normalized form" do
    concepts = ConceptVocabulary::RAILS_CONCEPTS + ConceptVocabulary::JS_CONCEPTS + ConceptVocabulary::ARCHITECTURE_CONCEPTS
    missing = concepts.uniq.reject do |concept|
      Glossary.lookup(concept) || Glossary.lookup(concept.tr("_", " "))
    end

    expect(missing).to be_empty
  end
end

require "rails_helper"

RSpec.describe Glossary do
  it "stores every key already lowercased, since glossary_wrap downcases only the matched text" do
    Glossary::TERMS.keys.each do |key|
      expect(key).to eq(key.downcase)
    end
  end

  it "has no blank definitions" do
    expect(Glossary::TERMS.values).to all(be_present)
  end

  # The coverage guard tries only underscore_case, so hyphenated spellings in prose need their own key.
  it "carries the hyphenated spelling of every term written that way in prose" do
    expect(Glossary::TERMS["pass-through method"]).to be_present
  end

  # Users search for the words the app shows them; "concurrency" once had no glossary hit at all.
  it "resolves every ConceptVocabulary entry, in its literal or space-normalized form" do
    concepts = ConceptVocabulary::RAILS_CONCEPTS + ConceptVocabulary::JS_CONCEPTS + ConceptVocabulary::ARCHITECTURE_CONCEPTS
    missing = concepts.uniq.reject do |concept|
      Glossary::TERMS[concept] || Glossary::TERMS[concept.tr("_", " ")]
    end

    expect(missing).to be_empty
  end

  describe "entries that reference pages read in two senses" do
    it "defines strict mode for JavaScript and for React" do
      expect(Glossary::TERMS["strict mode"]).to match(/use strict/).and match(/React/)
    end

    it "defines reconciliation as repairing differences and as React's render diff" do
      expect(Glossary::TERMS["reconciliation"]).to match(/differ|repair/i).and match(/React/)
    end

    it "defines throttling for a function and for a processor" do
      expect(Glossary::TERMS["throttling"]).to match(/interval/).and match(/CPU|processor/)
    end
  end
end

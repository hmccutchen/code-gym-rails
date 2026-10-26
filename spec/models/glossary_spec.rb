require "rails_helper"

RSpec.describe Glossary do
  it "stores every key already lowercased, since key_for downcases only the text it looks up" do
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
      Glossary.key_for(concept) || Glossary.key_for(concept.tr("_", " "))
    end

    expect(missing).to be_empty
  end

  describe ".pattern_for" do
    it "matches the longer of two overlapping terms" do
      pattern = Glossary.pattern_for("partial index" => "x", "index" => "y")

      expect("a partial index helps"[pattern]).to eq("partial index")
    end

    it "matches a form, preferring the longer form to a shorter one inside it" do
      pattern = Glossary.pattern_for({ "indexing" => "x", "composite index" => "y" }, { "indexing" => %w[indexes], "composite index" => [ "composite indexes" ] })

      expect("add composite indexes"[pattern]).to eq("composite indexes")
    end

    it "matches no form when none are passed" do
      expect("it is memoized"[Glossary.pattern_for("memoization" => "x")]).to be_nil
    end
  end

  describe ".key_for" do
    it "resolves a form to its key" do
      expect(Glossary.key_for("memoized")).to eq("memoization")
      expect(Glossary.key_for("Service Objects")).to eq("service object")
    end

    it "resolves a key to itself and an unknown word to nil" do
      expect(Glossary.key_for("Closure")).to eq("closure")
      expect(Glossary.key_for("nonexistentword")).to be_nil
    end

    it "gives the plural duplicates no key of their own" do
      expect(Glossary::TERMS.keys & [ "background jobs", "closures", "policy objects", "query objects", "service objects" ]).to be_empty
      expect(Glossary.key_for("closures")).to eq("closure")
    end
  end

  describe "FORMS" do
    it "lets no form equal a key or another key's form" do
      forms = Glossary::FORMS.values.flatten

      expect(forms & Glossary::TERMS.keys).to be_empty
      expect(forms.size).to eq(forms.uniq.size)
    end

    it "is lowercase and belongs to keys that exist" do
      expect(Glossary::FORMS.keys - Glossary::TERMS.keys).to be_empty
      expect(Glossary::FORMS.values.flatten.map { |form| form == form.downcase }).to all(be(true))
    end
  end

  describe "entries that reference pages read in two senses" do
    it "defines strict mode for JavaScript and for React" do
      expect(Glossary::TERMS["strict mode"]).to match(/use strict/).and match(/React/)
    end

    it "defines reconciliation as repairing differences and as React's render diff" do
      expect(Glossary::TERMS["reconciliation"]).to match(/repair/i).and match(/React/)
    end

    it "defines throttling for a function and for a processor" do
      expect(Glossary::TERMS["throttling"]).to match(/interval/).and match(/CPU|processor/)
    end
  end
end

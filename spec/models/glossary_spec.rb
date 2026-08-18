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

  # The coverage guard below only tries the underscore_case form, so a term
  # whose ordinary written spelling is hyphenated needs both keys — TERM_PATTERN
  # matches literal keys, and generated prose writes "pass-through method".
  # Same reason "over-mocking"/"over mocking" are both present.
  it "carries the hyphenated spelling of every term written that way in prose" do
    expect(Glossary.lookup("pass-through method")).to be_present
  end

  # Regression guard: a user is most likely to search for exactly the words
  # this app already shows them — a concept tag, or its underscore_case form.
  # Catches the class of bug reported in production: "concurrency" (a real
  # RAILS_CONCEPTS entry) had no glossary hit at all, and several others only
  # existed under a mismatched singular/plural or punctuation form.
  it "resolves every AiService concept vocabulary entry, in its literal or space-normalized form" do
    concepts = AiService::RAILS_CONCEPTS + AiService::JS_CONCEPTS + AiService::ARCHITECTURE_CONCEPTS
    missing = concepts.uniq.reject do |concept|
      Glossary.lookup(concept) || Glossary.lookup(concept.tr("_", " "))
    end

    expect(missing).to be_empty
  end
end

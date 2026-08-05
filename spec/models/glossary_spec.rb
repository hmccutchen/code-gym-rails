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
end

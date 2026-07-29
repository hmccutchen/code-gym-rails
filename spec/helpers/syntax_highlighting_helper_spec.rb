require "rails_helper"

RSpec.describe SyntaxHighlightingHelper, type: :helper do
  describe "#hljs_language" do
    it "maps ruby_rails to ruby" do
      expect(helper.hljs_language("ruby_rails")).to eq("ruby")
    end

    it "maps javascript to javascript" do
      expect(helper.hljs_language("javascript")).to eq("javascript")
    end

    it "returns nil for architecture (pseudocode is never highlighted)" do
      expect(helper.hljs_language("architecture")).to be_nil
    end

    it "returns nil for blank or unrecognized values" do
      expect(helper.hljs_language(nil)).to be_nil
      expect(helper.hljs_language("")).to be_nil
      expect(helper.hljs_language("cobol")).to be_nil
    end
  end
end

require "rails_helper"

RSpec.describe SyntaxHighlightingHelper, type: :helper do
  describe "#highlighted_code" do
    it "wraps the server-highlighted lines in a code element for the theme" do
      code = Nokogiri::HTML.fragment(helper.highlighted_code("puts 1", "ruby_rails")).at_css("code")

      expect(code["class"]).to eq("highlight")
      expect(code.css(".code-line").map(&:text)).to eq([ "puts 1" ])
      expect(code.css(".nb, .mi")).not_to be_empty
    end

    it "leaves no hook for a browser highlighter" do
      expect(helper.highlighted_code("puts 1", "ruby_rails")).not_to include("data-hljs")
    end
  end
end

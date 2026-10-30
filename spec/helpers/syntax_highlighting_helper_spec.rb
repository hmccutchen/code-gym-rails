require "rails_helper"

RSpec.describe SyntaxHighlightingHelper, type: :helper do
  describe "#highlighted_code" do
    it "wraps the server-highlighted lines in a code element for the theme" do
      code = Nokogiri::HTML.fragment(helper.highlighted_code("puts 1", "ruby_rails")).at_css("code")

      expect(code["class"]).to eq("highlight")
      expect(code.css(".code-line").map(&:text)).to eq([ "puts 1" ])
      expect(code.css(".nb, .mi")).not_to be_empty
    end

    it "passes changed lines through, and renders as before without them" do
      marked = Nokogiri::HTML.fragment(helper.highlighted_code("a = 1\nb = 2", "ruby_rails", changed: [ 2 ]))

      expect(marked.css(".code-line-changed").map(&:text)).to eq([ "b = 2" ])
      expect(helper.highlighted_code("a = 1\nb = 2", "ruby_rails"))
        .to eq(helper.content_tag(:code, CodeHighlight.html("a = 1\nb = 2", lexer: "ruby"), class: "highlight"))
    end

    it "leaves no hook for a browser highlighter" do
      expect(helper.highlighted_code("puts 1", "ruby_rails")).not_to include("data-hljs")
    end
  end
end

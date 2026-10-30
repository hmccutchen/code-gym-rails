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

    it "numbers the lines in a gutter as wide as the number width it is given" do
      code = Nokogiri::HTML.fragment(helper.highlighted_code("a = 1", "ruby_rails", number_width: 3)).at_css("code")

      expect(code["class"]).to eq("highlight numbered")
      expect(code["style"]).to eq("--number-width: 3")
    end

    it "leaves no hook for a browser highlighter" do
      expect(helper.highlighted_code("puts 1", "ruby_rails")).not_to include("data-hljs")
    end
  end
end

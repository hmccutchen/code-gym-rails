require "rails_helper"

RSpec.describe CodeHighlight do
  def html(code, lexer: "ruby")
    described_class.html(code, lexer: lexer)
  end

  def lines(markup)
    Nokogiri::HTML.fragment(markup).css(".code-line")
  end

  describe ".lexer_for" do
    it "maps the two languages and leaves everything else to plain text" do
      expect(described_class.lexer_for("ruby_rails")).to eq("ruby")
      expect(described_class.lexer_for("javascript")).to eq("javascript")
      [ "architecture", "plan_review", nil, "", "cobol" ].each do |language|
        expect(described_class.lexer_for(language)).to be_nil
      end
    end
  end

  describe ".html" do
    it "escapes markup in the code, whichever lexer reads it" do
      code = %(<script>alert("x")</script></code><a href="javascript:alert('y')">z</a>)

      [ "ruby", "javascript", nil ].each do |lexer|
        fragment = Nokogiri::HTML.fragment(html(code, lexer: lexer))

        expect(fragment.css("script, a, code")).to be_empty
        expect(fragment.text).to eq(code)
      end
    end

    it "is safe HTML built from code that is not" do
      code = "x = 1"

      expect(html(code)).to be_html_safe
      expect(code).not_to be_html_safe
    end

    it "gives each source line its own block with its leading columns" do
      result = lines(html("def total\n  items.sum\n\n\titems\nend\n"))

      expect(result.map(&:text)).to eq([ "def total", "  items.sum", "\n", "\titems", "end" ])
      expect(result.map { |line| line["style"] }).to eq([ 0, 2, 0, 8, 0 ].map { |indent| "--indent: #{indent}" })
    end

    it "re-opens a string that crosses lines on every line it covers" do
      result = lines(html(%(label = "a,\n  b" # note)))

      expect(result.map { |line| line.css(".s2").map(&:text) }).to eq([ [ %("a,) ], [ %(  b") ] ])
    end

    it "marks alignment padding past its first space, outside strings and comments" do
      result = lines(html(%(  kind     = 1 # a\nfoo(a: 1,   b: 2)\nx   //  y\nlabel = "a,  b" # c  = d\nkind:   value)))

      expect(result.map { |line| line.css(".code-align-extra").map(&:text) })
        .to eq([ [ "    " ], [ "  " ], [ "  " ], [], [ "  " ] ])
    end

    it "puts a break point after each dot or parenthesis outside strings and comments, adding no text" do
      code = %(a.b(c).d("e.f") # g.h)
      markup = html(code)

      expect(markup.scan("<wbr>").size).to eq(4)
      expect(Nokogiri::HTML.fragment(markup).text).to eq(code)
      expect(markup).to include(%(<wbr><span class="s2">"e.f"</span>))
      expect(markup).to include(%(<span class="c1"># g.h</span>))
    end

    it "falls back to plain text for an unknown lexer, still one block per line" do
      result = lines(html("a < b\nc", lexer: "no-such-lexer"))

      expect(result.map(&:text)).to eq([ "a < b", "c" ])
      expect(result.css("span span")).to be_empty
    end

    # Judge fixtures carry no language, so each snippet goes through every
    # lexer a page can pick, plain text included.
    it "highlights every fixture snippet with every lexer, keeping its text" do
      snippets = Dir[Rails.root.join("spec/fixtures/{judge,review_calibration}/*.json")].flat_map do |path|
        fixture = JSON.parse(File.read(path))
        section = fixture["section"].is_a?(Hash) ? fixture["section"] : fixture
        %w[snippet starter_code current_schema piece_a piece_b code_example improved_code].filter_map { |field| section[field].presence }
      end
      expect(snippets.size).to be >= 20

      lexers = [ *described_class::LEXERS.values, nil ]
      snippets.product(lexers).each do |code, lexer|
        rendered = lines(html(code, lexer: lexer)).map { |line| line.text == "\n" ? "" : line.text }

        expect(rendered).to eq(code.chomp.split("\n", -1))
      end
    end

    it "reads a cached block instead of highlighting it again" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      first = html("x = 1")
      expect(Rouge::Lexers::Ruby).not_to receive(:new)

      expect(html("x = 1")).to eq(first)
    end

    it "keys the cache on the lexer and the code" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect(html("x = 1", lexer: "ruby")).not_to eq(html("x = 1", lexer: nil))
      expect(html("x = 2")).to include("2")
    end
  end
end

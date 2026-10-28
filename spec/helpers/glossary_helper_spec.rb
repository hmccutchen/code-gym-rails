require "rails_helper"

RSpec.describe GlossaryHelper, type: :helper do
  describe "#glossary_wrap" do
    it "wraps the first case-insensitive match of a term in a span with its definition" do
      stub_glossary("closure" => "A function bundled with its surrounding variables.")
      result = helper.glossary_wrap("A Closure captures scope.")

      expect(result).to be_html_safe
      expect(result).to include('<span class="gloss-term" data-definition="A function bundled with its surrounding variables." tabindex="0" role="button" aria-label="Closure: A function bundled with its surrounding variables.">Closure</span>')
    end

    it "wraps a plural of a two-word key once, with the singular's definition" do
      result = Nokogiri::HTML5.fragment(helper.glossary_wrap("two unique indexes")).css(".gloss-term")

      expect(result.map(&:text)).to eq([ "unique indexes" ])
      expect(result.first["data-definition"]).to eq(Glossary::TERMS["unique index"])
    end

    it "only wraps the first occurrence, leaving later repeats plain" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("A closure is a closure of scope.")

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include(">closure</span> is a closure of scope.")
    end

    it "does not match a term as a partial substring of another word" do
      stub_glossary("orm" => "Object-Relational Mapping.")
      result = helper.glossary_wrap("Welcome to the dormitory, not the orm itself.")

      expect(result).to include("Welcome to the dormitory, not the")
      expect(result).to include('<span class="gloss-term" data-definition="Object-Relational Mapping." tabindex="0" role="button" aria-label="orm: Object-Relational Mapping.">orm</span> itself.')
    end

    it "wraps multiple distinct terms independently in the same text" do
      stub_glossary("closure" => "def1", "hoisting" => "def2")
      result = helper.glossary_wrap("A closure relies on hoisting rules.")

      expect(result.scan("gloss-term").size).to eq(2)
    end

    it "prefers the longer of two overlapping terms" do
      stub_glossary(
        "array mutation" => "shorter",
        "array mutation pitfalls" => "longer"
      )
      result = helper.glossary_wrap("Watch the array mutation pitfalls closely.")

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include('data-definition="longer"')
      expect(result).not_to include('data-definition="shorter"')
    end

    it "wraps an inflected form with its key's definition and keeps the text's own word" do
      stub_glossary({ "memoization" => "M." }, { "memoization" => %w[memoized] })
      result = helper.glossary_wrap("It is memoized.")

      expect(result).to include('data-definition="M."')
      expect(result).to include(">memoized</span>")
    end

    it "underlines a key and its form once per field" do
      stub_glossary({ "memoization" => "M." }, { "memoization" => %w[memoized] })
      result = helper.glossary_wrap("memoization helps; memoized code is fast")

      expect(result.scan("gloss-term").size).to eq(1)
    end

    it "prefers the longer plural form" do
      stub_glossary({ "indexing" => "I.", "unique index" => "U." },
                    { "indexing" => %w[indexes], "unique index" => [ "unique indexes" ] })
      result = helper.glossary_wrap("two unique indexes")

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include('data-definition="U."')
    end

    it "silently skips a term with no match in the text" do
      stub_glossary("nonexistentword" => "def")
      result = helper.glossary_wrap("Nothing to see here.")

      expect(result).to eq("Nothing to see here.")
    end

    it "returns nil/blank text unchanged" do
      stub_glossary("x" => "y")
      expect(helper.glossary_wrap(nil)).to be_nil
      expect(helper.glossary_wrap("")).to eq("")
    end

    it "escapes a malicious definition so it cannot break out of the data attribute" do
      stub_glossary("closure" => %(a trick" onmouseover="alert(1)))
      result = helper.glossary_wrap("Explain the closure here.")

      expect(result).not_to include('onmouseover="alert(1)"')
      expect(result).to include("a trick&quot; onmouseover=&quot;alert(1)")
    end

    it "escapes unmatched HTML-bearing text in the same field" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("<script>alert(1)</script> a closure appears here.")

      expect(result).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(result).not_to include("<script>alert(1)</script>")
    end

    it "escapes angle brackets in the surrounding (pre-match) text fragment" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("<b>Bold</b> and a closure here.")

      expect(result).to include("&lt;b&gt;Bold&lt;/b&gt;")
      expect(result).not_to include("<b>Bold</b>")
      expect(result).to include('<span class="gloss-term"')
    end

    it "escapes angle brackets in the post-match text fragment" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("A closure <script>xss</script>.")

      expect(result).to include("&lt;script&gt;xss&lt;/script&gt;")
    end

    it "still escapes dangerous text even when called with an html_safe (SafeBuffer) input" do
      # html_escape skips SafeBuffer input, so the helper must strip html_safe before escaping.
      stub_glossary("closure" => "def")
      unsafe_text = "<img src=x onerror=alert(1)> closure here".html_safe
      result = helper.glossary_wrap(unsafe_text)

      expect(result).not_to include("<img src=x onerror=alert(1)>")
      expect(result).to include("&lt;img src=x onerror=alert(1)&gt;")
      expect(result).to include('<span class="gloss-term"')
    end

    it "handles a definition with both single and double quotes safely" do
      stub_glossary("closure" => %q(it's a "thing"))
      result = helper.glossary_wrap("A closure exists.")

      expect(result).to include("it&#39;s a &quot;thing&quot;")
      expect(result).not_to include('"thing"')
    end

    it "makes the wrapped term keyboard-focusable with an accessible name" do
      stub_glossary("closure" => "A function bundled with its surrounding variables.")
      result = helper.glossary_wrap("A closure captures scope.")

      expect(result).to include('tabindex="0"')
      expect(result).to include('role="button"')
      expect(result).to include('aria-label="closure: A function bundled with its surrounding variables."')
    end

    it "escapes HTML-special characters in the aria-label the same way as the data-definition" do
      stub_glossary("closure" => %(a trick" onmouseover="alert(1)))
      result = helper.glossary_wrap("Explain the closure here.")

      expect(result).not_to include('aria-label="closure: a trick" onmouseover="alert(1)"')
      expect(result).to include('aria-label="closure: a trick&quot; onmouseover=&quot;alert(1)"')
    end

    it "escapes text with no match and marks it html_safe, so every caller gets safe HTML" do
      stub_glossary("nonexistentword" => "y")
      result = helper.glossary_wrap("<b>Nothing</b> here.")

      expect(result).to eq("&lt;b&gt;Nothing&lt;/b&gt; here.")
      expect(result).to be_html_safe
    end

    it "escapes an html_safe input that has no match, rather than trusting it" do
      stub_glossary("nonexistentword" => "y")
      result = helper.glossary_wrap("<img src=x onerror=alert(1)> plain".html_safe)

      expect(result).to eq("&lt;img src=x onerror=alert(1)&gt; plain")
      expect(result).to be_html_safe
    end

    it "returns html_safe result when a match exists" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("closure")
      expect(result).to be_html_safe
    end

    it "wraps a real curated term from the production Glossary::TERMS list" do
      result = helper.glossary_wrap("Explain the concept of idempotency here.")

      expect(result).to include(
        %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(Glossary::TERMS['idempotency'])}")
      )
    end

    it "shares the first-occurrence set across fragments when given one" do
      stub_glossary("closure" => "A function with its scope.")
      seen = Set.new
      first = helper.glossary_wrap("A closure here.", seen: seen)
      second = helper.glossary_wrap("Another closure there.", seen: seen)
      expect(first).to include("gloss-term")
      expect(second).not_to include("gloss-term")
    end
  end

  describe "#glossary_wrap_prose" do
    it "leaves a term inside backticks as code and wraps it once in the prose around it" do
      stub_glossary("closure" => "A function with its scope.")
      html = helper.glossary_wrap_prose("A `closure` holds state; a closure is cheap, and a closure is common.")
      expect(html).to include("<code>closure</code>")
      expect(html.scan("gloss-term").size).to eq(1)
      expect(html.index("gloss-term")).to be > html.index("</code>")
    end

    it "keeps escaping inside code and prose" do
      stub_glossary("closure" => "x")
      expect(helper.glossary_wrap_prose("`<b>raw</b>` and <i>closure</i>")).to eq(%(<code>&lt;b&gt;raw&lt;/b&gt;</code> and &lt;i&gt;<span class="gloss-term" data-definition="x" tabindex="0" role="button" aria-label="closure: x">closure</span>&lt;/i&gt;))
    end

    it "returns html_safe output" do
      expect(helper.glossary_wrap_prose("plain")).to be_html_safe
    end

    it "escapes prose and code alike when no term matches" do
      stub_glossary("nonexistentword" => "y")
      expect(helper.glossary_wrap_prose("<i>plain</i> and `<b>raw</b>`"))
        .to eq("&lt;i&gt;plain&lt;/i&gt; and <code>&lt;b&gt;raw&lt;/b&gt;</code>")
    end

    it "shares a seen set with the prose around it, so a term already underlined there stays plain" do
      stub_glossary("closure" => "A function with its scope.")
      seen = Set.new
      helper.glossary_wrap("A closure first.", seen: seen)

      expect(helper.glossary_wrap_prose("Then a closure again.", seen: seen)).not_to include("gloss-term")
      expect(helper.glossary_wrap_prose("A fresh closure.")).to include("gloss-term")
    end
  end

  it "no longer defines prose_with_inline_code" do
    expect(helper).not_to respond_to(:prose_with_inline_code)
  end
end

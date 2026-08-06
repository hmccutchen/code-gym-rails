require "rails_helper"

RSpec.describe GlossaryHelper, type: :helper do
  # Most examples stub a small, controlled glossary rather than exercising the
  # real ~170-entry Glossary::TERMS list, so the fixtures stay readable and can
  # cover edge cases (overlapping terms, a malicious definition) that will
  # never actually appear in the real curated data. This only replaces the
  # DATA Glossary exposes — Glossary.lookup/TERM_PATTERN itself is untouched,
  # and one test below runs against the real, unstubbed Glossary::TERMS to
  # confirm the two are actually wired together correctly.
  def stub_glossary(terms)
    stub_const("Glossary::TERMS", terms)
    stub_const("Glossary::TERM_PATTERN",
      Regexp.union(terms.keys.sort_by { |t| -t.length }.map { |t| /\b#{Regexp.escape(t)}\b/i }))
  end

  describe "#glossary_wrap" do
    it "wraps the first case-insensitive match of a term in a span with its definition" do
      stub_glossary("closure" => "A function bundled with its surrounding variables.")
      result = helper.glossary_wrap("A Closure captures scope.")

      expect(result).to be_html_safe
      expect(result).to include('<span class="gloss-term" data-definition="A function bundled with its surrounding variables." tabindex="0" role="button" aria-label="Closure: A function bundled with its surrounding variables.">Closure</span>')
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
      # ERB::Util.html_escape is a documented no-op on ActiveSupport::SafeBuffer input, so if
      # `text` ever arrived pre-marked html_safe, every escape call in the assembly loop would
      # silently skip unless the helper strips that wrapper first.
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

    it "treats no-match result (plain text) as not html_safe by default" do
      stub_glossary("nonexistentword" => "y")
      result = helper.glossary_wrap("Nothing.")
      expect(result.html_safe?).to be(false)
    end

    it "returns html_safe result when a match exists" do
      stub_glossary("closure" => "def")
      result = helper.glossary_wrap("closure")
      expect(result).to be_html_safe
    end

    # Runs against the real, unstubbed Glossary::TERMS/TERM_PATTERN — confirms
    # the helper actually wires up to the production curated glossary, not
    # just to whatever a test stubs in.
    it "wraps a real curated term from the production Glossary::TERMS list" do
      result = helper.glossary_wrap("Explain the concept of idempotency here.")

      expect(result).to include(
        %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(Glossary::TERMS['idempotency'])}")
      )
    end
  end
end

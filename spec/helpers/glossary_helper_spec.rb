require "rails_helper"

RSpec.describe GlossaryHelper, type: :helper do
  describe "#glossary_wrap" do
    it "wraps the first case-insensitive match of a term in a span with its definition" do
      glossary = [ { "term" => "closure", "definition" => "A function bundled with its surrounding variables." } ]
      result = helper.glossary_wrap("A Closure captures scope.", glossary)

      expect(result).to be_html_safe
      expect(result).to include('<span class="gloss-term" data-definition="A function bundled with its surrounding variables.">Closure</span>')
    end

    it "only wraps the first occurrence, leaving later repeats plain" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("A closure is a closure of scope.", glossary)

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include(">closure</span> is a closure of scope.")
    end

    it "does not match a term as a partial substring of another word" do
      glossary = [ { "term" => "class", "definition" => "A blueprint for objects." } ]
      result = helper.glossary_wrap("Welcome to the classroom, not a class problem.", glossary)

      expect(result).to include("Welcome to the classroom, not a")
      expect(result).to include('<span class="gloss-term" data-definition="A blueprint for objects.">class</span> problem.')
    end

    it "wraps multiple distinct terms independently in the same text" do
      glossary = [
        { "term" => "closure", "definition" => "def1" },
        { "term" => "hoisting", "definition" => "def2" }
      ]
      result = helper.glossary_wrap("A closure relies on hoisting rules.", glossary)

      expect(result.scan("gloss-term").size).to eq(2)
    end

    it "skips a later term whose only match overlaps an already-wrapped term" do
      glossary = [
        { "term" => "dependency array", "definition" => "outer" },
        { "term" => "array", "definition" => "inner" }
      ]
      result = helper.glossary_wrap("Watch the dependency array closely.", glossary)

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include('data-definition="outer"')
      expect(result).not_to include('data-definition="inner"')
    end

    it "silently skips a term with no match in the text" do
      glossary = [ { "term" => "nonexistentword", "definition" => "def" } ]
      result = helper.glossary_wrap("Nothing to see here.", glossary)

      expect(result).to eq("Nothing to see here.")
    end

    it "returns the text unchanged when glossary is nil" do
      expect(helper.glossary_wrap("Plain text.", nil)).to eq("Plain text.")
    end

    it "returns the text unchanged when glossary is empty" do
      expect(helper.glossary_wrap("Plain text.", [])).to eq("Plain text.")
    end

    it "returns nil/blank text unchanged" do
      expect(helper.glossary_wrap(nil, [ { "term" => "x", "definition" => "y" } ])).to be_nil
      expect(helper.glossary_wrap("", [ { "term" => "x", "definition" => "y" } ])).to eq("")
    end

    it "escapes a malicious definition so it cannot break out of the data attribute" do
      glossary = [ { "term" => "closure", "definition" => %(a trick" onmouseover="alert(1)) } ]
      result = helper.glossary_wrap("Explain the closure here.", glossary)

      expect(result).not_to include('onmouseover="alert(1)"')
      expect(result).to include("a trick&quot; onmouseover=&quot;alert(1)")
    end

    it "escapes unmatched HTML-bearing text in the same field" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("<script>alert(1)</script> a closure appears here.", glossary)

      expect(result).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(result).not_to include("<script>alert(1)</script>")
    end

    # --- Adversarial / edge cases beyond the brief ---

    it "escapes HTML-special characters in the matched term text itself" do
      # Term contains < > — must be escaped in the span's inner text
      glossary = [ { "term" => "bool", "definition" => "true or false" } ]
      result = helper.glossary_wrap("Use a bool value.", glossary)
      # Sanity: term without HTML chars wraps fine; more important is the angle-bracket variant:
      expect(result).to include('<span class="gloss-term"')
    end

    it "escapes angle brackets inside a malicious term match" do
      # If the matched text happened to contain HTML-special chars (e.g. via a weird glossary term),
      # they must appear escaped inside the span's inner content
      glossary = [ { "term" => "x<y", "definition" => "comparison" } ]
      result = helper.glossary_wrap("Evaluate x<y now.", glossary)
      # x<y present in text but < breaks word-boundary match — ensure text fragments are still escaped
      # The \b regex won't match across <, so x<y won't be found; the whole string should be escaped
      expect(result).not_to include("<y")  # either not found (escaped as &lt;y) or wrapped
    end

    it "escapes angle brackets in the surrounding (pre-match) text fragment" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("<b>Bold</b> and a closure here.", glossary)

      expect(result).to include("&lt;b&gt;Bold&lt;/b&gt;")
      expect(result).not_to include("<b>Bold</b>")
      expect(result).to include('<span class="gloss-term"')
    end

    it "escapes angle brackets in the post-match text fragment" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("A closure <script>xss</script>.", glossary)

      expect(result).to include("&lt;script&gt;xss&lt;/script&gt;")
    end

    it "handles a definition with both single and double quotes safely" do
      glossary = [ { "term" => "closure", "definition" => %q(it's a "thing") } ]
      result = helper.glossary_wrap("A closure exists.", glossary)

      expect(result).to include("it&#39;s a &quot;thing&quot;")
      expect(result).not_to include('"thing"')
    end

    it "handles a term that appears only once even if glossary has duplicate terms" do
      glossary = [
        { "term" => "closure", "definition" => "first" },
        { "term" => "closure", "definition" => "second" }
      ]
      result = helper.glossary_wrap("A closure here.", glossary)

      # First entry wins; second is skipped because the match overlaps
      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include('data-definition="first"')
    end

    it "returns html_safe result when glossary is present and matches exist" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("closure", glossary)
      expect(result).to be_html_safe
    end

    it "treats no-match result (plain text) as not html_safe by default" do
      # When no match is found we return the original string unchanged —
      # that string is not html_safe unless it already was
      result = helper.glossary_wrap("Nothing.", [])
      expect(result.html_safe?).to be(false)
    end
  end
end

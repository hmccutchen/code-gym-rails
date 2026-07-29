# Wraps each glossary term's first case-insensitive, word-boundary match in
# `text` with a <span class="gloss-term" data-definition="..."> that the
# tooltip CSS/JS (in the layout) reads. Operates on the raw, un-escaped
# `text` — never on already-escaped HTML, since escaping entities can shift
# \b word-boundary positions — and escapes every resulting fragment (plain
# text and span attributes) individually before assembling the final string.
# The result is marked .html_safe only after that escaping, so nothing in
# `text` or `glossary` (both may be AI-generated) can ever break out of the
# surrounding markup.
module GlossaryHelper
  def glossary_wrap(text, glossary)
    return text if text.blank? || glossary.blank?

    matches = []
    glossary.each do |entry|
      term       = entry["term"]
      definition = entry["definition"]
      next if term.blank? || definition.blank?

      match = text.match(/\b#{Regexp.escape(term)}\b/i)
      next unless match

      range = match.begin(0)...match.end(0)
      next if matches.any? { |m| ranges_overlap?(m[:range], range) }

      matches << { range: range, definition: definition }
    end

    return text if matches.empty?

    matches.sort_by! { |m| m[:range].begin }

    result = +""
    cursor = 0
    matches.each do |m|
      result << ERB::Util.html_escape(text[cursor...m[:range].begin])
      matched_text = text[m[:range]]
      result << %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(m[:definition])}">#{ERB::Util.html_escape(matched_text)}</span>)
      cursor = m[:range].end
    end
    result << ERB::Util.html_escape(text[cursor..])

    result.html_safe
  end

  private

  def ranges_overlap?(a, b)
    a.begin < b.end && b.begin < a.end
  end
end

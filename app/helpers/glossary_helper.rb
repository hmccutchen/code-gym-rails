# Wraps each curated Glossary::TERMS match's first case-insensitive,
# word-boundary occurrence in `text` with a <span class="gloss-term"
# data-definition="..."> that the tooltip CSS/JS (in the layout) reads.
# Scans against the full curated glossary — not an AI-selected subset — via
# Glossary::TERM_PATTERN, a single alternation regex compiled once at load
# rather than looping per term on every render. Operates on the raw,
# un-escaped `text` — never on already-escaped HTML, since escaping entities
# can shift word-boundary positions — and escapes every resulting fragment
# (plain text and span attributes) individually before assembling the final
# string. The result is marked .html_safe only after that escaping, so
# nothing in `text` can ever break out of the surrounding markup.
#
# Each span also carries tabindex="0", role="button", and an aria-label of
# "term: definition" so the tooltip is reachable and announced for keyboard
# and screen-reader users, not just mouse/touch — the layout's CSS shows the
# tooltip on :focus-visible in addition to :hover/.gloss-open, and its JS
# toggles .gloss-open on Enter/Space in addition to click/tap.
module GlossaryHelper
  def glossary_wrap(text)
    return text if text.blank?

    # Strip any ActiveSupport::SafeBuffer wrapper unconditionally: html_escape
    # is a no-op on already-html_safe input, which would silently skip every
    # escape call below if `text` ever arrived pre-marked safe.
    text = text.to_str

    matches = []
    seen_terms = {}
    text.to_enum(:scan, Glossary::TERM_PATTERN).each do
      match = Regexp.last_match
      key = match[0].downcase
      next if seen_terms[key]
      seen_terms[key] = true
      matches << { range: match.begin(0)...match.end(0), definition: Glossary::TERMS[key] }
    end

    return text if matches.empty?

    result = +""
    cursor = 0
    matches.each do |m|
      result << ERB::Util.html_escape(text[cursor...m[:range].begin])
      matched_text = text[m[:range]]
      accessible_label = ERB::Util.html_escape("#{matched_text}: #{m[:definition]}")
      result << %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(m[:definition])}" tabindex="0" role="button" aria-label="#{accessible_label}">#{ERB::Util.html_escape(matched_text)}</span>)
      cursor = m[:range].end
    end
    result << ERB::Util.html_escape(text[cursor..])

    result.html_safe
  end
end

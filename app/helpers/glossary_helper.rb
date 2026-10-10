# Works on raw text and escapes each fragment before marking the result html_safe, so `text` can't break the markup.
module GlossaryHelper
  def glossary_wrap(text)
    return text if text.blank?

    # html_escape is a no-op on html_safe input, so a SafeBuffer would silently skip every escape below.
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

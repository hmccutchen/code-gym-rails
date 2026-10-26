# Works on raw text and escapes each fragment before marking the result html_safe, so `text` can't break the markup.
module GlossaryHelper
  def glossary_wrap(text, seen: Set.new)
    return text if text.blank?

    # html_escape is a no-op on html_safe input, so a SafeBuffer would silently skip every escape below.
    text = text.to_str

    matches = []
    text.to_enum(:scan, Glossary::TERM_PATTERN).each do
      match = Regexp.last_match
      key = Glossary.key_for(match[0])
      next unless seen.add?(key)
      matches << { range: match.begin(0)...match.end(0), definition: Glossary.definition_for(match[0]) }
    end

    return ERB::Util.html_escape(text) if matches.empty?

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

  def glossary_wrap_prose(text)
    seen = Set.new
    segments = text.to_str.split(SyntaxHighlightingHelper::INLINE_CODE).each_with_index.map do |segment, index|
      index.odd? ? content_tag(:code, segment) : glossary_wrap(segment, seen: seen)
    end
    safe_join(segments)
  end
end

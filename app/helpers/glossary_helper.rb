module GlossaryHelper
  def glossary_wrap(text, seen: Set.new)
    return text if text.blank? || !text.respond_to?(:to_str)

    # safe_join and tag.span leave html_safe input unescaped, so a SafeBuffer could carry markup through.
    text = text.to_str

    matches = []
    text.to_enum(:scan, Glossary::TERM_PATTERN).each do
      match = Regexp.last_match
      key = Glossary.key_for(match[0])
      next unless seen.add?(key)
      matches << { range: match.begin(0)...match.end(0), definition: Glossary.definition_for(match[0]) }
    end

    return ERB::Util.html_escape(text) if matches.empty?

    pieces = []
    cursor = 0
    matches.each do |m|
      pieces << text[cursor...m[:range].begin] << glossary_term_tag(text[m[:range]], m[:definition])
      cursor = m[:range].end
    end
    safe_join(pieces << text[cursor..])
  end

  def section_glossary_wrap(text, kind:, submitted:)
    submitted || kind.glossary_shown_before_submission? ? glossary_wrap(text) : text
  end

  def glossary_wrap_prose(text, seen: Set.new)
    segments = text.to_str.split(SyntaxHighlightingHelper::INLINE_CODE).each_with_index.map do |segment, index|
      index.odd? ? tag.code(segment) : glossary_wrap(segment, seen: seen)
    end
    safe_join(segments)
  end

  private

  def glossary_term_tag(term, definition)
    tag.span(term, class: "gloss-term", data: { definition: }, tabindex: 0, role: "button",
                   aria: { label: "#{term}: #{definition}" })
  end
end

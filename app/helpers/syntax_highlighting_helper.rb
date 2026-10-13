module SyntaxHighlightingHelper
  # A nil language highlights as plain text.
  def highlighted_code(code, language)
    content_tag(:code, CodeHighlight.html(code, lexer: CodeHighlight.lexer_for(language)), class: "highlight")
  end

  INLINE_CODE = /`([^`\n]+)`/

  def prose_with_inline_code(text)
    safe_join(text.split(INLINE_CODE).each_with_index.map { |segment, index| index.odd? ? content_tag(:code, segment) : segment })
  end
end

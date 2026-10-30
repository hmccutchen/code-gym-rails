module SyntaxHighlightingHelper
  # A nil language highlights as plain text.
  def highlighted_code(code, language, changed: [])
    content_tag(:code, CodeHighlight.html(code, lexer: CodeHighlight.lexer_for(language), changed: changed), class: "highlight")
  end

  INLINE_CODE = /`([^`\n]+)`/
end

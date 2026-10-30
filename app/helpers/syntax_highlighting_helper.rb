module SyntaxHighlightingHelper
  # A nil language highlights as plain text.
  def highlighted_code(code, language, changed: [], number_width: nil)
    html = CodeHighlight.html(code, lexer: CodeHighlight.lexer_for(language), changed: changed)
    return content_tag(:code, html, class: "highlight") unless number_width

    content_tag(:code, html, class: "highlight numbered", style: "--number-width: #{number_width}")
  end

  INLINE_CODE = /`([^`\n]+)`/
end

module SyntaxHighlightingHelper
  # A nil language highlights as plain text.
  def highlighted_code(code, language)
    content_tag(:code, CodeHighlight.html(code, lexer: CodeHighlight.lexer_for(language)), class: "highlight")
  end
end

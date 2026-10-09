module SyntaxHighlightingHelper
  # The <code> element for one block, highlighted on the server. `language`
  # is the exercise or reference language; nil highlights as plain text.
  def highlighted_code(code, language)
    content_tag(:code, CodeHighlight.html(code, lexer: CodeHighlight.lexer_for(language)), class: "highlight")
  end
end

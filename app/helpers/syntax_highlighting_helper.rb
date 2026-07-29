# Maps this app's exercise/reference language keys to the highlight.js language
# name the shared syntax-highlighting script registers. Kept as an explicit
# closed map rather than passing the app's own key straight through — "ruby_rails"
# isn't a highlight.js language name, and "architecture" (pseudocode) must
# resolve to nil so the script never attempts to highlight it.
module SyntaxHighlightingHelper
  HLJS_LANGUAGES = {
    "ruby_rails" => "ruby",
    "javascript" => "javascript"
  }.freeze

  def hljs_language(language)
    HLJS_LANGUAGES[language]
  end
end

# Highlights a code block on the server with Rouge. The one place code becomes
# HTML: Rouge escapes every token, and only that output is marked safe.
# Cached by the code's digest, so a stored exercise is highlighted once, and
# never written back to the row it came from.
module CodeHighlight
  # Part of the cache key. Raise it when the markup or the token classes the
  # layout's theme reads change, so no page serves HTML from the old shape.
  VERSION = 1

  # Exercise and reference languages to Rouge lexers. Anything else, such as
  # architecture pseudocode or a hand-written lesson, is plain text.
  LEXERS = {
    "ruby_rails" => "ruby",
    "javascript" => "javascript"
  }.freeze

  def self.lexer_for(language)
    LEXERS[language]
  end

  # The highlighted lines of `code`, safe to put inside a <code>. An unknown
  # or missing lexer name falls back to plain text, which still escapes.
  def self.html(code, lexer:)
    code = code.to_s
    rouge_lexer = Rouge::Lexer.find(lexer.to_s) || Rouge::Lexers::PlainText
    key = [ "code_highlight", VERSION, rouge_lexer.tag, Digest::SHA256.hexdigest(code) ]
    Rails.cache.fetch(key) { LineFormatter.new.format(rouge_lexer.new.lex(code)) }.html_safe
  end

  # One <span class="code-line"> per source line, carrying its leading columns
  # as --indent, which the layout turns into a hanging indent for a wrapped
  # line. A blank line holds its own newline so it keeps its height and
  # survives a copy. Strings and comments sit inside .code-literal, which the
  # line-fitting script leaves alone.
  class LineFormatter < Rouge::Formatter
    TAB_COLUMNS = 8
    LITERALS = [ Rouge::Token::Tokens::Literal::String, Rouge::Token::Tokens::Comment ].freeze
    SYMBOL = Rouge::Token::Tokens::Literal::String::Symbol

    def initialize
      @tokens = Rouge::Formatters::HTML.new
    end

    def stream(tokens)
      token_lines(tokens) { |line| yield line_html(line) }
    end

    private

    def line_html(line)
      body = line.map { |token, text| span(token, text) }.join
      indent = leading_columns(line.map(&:last).join)
      %(<span class="code-line" style="--indent: #{indent}">#{body.presence || "\n"}</span>)
    end

    def span(token, text)
      html = @tokens.span(token, text)
      literal?(token) ? %(<span class="code-literal">#{html}</span>) : html
    end

    # A symbol is lexed as a string, but `kind:   value` pads after one.
    def literal?(token)
      LITERALS.any? { |literal| literal.matches?(token) } && !SYMBOL.matches?(token)
    end

    def leading_columns(text)
      text[/\A[ \t]*/].each_char.sum { |char| char == "\t" ? TAB_COLUMNS : 1 }
    end
  end
end

# Highlights a code block on the server with Rouge. The one place code becomes
# HTML: Rouge escapes every token, and only that output is marked safe.
# Never written back to the row the code came from.
module CodeHighlight
  # In this process's memory, not Rails.cache: production's Solid Cache would
  # make every block on a page its own database query, and /history renders
  # dozens. Losing it on a deploy costs only highlighting again, a few
  # milliseconds a block, and a new deploy can never serve the old markup.
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes)

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
    key = [ rouge_lexer.tag, Digest::SHA256.hexdigest(code) ]
    CACHE.fetch(key) { LineFormatter.new.format(rouge_lexer.new.lex(code)) }.html_safe
  end

  # One <span class="code-line"> per source line, carrying its leading columns
  # as --indent, which the layout turns into a hanging indent for a wrapped
  # line. A blank line holds its own newline so it keeps its height and
  # survives a copy.
  #
  # Two marks prepare a line for a narrow screen, and neither falls inside a
  # string or a comment. Code often pads names so a column lines up (`kind
  # = value` under `description = value`); every space after the first in such
  # a run goes in a .code-align-extra, which the layout hides once the block
  # wraps, so the text and a copy keep the original line. A long call chain has
  # no space to wrap at, so a <wbr> after each `.` or `(` gives it a better
  # place than mid-name.
  class LineFormatter < Rouge::Formatter
    TAB_COLUMNS = 8
    LITERALS = [ Rouge::Token::Tokens::Literal::String, Rouge::Token::Tokens::Comment ].freeze
    SYMBOL = Rouge::Token::Tokens::Literal::String::Symbol
    TEXT = Rouge::Token::Tokens::Text
    ALIGNMENT_RUN = /(?<=\S) {2,}(?==|#|\/\/)|(?<=[:,=]) {2,}(?=\S)/
    CHAIN_BREAK = /(?<=[.(])(?=[^\s.(])/

    def initialize
      @tokens = Rouge::Formatters::HTML.new
    end

    def stream(tokens)
      token_lines(tokens) { |line| yield line_html(line) }
    end

    private

    def line_html(line)
      text = line.map(&:last).join
      literal = line.flat_map { |token, value| [ literal?(token) ] * value.length }
      marks = Marks.new(alignment_padding(text, literal), chain_breaks(text, literal))
      offset = 0
      body = line.map do |token, value|
        prefix = marks.breaks.include?(offset) ? "<wbr>" : ""
        inner = marks.html(value, offset) { |segment| @tokens.span(TEXT, segment) }
        offset += value.length
        prefix + (token == TEXT ? inner : @tokens.safe_span(token, inner))
      end.join
      %(<span class="code-line" style="--indent: #{leading_columns(text)}">#{body.presence || "\n"}</span>)
    end

    # A symbol is lexed as a string, but `kind:   value` pads after one.
    def literal?(token)
      LITERALS.any? { |literal| literal.matches?(token) } && !SYMBOL.matches?(token)
    end

    def alignment_padding(text, literal)
      matches(text, ALIGNMENT_RUN).reject { |run| literal[run].any? }.flat_map { |run| (run.begin + 1...run.end).to_a }.to_set
    end

    def chain_breaks(text, literal)
      matches(text, CHAIN_BREAK).map(&:begin).reject { |offset| literal[offset - 1] }.to_set
    end

    def matches(text, pattern)
      text.to_enum(:scan, pattern).map { Regexp.last_match.then { |match| match.begin(0)...match.end(0) } }
    end

    def leading_columns(text)
      text[/\A[ \t]*/].each_char.sum { |char| char == "\t" ? TAB_COLUMNS : 1 }
    end

    # The character offsets in a line to hide once it wraps, and those to put
    # a break point before, applied to one token's text at a time. A break at
    # a token's first character goes before its span, which line_html adds.
    Marks = Struct.new(:hidden, :breaks) do
      def html(value, start)
        value.each_char.with_index(start).slice_when { |(_, a), (_, b)| hidden.include?(a) != hidden.include?(b) || breaks.include?(b) }
          .map do |chunk|
            offset = chunk.first.last
            segment = yield chunk.map(&:first).join
            segment = %(<span class="code-align-extra">#{segment}</span>) if hidden.include?(offset)
            breaks.include?(offset) && offset != start ? "<wbr>#{segment}" : segment
          end.join
      end
    end
  end
end

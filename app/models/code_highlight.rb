module CodeHighlight
  # Process memory, not Rails.cache: Solid Cache would make every block on a page its own database query.
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes)

  LEXERS = {
    "ruby_rails" => "ruby",
    "javascript" => "javascript"
  }.freeze

  def self.lexer_for(language)
    LEXERS[language]
  end

  # An unknown or missing lexer falls back to plain text, which still escapes.
  def self.html(code, lexer:, changed: [])
    code = code.to_s
    rouge_lexer = Rouge::Lexer.find(lexer.to_s) || Rouge::Lexers::PlainText
    key = [ rouge_lexer.tag, Digest::SHA256.hexdigest(code), changed.sort.join(",") ]
    CACHE.fetch(key) { LineFormatter.new(changed: changed).format(rouge_lexer.new.lex(code)) }.html_safe
  end

  # Alignment padding and <wbr> marks never go inside a string or a comment.
  class LineFormatter < Rouge::Formatter
    TAB_COLUMNS = 8
    LITERALS = [ Rouge::Token::Tokens::Literal::String, Rouge::Token::Tokens::Comment ].freeze
    SYMBOL = Rouge::Token::Tokens::Literal::String::Symbol
    TEXT = Rouge::Token::Tokens::Text
    ALIGNMENT_RUN = /(?<=\S) {2,}(?==|#|\/\/)|(?<=[:,=]) {2,}(?=\S)/
    CHAIN_BREAK = /(?<=[.(])(?=[^\s.(])/

    def initialize(changed: [])
      @tokens = Rouge::Formatters::HTML.new
      @changed = changed.to_set
    end

    def stream(tokens)
      token_lines(tokens).with_index(1) { |line, number| yield line_html(line, changed: @changed.include?(number)) }
    end

    private

    def line_html(line, changed:)
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
      %(<span class="#{changed ? "code-line code-line-changed" : "code-line"}" style="--indent: #{leading_columns(text)}">#{body.presence || "\n"}</span>)
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

    # A break at a token's first character goes before its span, which line_html adds.
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

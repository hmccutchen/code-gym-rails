# Design notes: docs/code-notes/app/models/key_reference.md
module KeyReference
  CONSTANT = /[A-Z]\w*(?:::[A-Z]\w*)*/

  METHOD = /[a-z_]\w*[?!=]?/

  CALL = /\A(#{CONSTANT}(?:\.[a-z_]\w*)*)\.(#{METHOD})\z/

  INSTANCE_METHOD = /\A(#{CONSTANT})#(#{METHOD})\z/

  ELISION = "...".freeze

  RUBY = "ruby_rails".freeze

  def self.resolves?(span, code:, language:)
    return false unless language == RUBY

    span = span.strip
    if span.include?(ELISION) then elided?(span, code, language)
    elsif (match = span.match(CALL)) then called?(match[1], match[2], code)
    elsif (match = span.match(INSTANCE_METHOD)) then defined_in?(match[1], match[2], code)
    else false
    end
  end

  def self.elided?(span, code, language)
    pieces = span.split(ELISION).map { |piece| KeyQuote.normalize(piece, language: language) }
                 .select { |piece| piece.length >= PlantedKey::MIN_QUOTE_LENGTH }
    shown = KeyQuote.normalize(code, language: language)
    position = 0
    pieces.any? && pieces.all? { |piece| (found = shown.index(piece, position)) && (position = found + piece.length) }
  end

  def self.called?(receiver, name, code)
    receiver_pattern = /(?<![\w:.])#{Regexp.escape(receiver)}(?![\w])/
    name_pattern = /[.:]#{Regexp.escape(name)}(?![\w?!=])/
    code.each_line.any? { |line| line.match?(receiver_pattern) && line.match?(name_pattern) }
  end

  def self.defined_in?(constant, name, code)
    body = code[/^[ \t]*class #{Regexp.escape(constant)}\b.*?(?=^class\s|\z)/m]
    body.present? && body.match?(/^[ \t]*def #{Regexp.escape(name)}(?![\w?!=])/)
  end

  private_class_method :elided?, :called?, :defined_in?
end

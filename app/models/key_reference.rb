# Design notes: docs/code-notes/app/models/key_reference.md
module KeyReference
  CONSTANT = /[A-Z]\w*(?:::[A-Z]\w*)*/

  METHOD = /[a-z_]\w*[?!=]?/

  CALL = /\A(#{CONSTANT}(?:\.[a-z_]\w*)*)\.(#{METHOD})\z/

  INSTANCE_METHOD = /\A(#{CONSTANT})#(#{METHOD})\z/

  ELISION = "...".freeze

  ARGUMENTS_ELIDED = "(...)".freeze

  RUBY = "ruby_rails".freeze

  def self.resolves?(span, code:, language:)
    return false unless language == RUBY

    span = span.strip
    named = span.delete_suffix(ARGUMENTS_ELIDED)
    if (match = named.match(CALL)) then called?(match[1], match[2], code)
    elsif (match = named.match(INSTANCE_METHOD)) then defined_in?(match[1], match[2], code)
    elsif span.include?(ELISION) then elided?(span, code, language)
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
    receiver = Regexp.escape(receiver)
    name = /#{Regexp.escape(name)}(?![\w?!=])/
    call = /(?<![\w:.])#{receiver}\s*\.\s*#{name}/
    stub = /\b(?:allow|expect)\(\s*#{receiver}\s*\)\s*\.\s*(?:to|not_to|to_not)\s+(?:receive|have_received)\(\s*:#{name}/
    code.match?(call) || code.match?(stub)
  end

  def self.defined_in?(constant, name, code)
    lines = code.lines
    start = lines.index { |line| line.match?(/^\s*class\s+#{Regexp.escape(constant)}(?=\s|<|;|$)/) }
    return false unless start

    indent = lines[start][/\A\s*/]
    finish = (start + 1...lines.size).find { |index| lines[index].match?(/\A#{indent}end\b/) } || lines.size
    lines[start + 1...finish].any? { |line| line.match?(/^\s*def\s+#{Regexp.escape(name)}(?![\w?!=])/) }
  end

  private_class_method :elided?, :called?, :defined_in?
end

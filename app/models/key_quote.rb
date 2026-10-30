# Design notes: docs/code-notes/app/models/key_quote.md
module KeyQuote
  CLOSER_COMMA = /,(?=[)\]}])/

  BARE_ARROW_PARAMETER = /(\()[A-Za-z_$][\w$]*(\))=>/

  def self.normalize(text, language:) = normalized_with_lines(text, language: language).first

  def self.find(code, quote, language:)
    wanted = normalize(quote, language: language)
    return if wanted.empty?

    shown, lines = normalized_with_lines(code, language: language)
    start = shown.index(wanted)
    lines[start]..lines[start + wanted.length - 1] if start
  end

  def self.line(code, quote, language:)
    wanted = normalize(quote, language: language)
    return if wanted.empty?

    source = code.lines
    matches = candidate_ranges(source, language).select do |range|
      normalize(source[(range.begin - 1)..(range.end - 1)].join, language: language) == wanted
    end
    matches.sole if matches.one?
  end

  # Runs start and end on lines with content, so blank padding adds no runs and can't pad one into a second match.
  def self.candidate_ranges(source, language)
    ends = source.each_index.select { |index| normalize(source[index], language: language).present? }.map(&:succ)
    return ends.map { |number| number..number } unless language == "javascript"

    ends.each_with_index.flat_map { |first, index| ends.drop(index).map { |last| first..last } }
  end

  def self.normalized_with_lines(text, language:)
    chars = text.each_line.with_index(1).flat_map { |line, number| line.chars.map { |char| [ char, number ] } }
    chars = chars.reject { |char, _| char.match?(/\s/) }
    chars = javascript_rules(chars) if language == "javascript"
    chars = chars[0...-1] if chars.last&.first == ","
    [ chars.map(&:first).join, chars.map(&:last) ]
  end

  def self.javascript_rules(chars)
    chars = chars.map { |char, number| [ char == "'" ? '"' : char, number ] }
    chars = chars[0...-1] if chars.last&.first == ";"
    text = chars.map(&:first).join
    dropped = text.enum_for(:scan, CLOSER_COMMA).map { Regexp.last_match.begin(0) }
    dropped += text.enum_for(:scan, BARE_ARROW_PARAMETER).flat_map { [ Regexp.last_match.begin(1), Regexp.last_match.begin(2) ] }
    chars.reject.with_index { |_, index| dropped.include?(index) }
  end

  private_class_method :candidate_ranges, :normalized_with_lines, :javascript_rules
end

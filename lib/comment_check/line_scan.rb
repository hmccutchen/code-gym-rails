require_relative "located"

module CommentCheck
  module LineScan
    QUOTES = [ "\"", "'", "`" ].freeze

    module_function

    def marker_outside_quotes(line, marker, require_space: true)
      quote = nil
      index = 0
      while index < line.length
        char = line[index]
        if quote
          index += 1 if char == "\\"
          quote = nil if char == quote
        elsif QUOTES.include?(char)
          quote = char
        elsif line[index, marker.length] == marker && (!require_space || index.zero? || line[index - 1].match?(/\s/))
          return index
        end
        index += 1
      end
      nil
    end

    def line_comments(text, marker, require_space:)
      offset = 0
      text.lines.filter_map do |line|
        column = marker_outside_quotes(line, marker, require_space: require_space)
        start = offset + column if column
        offset += line.length
        Located.comment(text, start, start + line.length - column, 0) if column
      end
    end

    def delimited_comments(text, opening, closing, offset: 0)
      text.to_enum(:scan, /#{Regexp.escape(opening)}.*?#{Regexp.escape(closing)}/m).map do
        match = Regexp.last_match
        Located.comment(text, match.begin(0), match.end(0), offset)
      end
    end
  end
end

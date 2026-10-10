module CommentCheck
  module LineScan
    QUOTES = [ "\"", "'", "`" ].freeze

    module_function

    def marker_outside_quotes(line, marker)
      quote = nil
      index = 0
      while index < line.length
        char = line[index]
        if quote
          index += 1 if char == "\\"
          quote = nil if char == quote
        elsif QUOTES.include?(char)
          quote = char
        elsif line[index, marker.length] == marker && (index.zero? || line[index - 1].match?(/\s/))
          return index
        end
        index += 1
      end
      nil
    end

    def line_comments(lines, marker, offset: 0)
      lines.each_with_index.filter_map do |line, index|
        column = marker_outside_quotes(line, marker) or next
        number = index + 1 + offset
        Comment.new(first_line: number, last_line: number, own_line: line[0...column].strip.empty?)
      end
    end

    def delimited_comments(text, opening, closing, offset: 0)
      text.to_enum(:scan, /#{Regexp.escape(opening)}.*?#{Regexp.escape(closing)}/m).map do
        start = Regexp.last_match.begin(0)
        before = text[0...start]
        first = before.count("\n") + 1 + offset
        Comment.new(first_line: first, last_line: first + Regexp.last_match[0].count("\n"),
                    own_line: before.split("\n", -1).last.to_s.strip.empty?)
      end
    end
  end
end

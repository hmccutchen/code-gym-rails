require_relative "located"

module CommentCheck
  module CStyleScan
    QUOTES = [ "\"", "'", "`" ].freeze

    module_function

    def comments(text, line_comments:, offset: 0)
      found = []
      quote = nil
      index = 0
      while index < text.length
        if quote
          quote = nil if text[index] == quote || (text[index] == "\n" && quote != "`")
          index += 1 if text[index] == "\\"
        elsif QUOTES.include?(text[index])
          quote = text[index]
        elsif text[index, 2] == "/*" || (line_comments && text[index, 2] == "//")
          stop = comment_end(text, index)
          found << Located.comment(text, index, stop, offset)
          index = stop
          next
        end
        index += 1
      end
      found
    end

    def comment_end(text, start)
      if text[start, 2] == "/*"
        close = text.index("*/", start + 2)
        close ? close + 2 : text.length
      else
        text.index("\n", start) || text.length
      end
    end
  end
end

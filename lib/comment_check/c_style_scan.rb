require_relative "located"

module CommentCheck
  module CStyleScan
    QUOTES = [ "\"", "'", "`" ].freeze
    REGEX_PRECEDERS = "(,=:[!&|?{};+-*%<>~^".chars.freeze
    REGEX_KEYWORDS = /(?<![\w$])(?:return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await)\z/
    LOOKBEHIND = 32

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
        elsif line_comments && text[index] == "/" && (stop = regex_end(text, index))
          index = stop
          next
        end
        index += 1
      end
      found
    end

    def regex_end(text, start)
      return unless regex_start?(text, start)

      in_class = false
      index = start + 1
      while (char = text[index]) && char != "\n"
        return index + 1 if char == "/" && !in_class

        in_class = char == "[" || (in_class && char != "]")
        index += char == "\\" ? 2 : 1
      end
    end

    def regex_start?(text, start)
      before = text[[ start - LOOKBEHIND, 0 ].max...start].rstrip
      return false if postfix_step?(text, start)

      before.empty? || REGEX_PRECEDERS.include?(before[-1]) || regex_keyword?(before)
    end

    def regex_keyword?(before)
      keyword = before.match(REGEX_KEYWORDS) or return false
      !before[0...keyword.begin(0)].rstrip.end_with?(".")
    end

    def postfix_step?(text, start)
      line_start = (text.rindex("\n", start - 1) || -1) + 1
      text[line_start...start].rstrip.end_with?("++", "--")
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

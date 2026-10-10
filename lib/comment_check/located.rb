require_relative "comment"

module CommentCheck
  module Located
    module_function

    def comment(text, start, stop, offset)
      before = text[0...start]
      first = before.count("\n") + 1 + offset
      body = text[start...stop]
      Comment.new(first_line: first, last_line: first + body.chomp.count("\n"),
                  own_line: before[/[^\n]*\z/].strip.empty?, text: body)
    end
  end
end

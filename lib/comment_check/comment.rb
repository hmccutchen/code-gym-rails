module CommentCheck
  Comment = Struct.new(:first_line, :last_line, :own_line, keyword_init: true) do
    def multi_line?
      last_line != first_line
    end
  end
end

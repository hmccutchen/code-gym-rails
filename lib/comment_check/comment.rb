module CommentCheck
  Comment = Struct.new(:first_line, :last_line, :own_line, :text, keyword_init: true) do
    def multi_line?
      last_line != first_line
    end

    def body
      text.strip.sub(%r{\A(<%#|<!--|/\*|//|#)\s*}, "").sub(%r{\s*(%>|-->|\*/)\z}, "")
    end
  end
end

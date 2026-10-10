require "rubocop"

module RuboCop
  module Cop
    module CodeGym
      module ProseComments
        private

        def prose_comments
          processed_source.comments.reject { |comment| tooling?(comment) }
        end

        def own_line?(comment)
          processed_source.lines[comment.loc.line - 1][0...comment.loc.column].strip.empty?
        end

        def last_line_of(comment)
          comment.loc.line + comment.text.chomp.count("\n")
        end

        def tooling?(comment)
          shebang?(comment) || MagicComment.parse(comment.text).any? || directive?(comment.text)
        end

        def directive?(text)
          text.strip.match?(DirectiveComment::DIRECTIVE_COMMENT_REGEXP)
        end

        def shebang?(comment)
          comment.loc.line == 1 && comment.text.start_with?("#!")
        end
      end
    end
  end
end

require "rubocop"

module RuboCop
  module Cop
    module CodeGym
      class SingleLineComment < Base
        MSG = "Keep each comment to a single line.".freeze

        def on_new_investigation
          comment_blocks.each do |block|
            add_offense(block.first.source_range.join(block.last.source_range)) if multi_line?(block)
          end
        end

        private

        def comment_blocks
          prose_comments.slice_when { |previous, current| !continues?(previous, current) }
        end

        def prose_comments
          processed_source.comments.reject { |comment| tooling?(comment) }
        end

        def tooling?(comment)
          shebang?(comment) || MagicComment.parse(comment.text).any? || comment.text.match?(DirectiveComment::DIRECTIVE_COMMENT_REGEXP)
        end

        def shebang?(comment)
          comment.loc.line == 1 && comment.text.start_with?("#!")
        end

        def continues?(previous, current)
          current.loc.line == previous.loc.last_line + 1 && own_line?(current)
        end

        def own_line?(comment)
          processed_source.lines[comment.loc.line - 1][0...comment.loc.column].strip.empty?
        end

        def multi_line?(block)
          block.size > 1 || block.first.loc.line != block.first.loc.last_line
        end
      end
    end
  end
end

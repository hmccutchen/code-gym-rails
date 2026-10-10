require_relative "prose_comments"

module RuboCop
  module Cop
    module CodeGym
      class SingleLineComment < Base
        include ProseComments

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

        def continues?(previous, current)
          current.loc.line == previous.loc.last_line + 1 && own_line?(current)
        end

        def multi_line?(block)
          block.size > 1 || block.first.loc.line != block.first.loc.last_line
        end
      end
    end
  end
end

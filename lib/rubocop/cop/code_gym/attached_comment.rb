require_relative "prose_comments"

module RuboCop
  module Cop
    module CodeGym
      class AttachedComment < Base
        include ProseComments

        MSG = "Put the comment directly above the code it discusses.".freeze

        def on_new_investigation
          prose_comments.each do |comment|
            add_offense(comment) if own_line?(comment) && !code_follows?(comment)
          end
        end

        private

        def code_follows?(comment)
          index = processed_source.lines.each_index.drop(last_line_of(comment)).find { |i| !directive?(processed_source.lines[i]) }
          !index.nil? && !processed_source.lines[index].strip.empty? && !comment_line_numbers.include?(index + 1)
        end

        def comment_line_numbers
          processed_source.comments.select { |comment| own_line?(comment) }
            .flat_map { |comment| (comment.loc.line..last_line_of(comment)).to_a }
        end
      end
    end
  end
end

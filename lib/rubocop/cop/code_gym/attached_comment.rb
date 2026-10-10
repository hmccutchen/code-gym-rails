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
          next_line = processed_source.lines[comment.loc.last_line]
          !next_line.nil? && !next_line.strip.empty? && !next_line.lstrip.start_with?("#")
        end
      end
    end
  end
end

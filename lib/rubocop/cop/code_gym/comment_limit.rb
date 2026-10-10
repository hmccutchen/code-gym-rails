require_relative "prose_comments"
require_relative "../../../comment_check/route_annotation"

module RuboCop
  module Cop
    module CodeGym
      class CommentLimit < Base
        include ProseComments

        MSG = "This file has %<count>d comments; the limit is %<max>d. Move the reasoning into docs.".freeze

        def on_new_investigation
          comments = prose_comments.reject { |comment| route_annotation?(comment) }
          return if comments.size <= max

          comments.drop(max).each { |comment| add_offense(comment, message: format(MSG, count: comments.size, max: max)) }
        end

        private

        def route_annotation?(comment)
          comment.text.delete_prefix("#").strip.match?(::CommentCheck::ROUTE_ANNOTATION)
        end

        def max
          cop_config.fetch("Max", 5)
        end
      end
    end
  end
end

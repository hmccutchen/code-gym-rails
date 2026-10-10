require_relative "prose_comments"

module RuboCop
  module Cop
    module CodeGym
      class CommentLimit < Base
        include ProseComments

        MSG = "This file has %<count>d comments; the limit is %<max>d. Move the reasoning into docs.".freeze

        ROUTE_ANNOTATION = %r{\A# (GET|POST|PUT|PATCH|DELETE)(/(GET|POST|PUT|PATCH|DELETE))* /\S*\z}

        def on_new_investigation
          comments = prose_comments.reject { |comment| comment.text.match?(ROUTE_ANNOTATION) }
          return if comments.size <= max

          comments.drop(max).each { |comment| add_offense(comment, message: format(MSG, count: comments.size, max: max)) }
        end

        private

        def max
          cop_config.fetch("Max", 5)
        end
      end
    end
  end
end

# Design notes: docs/code-notes/app/models/exercise_section/code_review/bug_hunt.md
module ExerciseSection::CodeReview::BugHunt
  MODE = :bug_hunt

  PURPOSE_FIELD = "purpose".freeze

  MAX_LINES = 10

  MAX_PURPOSE_LENGTH = 160

  RESULT_COMMENT = %r{(#|//)\s*(=>|->)}

  REFUSAL_CODES = %w[purpose_missing purpose_too_long bug_hunt_too_long output_shown].freeze

  OPTIONAL_KEY_FIELDS = { "witness" => %w[call expected returns], "looks_right_on" => %w[call expected] }.freeze

  FIXED_SNIPPET_FIELD = "fixed_snippet".freeze

  def self.mode?(mode) = mode == MODE

  def self.section?(section) = section.is_a?(Hash) && section.key?(PURPOSE_FIELD)

  def self.optional_key_fields(key)
    return {} unless key.is_a?(Hash)

    nested = OPTIONAL_KEY_FIELDS.to_h { |field, parts| [ field, PlantedKey.fields(key[field], parts) ] }
    nested.merge(FIXED_SNIPPET_FIELD => PlantedKey.text(key[FIXED_SNIPPET_FIELD])).compact
  end

  # Extended into CodeReview, so these run as its own class methods and can call its private refuse!.
  module Checks
    def reject_bug_hunt!(section)
      reject_bug_hunt_purpose!(section[PURPOSE_FIELD])
      reject_bug_hunt_snippet!(section["snippet"])
      drop_file_fields!(section)
    end

    def reject_bug_hunt_purpose!(purpose)
      refuse!("purpose_missing", "Bug hunt has no one-line purpose") unless usable_text?(purpose) && !purpose.strip.include?("\n")
      return if purpose.strip.length <= MAX_PURPOSE_LENGTH

      refuse!("purpose_too_long", "Bug hunt purpose runs #{purpose.strip.length} characters, past #{MAX_PURPOSE_LENGTH}")
    end

    def reject_bug_hunt_snippet!(snippet)
      refuse!("snippet_missing", "Bug hunt returned no usable snippet") unless usable_text?(snippet)

      lines = shown_lines(snippet)
      refuse!("bug_hunt_too_long", "Bug hunt snippet runs #{lines} lines, past #{MAX_LINES}") if lines > MAX_LINES
      refuse!("output_shown", "Bug hunt snippet shows a result in a comment") if snippet.match?(RESULT_COMMENT)
    end
  end
end

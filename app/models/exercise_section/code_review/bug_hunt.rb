module ExerciseSection::CodeReview::BugHunt
  MODE = :bug_hunt

  PURPOSE_FIELD = "purpose".freeze

  def self.mode?(mode) = mode == MODE

  def self.section?(section) = section.is_a?(Hash) && section.key?(PURPOSE_FIELD)
end

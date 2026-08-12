# Given a vague feature request, the engineer lists what they'd need
# clarified before writing a spec. Unscaffolded deliberately: a labeled
# scaffold would hint at the shape or count of the planted ambiguities (see
# AiService::AMBIGUITY_HUNT_PLANTED_COUNT). improved_code? is false — there's
# no "corrected code" for a clarifying-questions exercise.
class ExerciseSection::AmbiguityHunt < ExerciseSection
  def self.vocabulary_key
    :ambiguity_hunt
  end

  def self.improved_code?
    false
  end
end

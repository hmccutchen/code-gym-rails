# Restricted to the day's language security_concepts subset, never the full
# vocabulary — that restriction is what makes the interleaving with code_review
# deliberate rather than incidental.
class ExerciseSection::SecurityReview < ExerciseSection
  def self.vocabulary_key
    :security_concepts
  end
end

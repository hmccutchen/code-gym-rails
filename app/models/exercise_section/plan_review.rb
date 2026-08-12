# Given a short implementation plan with deliberately planted flaws, the
# engineer identifies what's wrong and what they'd push back on before
# approving. Scaffolded because the answer has two predictable parts — what's
# wrong, and what to push back on — the same reasoning that scaffolds
# Pattern/Architecture. Its review carries a revised plan as improved_code,
# the same shape every other scaffolded kind's review carries.
class ExerciseSection::PlanReview < ExerciseSection
  DEFAULT_SCAFFOLD = [
    "What's wrong:",
    "What you'd push back on before approving:"
  ].freeze

  def self.default_scaffold
    DEFAULT_SCAFFOLD
  end

  def self.vocabulary_key
    :plan_review
  end
end

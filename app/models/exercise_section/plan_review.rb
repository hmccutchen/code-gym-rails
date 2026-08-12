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

  # The reviewed artifact is a prose plan, so the "improvement" is a rewritten
  # plan — not source. Syntax-highlighting it as the day's language and calling
  # it "Improved code" would misdescribe it in both the review view and the
  # review email.
  def self.improved_code_label
    "Revised plan"
  end

  def self.improved_code_prose?
    true
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "plan_review": {
          "title":    "string — short name for the plan/decision under review",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "plan_excerpt": "string — a short prose implementation plan, framed as if written by an AI assistant, containing 2-3 planted flaws spanning levels: one real technical anti-pattern, one scope-creep item, one unflagged behavior change",
          "question": "string — what to evaluate before approving this plan",
          "answer_scaffold": ["string — a labelled part of a complete answer to THIS review", "string — another part"],
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        }
    SCHEMA
  end
end

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

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The fourth section is a PLAN REVIEW: "plan_excerpt" is a short prose implementation plan, framed as if written by an AI assistant, short enough to review in one sitting (2-4 short paragraphs or a short numbered list, never a full design doc). It must contain 2-3 planted flaws that span levels — one real technical anti-pattern, one scope-creep item, one unflagged behavior change — never three of the same category.
      - Choose the plan_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
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

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Plan Review (#{section["title"]}): #{section["question"]}
      Plan excerpt: #{section["plan_excerpt"]}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  def self.grading_note(section:, answer:)
    "Evaluate on whether they correctly identified the planted flaws (a technical anti-pattern, a scope-creep item, an unflagged behavior change) and whether their pushback is well-reasoned — not against one exact expected wording. \"improved_code\" for this section is a revised version of the plan that addresses what they missed."
  end
end

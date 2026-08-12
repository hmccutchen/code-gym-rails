# Restricted to the day's language security_concepts subset, never the full
# vocabulary — that restriction is what makes the interleaving with code_review
# deliberate rather than incidental.
class ExerciseSection::SecurityReview < ExerciseSection
  def self.vocabulary_key
    :security_concepts
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "security_review": {
          "title":        "string",
          "question":     "string — what security vulnerability exists here, and how would you mitigate it",
          "snippet":      "string — #{label} code, ~10-15 lines, containing one real, exploitable vulnerability",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "reference": {
            "tagline":      "string — bold one-liner",
            "explanation":  "string — 2-3 sentences",
            "code_example": "string — annotated #{label} code, ~15 lines",
            "senior_lens":  "string — when to reach for it / tradeoffs"
          }
        }
    SCHEMA
  end
end

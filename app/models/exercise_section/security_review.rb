# Restricted to the day's language security_concepts subset, never the full
# vocabulary — that restriction is what makes the interleaving with code_review
# deliberate rather than incidental.
class ExerciseSection::SecurityReview < ExerciseSection
  def self.vocabulary_key
    :security_concepts
  end

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The third section is a SECURITY REVIEW, not a general correctness check. The snippet must contain one real, exploitable vulnerability appropriate to #{label}. The question asks the engineer to identify the vulnerability AND propose a mitigation — not just "what's wrong with this code."
      - Choose the security_review concept from this vocabulary, exactly one — these are the ONLY concepts security_review may use, never one from code_review/pattern's broader vocabulary: #{vocabulary.join(", ")}
      - The security_review snippet should be realistic #{label} code, not a contrived toy example — the same bar as code_review's snippet.
    GUIDANCE
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

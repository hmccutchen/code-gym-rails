class ExerciseSection::CodeReview < ExerciseSection
  def self.diagrammable?
    true
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — #{label} code, ~10-15 lines",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "diagram":  "string — Mermaid source showing the structure this snippet describes, or an empty string if no diagram would help"
        }
    SCHEMA
  end
end

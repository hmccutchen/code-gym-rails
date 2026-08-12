class ExerciseSection::Challenge < ExerciseSection
  def self.diagrammable?
    true
  end

  # As in ParsonsProblem, the "each section's concept" line speaks for
  # code_review and pattern too. See issue #81.
  def self.generation_guidance(vocabulary:, language_vocabulary:, label:)
    <<~GUIDANCE.chomp
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{language_vocabulary.join(", ")}
    GUIDANCE
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "challenge": {
          "title":        "string",
          "question":     "string — what to implement",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "starter_code": "string — optional skeleton (empty string if none)",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "diagram": "string — Mermaid source showing the structure this scenario describes, or an empty string if no diagram would help"
        }
    SCHEMA
  end
end

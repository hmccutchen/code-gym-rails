class ExerciseSection::Challenge < ExerciseSection
  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  # Answered in code, so the textarea gets the monospace treatment.
  def self.answer_class
    "answer code-answer"
  end

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Choose the challenge concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
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

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Coding Challenge: #{section["question"]}
      #{answer_lines(answer, rating)}
    CONTEXT
  end
end

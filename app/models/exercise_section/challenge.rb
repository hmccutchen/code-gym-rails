class ExerciseSection::Challenge < ExerciseSection
  RUNG_GUIDANCE = {
    "junior" => "Write a direct implementation of the stated behavior using any supplied starter.",
    "mid_level" => "Read the requirements to derive the steps and handle the stated cases using any supplied starter.",
    "senior" => "Implement interacting requirements, preserving each stated behavior when they meet.",
    "principal_engineer" => "Implement the stated behavior while weighing its system-wide costs; no unstated production features are required."
  }.freeze

  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  def self.judge_task
    "Implement what the question asks from the starter code."
  end

  # Answered in code, so the textarea gets the monospace treatment.
  def self.answer_class
    "answer code-answer"
  end

  def self.code_fields
    %w[starter_code]
  end

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Choose the challenge concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.grading_note(section:, answer:)
    "Main point: code that does the task the question asks for.\n" \
    "Essential pieces: each requirement and behavior the question states. Naming, style and idiom are not essential unless the question asks for them."
  end

  def self.schema_fragment(label:, **)
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

  # Grading without the on-screen starter code misreads correct work as incomplete; both omitted when blank.
  def self.review_context(section:, answer:, rating:)
    [
      "Coding Challenge: #{section["question"]}",
      ("Scenario: #{section["scenario"]}" if section["scenario"].present?),
      ("Starter code they were given:\n#{section["starter_code"]}" if section["starter_code"].present?),
      answer_lines(answer, rating)
    ].compact.join("\n")
  end
end

class ExerciseSection::CodeReview < ExerciseSection
  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  # The only kind with a content mode. `artifact` is the day's language-
  # specific schema artifact (see AiService::LANGUAGE_CONFIG) and is read only
  # on a schema-review day.
  def self.generation_guidance(vocabulary:, label:, mode: nil, artifact: nil)
    <<~GUIDANCE.chomp
      #{content_instruction(label, mode, artifact)}
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.content_instruction(label, mode, artifact)
    case mode
    when :test_file
      "- The code_review snippet must be #{label} test code — a realistic test file exhibiting one real test smell, same question shape (\"what's the issue here, and how would you fix it\")."
    when :schema_review
      "- The code_review snippet must be #{artifact}, ~10-15 lines, containing one planted data-modeling flaw. Same question shape as any other code_review (\"what's the issue here, and how would you fix it\") — the engineer reviews the proposed change, not prose about it."
    else
      "- The code_review snippet must be realistic #{label} code — not toy examples."
    end
  end
  private_class_method :content_instruction

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

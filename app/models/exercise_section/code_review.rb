class ExerciseSection::CodeReview < ExerciseSection
  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  # Every day is built around code_review, and a set with no sections at all
  # fails DailyExercise's presence validation.
  def self.droppable?
    false
  end

  def self.judge_task
    "Find the one planted issue in the snippet and say how to fix it."
  end

  def self.planned_concept(mode: nil)
    mode == :schema_review ? "missing_index" : "n_plus_one"
  end

  def self.discovery?
    true
  end

  def self.prose_fields
    %w[scenario question teaching_note]
  end

  # The only kind with a content mode. `artifact` is the day's language-
  # specific schema artifact and `test_framework` its test-framework steer
  # (both from AiService::LANGUAGE_CONFIG); each is read only on the matching
  # mode. `source` is the RealSource excerpt today's snippet is grounded in,
  # when there is one: its own instruction replaces the mode's toy line,
  # since a grounded snippet is still that mode, just with its material given.
  def self.generation_guidance(vocabulary:, label:, mode: nil, artifact: nil, test_framework: nil, source: nil)
    <<~GUIDANCE.chomp
      #{source ? source.instruction : content_instruction(label, mode, artifact, test_framework)}
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.content_instruction(label, mode, artifact, test_framework)
    case mode
    when :test_file
      "- The code_review snippet must be #{test_framework} #{label} test file — a realistic test file exhibiting one real test smell, same question shape (\"what's the issue here, and how would you fix it\")."
    when :schema_review
      "- The code_review snippet must be #{artifact}, ~10-15 lines, containing one planted data-modeling flaw. Same question shape as any other code_review (\"what's the issue here, and how would you fix it\") — the engineer reviews the proposed change, not prose about it."
    else
      "- The code_review snippet must be realistic #{label} code — not toy examples."
    end
  end
  private_class_method :content_instruction

  # `label:` stays part of the contract even though the snippet description no
  # longer restates it here — the instruction line above is the one place a
  # mode's snippet language is authoritative, and duplicating it here is what
  # broke on the JS schema-review day (a Prisma schema described as "JavaScript
  # code").
  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — ~10-15 lines, matching the code_review snippet instruction above",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "diagram":  "string — Mermaid source showing the structure this snippet describes, or an empty string if no diagram would help"
        }
    SCHEMA
  end

  def self.review_context(section:, answer:, rating:)
    [
      "Code Review question: #{section["question"]}",
      "Code snippet: #{section["snippet"]}",
      current_schema_lines(section["current_schema"]),
      answer_lines(answer, rating)
    ].compact.join("\n")
  end

  def self.current_schema_lines(schema)
    return if schema.blank?

    <<~SCHEMA.chomp
      Current schema — the real table(s) as they stand today in db/schema.rb. The snippet is a new migration proposed against them, so a column or index already here is not part of the flaw and the answer does not need to add it:
      #{schema}
    SCHEMA
  end
  private_class_method :current_schema_lines
end

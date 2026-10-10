# Scaffolded because a design answer has predictable parts; nothing validates against the scaffold.
class ExerciseSection::Pattern < ExerciseSection
  # Fallback for rows predating answer_scaffold and for a provider that omits or mangles it.
  DEFAULT_SCAFFOLD = [
    "Your approach:",
    "Interface — how would this be called:",
    "What would be easy to get wrong or worth testing:"
  ].freeze

  def self.default_scaffold
    DEFAULT_SCAFFOLD
  end

  def self.diagrammable?
    true
  end

  def self.judge_task
    "Design an approach to the stated problem, explaining the tradeoffs the scaffold names; naming the pattern is the point."
  end

  def self.prose_fields
    %w[title why scenario question teaching_note]
  end

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - Choose the pattern concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "pattern": {
          "title":    "string — pattern name",
          "why":      "string — one sentence on why the pattern exists",
          "question": "string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "answer_scaffold": ["string — a labelled part of a complete answer to THIS question", "string — another part"],
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "diagram": "string — Mermaid source showing the structure this scenario describes, or an empty string if no diagram would help"
        }
    SCHEMA
  end

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Pattern question (#{section["title"]}): #{section["question"]}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  def self.grading_note(section:, answer:)
    "Main point: the structure the problem calls for.\n" \
    "Essential pieces: a structure and interface that would work for the stated problem. The answer scaffold names what to cover (#{scaffold_labels(section).map { |label| label.delete_suffix(':') }.join('; ')}), whether or not the answer kept the labels; a part it leaves out is an essential gap only when the design would not work without it.\n" \
    "For \"pattern\", improved_code must show the refactored structure that addresses what they missed — " \
    "the classes, methods, and boundaries the pattern calls for — not a one-line tweak. A pattern fix is " \
    "structural; show enough of the shape to make the structure obvious."
  end
end

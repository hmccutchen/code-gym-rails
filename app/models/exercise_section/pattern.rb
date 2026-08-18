# The one section whose question is "design something", so its answer has
# predictable parts — the approach, the shape of the interface, and what could
# go wrong. The template names those parts so the blank textarea stops being
# the hard part. It is not a required structure: nothing validates against it
# beyond ignoring untouched labels when measuring an answer's substance.
class ExerciseSection::Pattern < ExerciseSection
  # Fallback only. The generator returns an `answer_scaffold` tailored to the
  # day's actual question; this is what a pattern answer needs in general, used
  # for rows generated before the field existed and for a provider that omits
  # or mangles it.
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
end

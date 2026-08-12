# Language-independent by nature: an architecture concept transcends any one
# stack, so it draws from ARCHITECTURE_CONCEPTS rather than the day's language
# vocabulary. Its review carries no improved_code — the model is asked to return
# an empty string there, since a design decision has no single corrected form.
class ExerciseSection::Architecture < ExerciseSection
  # Fallback only — see ExerciseSection::Pattern::DEFAULT_SCAFFOLD.
  DEFAULT_SCAFFOLD = [
    "Which option, and why:",
    "Tradeoffs you considered:"
  ].freeze

  def self.default_scaffold
    DEFAULT_SCAFFOLD
  end

  def self.vocabulary_key
    :architecture
  end

  def self.improved_code?
    false
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "architecture": {
          "title":     "string — short name for the decision",
          "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
          "question":  "string — ONE sentence asking for a decision + justification",
          "options":   ["string — a viable approach", "string — another viable approach", "string — an optional third approach (omit for 2)"],
          "answer_scaffold": ["string — a labelled part of a complete answer to THIS decision", "string — another part"],
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the architecture vocabulary",
          "reference": {
            "tagline":     "string — bold one-liner",
            "explanation": "string — 2-3 sentences",
            "tradeoffs":   ["string — a tradeoff", "string — a tradeoff", "string — a tradeoff"],
            "senior_lens": "string — how a senior frames the decision",
            "diagram":     "string — Mermaid source visualizing the decision, or an empty string if no diagram would help"
          }
        }
    SCHEMA
  end
end

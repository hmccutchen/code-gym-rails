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

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
      - Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
      - Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
      - The architecture question itself is one sentence — do not restate the scenario in it.
      - Choose the architecture section's concept from this SEPARATE vocabulary, exactly one: #{vocabulary.join(", ")}
      - The architecture reference's "diagram" shows the STRUCTURE the decision is about — the services, data stores, and flows in tension — not a flowchart of how to decide.
    GUIDANCE
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

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Architecture decision (#{section["title"]}): #{section["question"]}
      Scenario/constraints: #{section["scenario"]}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  def self.grading_note(section:, answer:)
    "Evaluate the architecture answer on the DEPTH of its reasoning, not a single correct answer:\n" \
    "- Did they weigh real tradeoffs between the options?\n" \
    "- Did they address the stated constraints (scale, team, reliability, tech debt)?\n" \
    "- Did they consider alternatives rather than asserting one option?"
  end
end

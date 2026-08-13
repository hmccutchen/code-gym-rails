# Given a vague feature request, the engineer lists what they'd need
# clarified before writing a spec. Unscaffolded deliberately: a labeled
# scaffold would hint at the shape or count of the planted ambiguities (see
# PLANTED_COUNT). improved_code? is false — there's no "corrected code" for a
# clarifying-questions exercise.
class ExerciseSection::AmbiguityHunt < ExerciseSection
  # Fixed, not a range: the review prompt must always know exactly how many
  # ambiguities were planted to grade coverage against. 4 sits at the
  # midpoint of the 3-5 range considered — few enough to find in one sitting,
  # enough to force real coverage judgment.
  PLANTED_COUNT = 4

  # What the planted list is bounded to on ingest, as opposed to what the
  # prompt asks for. PLANTED_COUNT is the generator's target; nothing
  # downstream reads it, since the review prompt lists the ambiguities rather
  # than counting them (see AiService#fourth_context_summary). So a provider
  # that lands on 3 or 5 has still produced a gradable section, and only the
  # runaway case needs bounding — this is provider text going into another
  # prompt.
  #
  # Lives beside PLANTED_COUNT rather than beside the normalizer that enforces
  # it, the same way MAX_SCAFFOLD_LABELS sits on ExerciseSection while
  # AiService#normalize_answer_scaffolds! enforces that one. Splitting a
  # constant from the constant it derives from is how the two drift.
  MAX_PLANTED = PLANTED_COUNT * 2

  def self.vocabulary_key
    :ambiguity_hunt
  end

  def self.improved_code?
    false
  end

  def self.generation_guidance(vocabulary:, label:, mode: nil)
    <<~GUIDANCE.chomp
      - The fourth section is an AMBIGUITY HUNT: "request" is a vague feature ask, 2-4 sentences, phrased the way a stakeholder or PM would ask for it — not an engineer. It must contain EXACTLY #{PLANTED_COUNT} deliberately planted ambiguities, listed in "planted_ambiguities". Each must be a genuine gap — a missing scope boundary, an undefined edge case, no stated success criteria, an unstated data implication, or an undefined permissions model — never something "request" already answers.
      - "planted_ambiguities" is HIDDEN test data used only for grading. Never restate, hint at, or echo any of it inside "request", "question", or "teaching_note" — doing so would give away the answer before the engineer reads the request.
      - Choose the ambiguity_hunt concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "ambiguity_hunt": {
          "title":    "string",
          "scenario": "string — the concrete business-domain framing, drawn from Code Gym-style feature requests (e.g. a daily-practice app's own features)",
          "request":  "string — a vague feature request, 2-4 sentences, phrased the way a stakeholder or PM would ask for it, not an engineer",
          "planted_ambiguities": ["string — one specific ambiguity deliberately left in \\"request\\"", "... (exactly #{PLANTED_COUNT} total)"],
          "question": "string — e.g. 'What would you need clarified before writing a spec for this?'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        }
    SCHEMA
  end
end

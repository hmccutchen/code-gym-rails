# Unscaffolded on purpose: labels would hint at the planted ambiguities. Ignores the day's scenario flavor.
class ExerciseSection::AmbiguityHunt < ExerciseSection
  # The generator's target, not a bound: nothing downstream reads it.
  PLANTED_COUNT = 4

  # Only the runaway case needs bounding: a list of 3 or 5 still grades.
  MAX_PLANTED = PLANTED_COUNT * 2

  PLANTED_FIELD = "planted_ambiguities".freeze

  def self.vocabulary_key
    :ambiguity_hunt
  end

  def self.answer_key_fields
    [ PLANTED_FIELD ]
  end

  # Refuses an empty list, the only grading ground truth; a wrong count is fine and a long list is truncated.
  def self.reject_unusable!(section)
    raw     = section[PLANTED_FIELD]
    planted = raw.is_a?(Array) ? raw.grep(String).filter_map { |entry| entry.strip.presence } : []
    if planted.empty?
      raise AiService::InvalidResponseError,
            "Ambiguity hunt returned no usable #{PLANTED_FIELD} to grade coverage against"
    end

    section[PLANTED_FIELD] = planted.first(MAX_PLANTED)
  end

  def self.improved_code?
    false
  end

  def self.judge_task
    "List what needs clarifying before a spec could be written."
  end

  def self.generation_guidance(vocabulary:, label:, **)
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
          "scenario": "string — the concrete business-domain framing, drawn from Code Gym-style feature requests (a daily-practice app's own features) and NOT from the scenario flavors listed above — the engineer reasons about ambiguity in a domain they already know",
          "request":  "string — a vague feature request, 2-4 sentences, phrased the way a stakeholder or PM would ask for it, not an engineer",
          "planted_ambiguities": ["string — one specific ambiguity deliberately left in \\"request\\"", "... (exactly #{PLANTED_COUNT} total)"],
          "question": "string — e.g. 'What would you need clarified before writing a spec for this?'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        }
    SCHEMA
  end

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Ambiguity Hunt (#{section["title"]}): #{section["question"]}
      Request: #{section["request"]}
      Planted ambiguities (hidden from the engineer, known here for grading): #{Array(section[PLANTED_FIELD]).join('; ')}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  def self.grading_note(section:, answer:)
    "Grade coverage against the PLANTED ambiguities listed in the context above (the \"Planted ambiguities\" line) — do not invent your own list.\n" \
    "Main point: at least one planted ambiguity identified.\n" \
    "Essential pieces: the planted ambiguities that would most likely get the feature built wrong if nobody asked. In \"missed\", name every planted ambiguity the engineer did not identify, but list only those as essential gaps, so the rating does not depend on how many were planted. In \"correct\", credit each one they did identify, AND credit (without penalty) any additional legitimate ambiguity they found that wasn't planted; an extra one like that is the kind of addition the rubric credits beyond solid.\n" \
    "For this section \"improved_code\" must be an empty string."
  end
end

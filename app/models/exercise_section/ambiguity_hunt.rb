# Given a vague feature request, the engineer lists what they'd need
# clarified before writing a spec. Unscaffolded deliberately: a labeled
# scaffold would hint at the shape or count of the planted ambiguities (see
# PLANTED_COUNT). improved_code? is false — there's no "corrected code" for a
# clarifying-questions exercise.
#
# The one kind that opts out of the day's scenario flavor
# (AiService::SCENARIO_POOLS): its scenario stays a Code Gym-style feature
# request, stated in its own schema fragment. Reasoning about what a request
# leaves unsaid is the whole exercise, and an unfamiliar business setting
# would add a second thing to work out first — the burden this kind removes.
class ExerciseSection::AmbiguityHunt < ExerciseSection
  # Fixed, not a range: the review prompt must always know exactly how many
  # ambiguities were planted to grade coverage against. 4 sits at the
  # midpoint of the 3-5 range considered — few enough to find in one sitting,
  # enough to force real coverage judgment.
  PLANTED_COUNT = 4

  # What the planted list is bounded to on ingest, as opposed to what the
  # prompt asks for. PLANTED_COUNT is the generator's target; nothing
  # downstream reads it, since the review prompt lists the ambiguities rather
  # than counting them (see .review_context below). So a provider
  # that lands on 3 or 5 has still produced a gradable section, and only the
  # runaway case needs bounding — this is provider text going into another
  # prompt.
  MAX_PLANTED = PLANTED_COUNT * 2

  PLANTED_FIELD = "planted_ambiguities".freeze

  def self.vocabulary_key
    :ambiguity_hunt
  end

  def self.answer_key_fields
    [ PLANTED_FIELD ]
  end

  # Unlike most boundary checks, this one rejects rather than repairs. The
  # planted list is the ambiguity hunt's entire grading ground truth — the
  # review prompt grades coverage against it and nothing else — so an empty or
  # unusable list doesn't degrade the section, it silently turns coverage
  # grading back into the freehand judgement the kind exists to replace, and
  # there is no fallback to fall back to. InvalidResponseError is already a
  # surfaced, retryable generation failure
  # (GenerateDailyExercisesJob#persist_failure), so failing costs the user a
  # retry rather than a day of ungrounded grading.
  #
  # A WRONG COUNT IS NOT A FAILURE, though. Nothing downstream reads
  # PLANTED_COUNT, so a list of 3 or 5 grades exactly as well — and rejecting
  # it would throw away the rest of the day's sections over the likeliest
  # deviation an LLM makes on a counted list. Only the empty case is fatal;
  # the long case is truncated.
  #
  # Shape is held to the schema even though count isn't: a bare string here
  # is not four ambiguities, it's a provider that ignored the field's type,
  # and Array() would quietly launder it into a single-entry answer key.
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
      Planted ambiguities (hidden from the engineer, known here for grading): #{Array(section["planted_ambiguities"]).join('; ')}
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

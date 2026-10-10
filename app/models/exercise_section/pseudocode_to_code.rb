# Design notes: docs/code-notes/app/models/exercise_section/pseudocode_to_code.md
class ExerciseSection::PseudocodeToCode < ExerciseSection
  MAX_CRITIQUE_POINTS = 3

  MAX_CRITIQUE_POINT_LENGTH = 300

  MAX_PROBLEM_STATEMENT_LENGTH = 2_000

  MAX_PSEUDOCODE_LENGTH = 6_000

  def self.vocabulary_key
    :pseudocode_to_code
  end

  # Rejects rather than repairs: the statement is the whole task, and a non-string raises in glossary_wrap.
  def self.reject_unusable!(section)
    statement = section["problem_statement"].is_a?(String) ? section["problem_statement"].strip : ""
    if statement.empty?
      raise AiService::InvalidResponseError,
            "Pseudocode section returned no usable problem_statement to plan against"
    end

    section["problem_statement"] = statement.truncate(MAX_PROBLEM_STATEMENT_LENGTH)
  end

  def self.judge_task
    "Write pseudocode that meets the stated requirements, including the one an under-specified plan would miss."
  end

  def self.default_scaffold
    nil
  end

  def self.translated_before_grading?
    true
  end

  def self.diagrammable?
    false
  end

  def self.answer_partial
    "responses/answers/pseudocode_to_code"
  end

  def self.answer_class
    "answer code-answer"
  end

  # The one wording of the gap rule; critique_pseudocode and .grading_note both read it, and a spec checks both.
  def self.gap_standard
    "Only flag a gap if implementing the pseudocode literally as written would produce behavior " \
      "that's actually wrong or that fails to handle something the problem statement requires. " \
      "Do NOT flag: missing syntax or type detail, omitted mechanical/obvious steps (e.g. \"return " \
      "the result\"), or any level of abstraction normal for pseudocode. Pseudocode is expected to " \
      "be less granular than code — evaluate the REASONING, not the verbosity."
  end

  def self.normalize_critique(raw)
    return [] unless raw.is_a?(Array)

    raw.grep(String)
       .filter_map { |point| point.strip.presence&.truncate(MAX_CRITIQUE_POINT_LENGTH) }
       .first(MAX_CRITIQUE_POINTS)
  end

  def self.generation_guidance(vocabulary:, label:, **)
    <<~GUIDANCE.chomp
      - The fourth section is PSEUDOCODE TO CODE: "problem_statement" is a self-contained problem the engineer will plan in pseudocode before any code exists. It must be solvable in roughly 15-25 lines of pseudocode — small enough to plan in one sitting, large enough to need real decomposition — and must state at least one requirement an under-specified plan would quietly miss (an empty input, a boundary, an ordering guarantee, a failure path), so there is something missable to grade.
      - State the problem in terms of behavior and inputs, never in terms of #{label} APIs: the engineer answers in pseudocode, and naming a framework method would hand them the decomposition.
      - Do NOT include starter code, a function signature, or a worked example. Choosing the decomposition is the whole exercise.
      - Choose the pseudocode_to_code concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "pseudocode_to_code": {
          "title":    "string — short name for the problem",
          "scenario": "string — the concrete business-domain framing, e.g. 'deduplicating a nightly import feed'",
          "problem_statement": "string — a self-contained problem solvable in roughly 15-25 lines of pseudocode, stating at least one requirement an under-specified plan would miss. No starter code, no signature, no worked example.",
          "question": "string — e.g. 'Write pseudocode for this.'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        }
    SCHEMA
  end

  # section["rounds"] is merged in by the caller from pseudocode_rounds; problem_set never holds it.
  def self.review_context(section:, answer:, rating:)
    rounds = section["rounds"].is_a?(Hash) ? section["rounds"] : {}

    <<~CONTEXT.chomp
      Pseudocode to Code (#{section["title"]}): #{section["question"]}
      Problem statement: #{section["problem_statement"]}
      #{critique_lines(rounds)}
      #{UserText.labelled("Their final pseudocode:", answer)}
      #{translation_lines(rounds, answer)}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  # States absence explicitly, since .grading_note depends on whether a critique was declined or is missing.
  def self.critique_lines(rounds)
    return "No critique was requested, so there was no revision round." if rounds["critiqued_at"].blank?

    points = normalize_critique(rounds["critique"])
    raised = points.any? ? points.join("; ") : "nothing — the critique found no genuine gap"

    "#{UserText.labelled("Their first pseudocode:", rounds["initial_pseudocode"], blank: "(blank)")}\n" \
    "The critique they were shown raised: #{raised}"
  end
  private_class_method :critique_lines

  def self.translation_lines(rounds, answer)
    code = rounds["generated_code"].presence
    return "They never translated their plan into code." if code.nil?

    fenced = UserText.tagged(code)
    if rounds["translated_from"].to_s.strip == answer.to_s.strip
      "The code their pseudocode produced, translated literally:\n#{fenced}"
    else
      "They revised their plan AFTER translating, so the code below came from an earlier draft. " \
      "Grade the final pseudocode above; treat this code as evidence about the draft only, and do " \
      "not attribute its flaws to the final plan unless the final plan still has them:\n#{fenced}"
    end
  end
  private_class_method :translation_lines

  def self.grading_note(section:, answer:)
    "Grade the REASONING in their pseudocode, not the polish of the code it produced. The code was translated literally and faithfully from the pseudocode it was given — it was never corrected — so a flaw in it is a flaw in THAT version of the plan, and missing syntax or idiom in it is an artifact of translation and is never a fault. Attribute a flaw to their final answer only when the context above says the code was translated from that same text; if it says the plan was revised afterwards, check whether the final version still has the flaw before counting it.\n" \
    "Main point: an approach that would solve the problem.\n" \
    "Essential pieces: the gaps this standard counts. #{gap_standard}\n" \
    "If the context above shows a critique was requested, credit any revision that addressed a point it raised. NEVER treat an unaddressed critique point as a miss on its own: the critique is advisory, the engineer may have judged it wrong, and it is permitted to find nothing at all.\n" \
    "\"improved_code\" for this section is their corrected plan implemented — the smallest change to their approach that fixes what they missed, not a from-scratch ideal solution."
  end
end

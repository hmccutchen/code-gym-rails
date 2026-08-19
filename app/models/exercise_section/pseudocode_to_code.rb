# Given a problem statement, the engineer writes pseudocode; one call then
# translates it into real code FAITHFULLY, preserving whatever the plan got
# wrong. Unscaffolded deliberately — a labelled scaffold would hand over the
# decomposition, and choosing the decomposition is the exercise.
class ExerciseSection::PseudocodeToCode < ExerciseSection
  # What the round-1 critique may return, bounded because it is provider text
  # rendered into the page. Three is enough to redirect a plan without
  # rewriting it for them.
  MAX_CRITIQUE_POINTS = 3

  MAX_CRITIQUE_POINT_LENGTH = 300

  def self.vocabulary_key
    :pseudocode_to_code
  end

  def self.default_scaffold
    nil
  end

  # A diagram of the structure would hand over the decomposition this section
  # asks the engineer to produce.
  def self.diagrammable?
    false
  end

  def self.answer_partial
    "responses/answers/pseudocode_to_code"
  end

  # Pseudocode is written as code-shaped text, so it reads wrong in the prose face.
  def self.answer_class
    "answer"
  end

  # The one statement of what counts as a genuine gap. Two consumers read this
  # method and neither restates it: the round-1 critique prompt
  # (AiService#critique_pseudocode) and this kind's own .grading_note. A second
  # wording of this rule is the drift the design set out to prevent, and a spec
  # asserts both call sites contain exactly this string.
  #
  # It lives on the kind rather than beside AiService's #<group>_guidance
  # methods because those state a rule about a CONCEPT GROUP once for every
  # section, while this states a rule about one kind at two call sites — and
  # because ExerciseSection deliberately does not depend on AiService.
  def self.gap_standard
    "Only flag a gap if implementing the pseudocode literally as written would produce behavior " \
      "that's actually wrong or that fails to handle something the problem statement requires. " \
      "Do NOT flag: missing syntax or type detail, omitted mechanical/obvious steps (e.g. \"return " \
      "the result\"), or any level of abstraction normal for pseudocode. Pseudocode is expected to " \
      "be less granular than code — evaluate the REASONING, not the verbosity."
  end

  # Same normalize-and-bound shape as ExerciseSection.normalize_scaffold, and
  # for the same reason: provider text going into the page.
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
          "question": "string — e.g. 'Write pseudocode for this, then translate it.'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        }
    SCHEMA
  end

  # `section["rounds"]` is merged in by the caller from the response's
  # pseudocode_rounds column — the exercise's own problem_set never holds it.
  def self.review_context(section:, answer:, rating:)
    rounds = section["rounds"].is_a?(Hash) ? section["rounds"] : {}

    <<~CONTEXT.chomp
      Pseudocode to Code (#{section["title"]}): #{section["question"]}
      Problem statement: #{section["problem_statement"]}
      #{critique_lines(rounds)}
      The code their pseudocode produced, translated literally: #{rounds["generated_code"].presence || "(never translated)"}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  # Absence is stated rather than left blank: a reviewer given no critique line
  # cannot tell whether the engineer declined one or the field went missing, and
  # .grading_note turns on exactly that difference.
  def self.critique_lines(rounds)
    return "No critique was requested, so there was no revision round." if rounds["critiqued_at"].blank?

    points = normalize_critique(rounds["critique"])
    raised = points.any? ? points.join("; ") : "nothing — the critique found no genuine gap"

    "Their first pseudocode: #{rounds["initial_pseudocode"].presence || "(blank)"}\n" \
    "The critique they were shown raised: #{raised}"
  end
  private_class_method :critique_lines

  def self.grading_note(section:, answer:)
    "Grade the REASONING in their pseudocode, not the polish of the code it produced. The code was translated literally and faithfully from their plan — it was never corrected — so any flaw in it is a flaw in the plan and must be attributed to the plan, and missing syntax or idiom in it is an artifact of translation and is never a fault.\n" \
    "#{gap_standard}\n" \
    "If the context above shows a critique was requested, credit any revision that addressed a point it raised. NEVER treat an unaddressed critique point as a miss on its own: the critique is advisory, the engineer may have judged it wrong, and it is permitted to find nothing at all.\n" \
    "\"improved_code\" for this section is their corrected plan implemented — the smallest change to their approach that fixes what they missed, not a from-scratch ideal solution."
  end
end

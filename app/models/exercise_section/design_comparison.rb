# Two working pieces of code that differ on one design principle. The engineer
# picks the piece the stated system should use and says which stated fact
# decides it. No scaffold and no teaching note: either would point at the
# answer before the engineer has read the code.
#
# The provider writes the pieces as better_piece and other_piece, so it never
# chooses a position; .arrange! rolls which one is shown as A. The correct
# position then exists only in the stored answer key, which nothing before
# submission may show, log or send to a model.
class ExerciseSection::DesignComparison < ExerciseSection
  # Lines of code, blanks not counted: twice the prompt's lower target, the
  # way AmbiguityHunt::MAX_PLANTED doubles PLANTED_COUNT. Exceeding it costs
  # the section, so it stops a runaway reply, not a long piece; unequal
  # lengths are the judge's surface-parity check.
  MAX_PIECE_LINES = 24

  # About one sentence naming a fact, against prose's ten characters. A pick
  # and a word is not an answer to "what decides it".
  MIN_REASON_LENGTH = 40

  PICK_PREFIX = "pick:".freeze
  PIECES = %w[a b].freeze

  # The reason is typed, then encoded behind "pick:a\n" before it is stored, so
  # its own bound is the shared answer cap less the longest prefix that can sit
  # in front of it. Derived rather than written out: a change to either the
  # cap or the encoding would otherwise leave the browser offering a reason the
  # boundary would quietly clip.
  MAX_REASON_LENGTH = UserText::MAX_ANSWER_LENGTH - (PICK_PREFIX.length + 2)

  # Even odds, and no "must differ from the stored order" rule like the
  # Parsons scramble has: with two pieces that rule would always swap, which
  # gives the answer away.
  POSITION_WEIGHTS = PIECES.index_with(1).freeze

  CANONICAL_PIECES = %w[better_piece other_piece].freeze
  ANSWER_KEY_FIELD = "answer_key".freeze
  # The fields the provider writes; `better` is the server's.
  PROVIDER_KEY_FIELDS = %w[deciding_fact principle why_other_fails].freeze

  # Hosted concept by concept, beside the whole groups in .hosted_concepts. A
  # concept qualifies when both pieces can meet the same stated behavior and
  # still differ in what they cost to change or to run. Concepts whose worse
  # piece would be incorrect (idempotency, error_handling, concurrency,
  # transactions, security) turn the task back into a code review and stay out.
  # A borderline concept joins only after the judge comparison keeps real
  # drafts for it.
  # Data-modeling concepts deferred after the 2026-10-01 real-draft check: a
  # missing_constraint draft's two pieces behaved differently under the
  # scenario's own concurrent writers and bulk insert, and the judge kept it.
  # Each is eligible again only after a comparison run shows drafts whose
  # pieces behave the same under every stated condition.
  DEFERRED_CONCEPTS = %w[missing_constraint unsafe_migration wrong_cardinality].freeze

  HOSTED_CONCEPTS = %w[
    n_plus_one memoization service_objects query_objects policy_objects
    over_mocking testing_implementation_not_behavior
    callback_hell promise_chaining event_loop_blocking debouncing_throttling
    component_re_renders state_lifting controlled_vs_uncontrolled
  ].freeze

  RUNG_GUIDANCE = {
    "junior" => "the deciding fact is in the question, in a line or two, and points plainly at one piece.",
    "senior" => "the deciding fact is in the scenario's description of the system and has to be connected to the code. " \
                "Both pieces are equally readable; their structures respond differently to the stated maintenance or workload constraint.",
    "principal_engineer" => "both pieces are defensible and each has a real cost. The scenario sets the tradeoff, " \
                            "and the stated facts still settle which cost this system should pay."
  }.freeze

  class << self
    def fixed?
      true
    end

    def improved_code?
      false
    end

    def discovery?
      true
    end

    def prose_fields
      %w[title scenario question]
    end

    def answer_key_fields
      [ ANSWER_KEY_FIELD ]
    end

    # The canonical names, since ingest formats before .arrange! renames them.
    def code_fields
      CANONICAL_PIECES
    end

    def answer_partial
      "responses/answers/design_comparison"
    end

    # Its reference explains the principle that decides the pick, which is
    # the reason the grade asks for.
    def reference_opens_before_answer?
      false
    end

    def judge_task
      "Pick the better-designed of two working pieces of code for the stated system, and say which stated fact decides it."
    end

    def judge_guidance
      "This section shows two pieces of code, A and B. They must behave the same and differ on one design principle. " \
        "Solve it before judging: decide which piece is better for the stated system, and quote the sentence that decides it. " \
        "Reject as underdetermined if no stated fact decides it, or if, at the junior rung, both pieces are defensible. " \
        "Reject as reasoning_failure if a piece can be picked without reasoning about the system: cleaner names, more or " \
        "better comments, clearly shorter code, or behavior that differs under any condition the scenario states, such as " \
        "concurrent writers, retries, bulk writes or a failure. Reject as scope_mismatch if the principle the " \
        "pieces differ on is not the tagged concept. At principal_engineer both pieces may be defensible and each may carry " \
        "a real cost; keep it only if the stated facts still settle which cost this system should pay. Reject as " \
        "scope_mismatch if the section restates a defect to find rather than offering a choice between two working " \
        "designs. When you edit, you may reword the title, scenario and question; never " \
        "change either piece of code, which piece is better, or what the deciding fact says.\n" \
        "Put your solve in \"better\" (\"a\" or \"b\") and nowhere else: evidence, reason and issues must not say which piece is better."
    end

    def judge_solve_options
      PIECES
    end

    # The scenario and question the judge may reword are where the deciding
    # fact lives.
    def rejudge_edits?
      true
    end

    def solve_matches_key?(section, solve)
      section.dig(ANSWER_KEY_FIELD, "better") == solve
    end

    # Rung-dependent: TRADEOFF_CONCEPTS have two defensible sides, which only
    # the principal_engineer rung allows. No rung means the caller cannot know
    # it, so it gets the strictest list.
    def narrow_vocabulary(vocabulary, rung: nil)
      hosts = vocabulary & hosted_concepts
      rung == "principal_engineer" ? hosts : hosts - AiService::TRADEOFF_CONCEPTS
    end

    # An allowlist rather than exclusions, so a concept added to a language
    # vocabulary later is not offered here until someone decides it fits.
    def hosted_concepts
      AiService::CODE_SMELL_CONCEPTS + AiService::OO_DESIGN_CONCEPTS + AiService::MODULE_DESIGN_CONCEPTS +
        AiService::DOMAIN_MODELING_CONCEPTS + (AiService::DATA_MODELING_CONCEPTS - DEFERRED_CONCEPTS) +
        AiService::TYPESCRIPT_FLAVORED_CONCEPTS + HOSTED_CONCEPTS
    end

    def reject_unusable!(section)
      CANONICAL_PIECES.each { |field| reject_unusable_piece!(field, section[field]) }

      key = section[ANSWER_KEY_FIELD]
      unusable = PROVIDER_KEY_FIELDS.reject { |field| key.is_a?(Hash) && usable_text?(key[field]) }
      return if unusable.empty?

      raise AiService::InvalidResponseError, "Design comparison answer key has no usable #{unusable.join(', ')}"
    end

    def arrange!(section)
      better = WeightedRoll.pick(POSITION_WEIGHTS)
      raise ArgumentError, "#{better.inspect} is not one of #{PIECES.join(', ')}" unless PIECES.include?(better)

      pieces = section.values_at(*CANONICAL_PIECES)
      section["piece_a"], section["piece_b"] = better == "a" ? pieces : pieces.reverse
      section[ANSWER_KEY_FIELD] = { "better" => better }
        .merge(section[ANSWER_KEY_FIELD].slice(*PROVIDER_KEY_FIELDS).transform_values(&:strip))
      CANONICAL_PIECES.each { |field| section.delete(field) }
    end

    # [pick, reason]: pick is "a", "b" or nil, and reason is the stripped text
    # after the first line. Never raises, since the stored answer is a
    # free-form permitted param.
    def parse_answer(value)
      first_line, reason = value.to_s.split("\n", 2)
      pick = first_line.to_s.strip.delete_prefix(PICK_PREFIX)
      [ (pick if first_line.to_s.start_with?(PICK_PREFIX) && PIECES.include?(pick)), reason.to_s.strip ]
    end

    def encode_answer(pick, reason)
      "#{PICK_PREFIX}#{pick}\n#{reason}"
    end

    def answered?(value, _section_data = nil)
      pick, reason = parse_answer(value)
      pick.present? && reason.length >= MIN_REASON_LENGTH
    end

    def review_context(section:, answer:, rating:)
      key = section[ANSWER_KEY_FIELD].is_a?(Hash) ? section[ANSWER_KEY_FIELD] : {}

      <<~CONTEXT.chomp
        Design Comparison (#{section["title"]}): #{section["question"]}
        Scenario: #{section["scenario"]}
        Piece A:
        #{section["piece_a"]}
        Piece B:
        #{section["piece_b"]}
        Answer key (hidden from the engineer, known here for grading): the better piece is #{key["better"].to_s.upcase}. Deciding fact: #{key["deciding_fact"]} Principle: #{key["principle"]} Why the other piece fails: #{key["why_other_fails"]}
        #{decoded_answer_line(answer)}
        Their self-rating: #{rating.presence || '(none given)'}
      CONTEXT
    end

    def grading_note(section:, answer:)
      "Grade the reason, never the pick alone.\n" \
        "Main point: a pick grounded in the stated system: the piece the answer key names, or a reason tied to a fact the section states. " \
        "A pick that is neither has missed it.\n" \
        "Essential pieces: picking the piece the answer key names, naming the deciding fact, and naming the principle the pieces differ on. " \
        "The matching pick with a reason that does not name the deciding fact has missed an essential piece. " \
        "The other pick with a sound reason tied to a stated fact has missed one too; say in \"missed\" what the stated facts decide. " \
        "At principal_engineer, a reason that weighs both pieces' costs against the stated facts counts for more than which piece was picked. " \
        "Naming the other piece's real cost, or a consequence of the choice, is the kind of addition the rubric credits beyond solid."
    end

    def generation_guidance(vocabulary:, label:, rung: nil, **)
      <<~GUIDANCE.chomp
        - The second section is a DESIGN COMPARISON: "better_piece" and "other_piece" are two pieces of #{label} code, 12-15 lines each, that meet the same stated behavior, including its retry and failure cases, and differ on exactly one design principle: the tagged concept. Compare what they cost to change or to run, never correct behavior against a defect; a worse piece that is incorrect turns this into a code review.
        - Surface parity: the pieces behave identically, are about the same length, and are equally clean, named and commented. Any difference other than the tested principle is a defect.
        - #{rung_line(rung)}
        - The deciding fact must be stated in the section. A hypothetical condition the section never states does not decide anything.
        - When this section's concept is the same as the code review's, test it through a choice between two working designs in a different scenario from the code review, never by restating a defect to find.
        - "answer_key" is HIDDEN grading data. Never restate or hint at it, or at which piece is better, in "title", "scenario" or "question".
        - Choose the design_comparison concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
      GUIDANCE
    end

    def schema_fragment(label:)
      <<~SCHEMA.chomp
        "design_comparison": {
            "title":    "string",
            "scenario": "string — the system this code belongs to, with the facts about its workload or how it changes",
            "question": "string — e.g. 'Which piece fits this system better, and which fact decides it?'",
            "better_piece": "string — 12-15 lines of #{label} code: the design this system should choose",
            "other_piece":  "string — 12-15 lines of #{label} code with the same behavior, making the other choice",
            "answer_key": {
              "deciding_fact":   "string — the stated fact that settles the choice",
              "principle":       "string — the design principle the pieces differ on",
              "why_other_fails": "string — what the other piece costs this system"
            },
            "concept": "string — exactly one concept from the provided vocabulary"
          }
      SCHEMA
    end

    private

    def reject_unusable_piece!(field, piece)
      raise AiService::InvalidResponseError, "Design comparison returned no usable #{field}" unless usable_text?(piece)
      return if piece.lines.count { |line| line.strip.present? } <= MAX_PIECE_LINES

      raise AiService::InvalidResponseError, "Design comparison #{field} runs past #{MAX_PIECE_LINES} lines"
    end

    def usable_text?(value)
      value.is_a?(String) && value.strip.present?
    end

    def rung_line(rung)
      return "This section is pitched at #{rung}: #{RUNG_GUIDANCE.fetch(rung)}" if rung

      "By the level this section is pitched at: #{RUNG_GUIDANCE.map { |level, text| "#{level}: #{text}" }.join(' ')}"
    end

    def decoded_answer_line(answer)
      pick, reason = parse_answer(answer)
      return "Their answer: (skipped)" unless pick

      "Picked: #{pick.upcase}. #{UserText.labelled('Reason:', reason)}"
    end
  end
end

# Blocks are always persisted in correct order (ProblemSetIngest#shuffle_parsons_blocks!
# scrambles only the display order), so a correct submission is always the
# identity permutation. That is what keeps grading local and deterministic —
# the AI is never asked to judge correctness for this kind, only to explain it.
class ExerciseSection::ParsonsProblem < ExerciseSection
  ANSWER_PREFIX = "order:".freeze

  class << self
    def improved_code?
      false
    end

    # Parsons is a SEQUENCING format: 5-8 blocks reordered into one correct
    # sequence, graded by positional diff against a known-correct order.
    #
    # The data-modeling concepts are not sequential — "these columns are in the
    # wrong order" is not what wrong_cardinality or missing_index means. The
    # meta-skill concepts fail the same way from the other direction: they are
    # about reading and interrogating something, and there is nothing to read
    # in a pile of blocks whose only question is what order they go in. The
    # code smells fail on scale rather than on sequence: each names a shape
    # visible across a class or a call graph, and 5-8 blocks is neither — a
    # god_object cannot be shown, let alone recognized, in a list short enough
    # to reorder. A Parsons problem tagged from any of the three degenerates
    # into nonsense or quietly becomes about something else, and a nonsense
    # exercise costs more trust than a missed retention check does — a due
    # concept from any of them still has other hosts (see
    # AiService#annotate_retention_concept).
    #
    # The OO design principles fail on the same axis as the code smells and
    # for a sharper reason: this format's entire grade is a positional diff,
    # and none of open_closed, dependency_inversion, or
    # composition_over_inheritance has an ordering that is right or wrong. An
    # extension seam, an injected collaborator, and a composed object are
    # structural judgments a permutation score cannot measure at all.
    #
    # unsafe_migration is the arguable exception: backfill-then-constrain has a
    # genuinely correct step order, which is exactly this format's shape. It is
    # excluded anyway, because the case for it is really evidence that
    # unsafe_migration sits on a different axis from the other four —
    # operational rather than structural — and the fix for that is to stop
    # grouping it with them, not to special-case one consumer. Revisit here if
    # that regrouping ever happens.
    def excluded_vocabulary_keys
      [ :data_modeling, :meta_skill, :code_smell, :oo_design ]
    end

    # The answer is an ordering, not prose: a draggable, keyboard-reorderable
    # block ladder writing into a hidden field.
    def answer_partial
      "responses/answers/parsons_problem"
    end

    def generation_guidance(vocabulary:, label:, **)
      <<~GUIDANCE.chomp
        - The third section is a PARSONS PROBLEM: return "blocks" as 5 to 8 short code blocks IN THE CORRECT FINAL ORDER — the app shuffles them for display, you must never shuffle them yourself. Each block should be one coherent unit (a full line, or a short logically-grouped set of lines) — never a single token or a bare punctuation mark, since reordering individual tokens is busywork rather than the exercise.
        - Choose the parsons_problem concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
      GUIDANCE
    end

    def schema_fragment(label:)
      <<~SCHEMA.chomp
        "parsons_problem": {
            "title":    "string",
            "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
            "question": "string — e.g. 'Arrange these blocks into the correct working solution'",
            "blocks":   ["string — one logical line or short cohesive group of lines, IN THE CORRECT FINAL ORDER", "string — the next block in correct order", "... (5-8 blocks total)"],
            "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
            "concept": "string — exactly one concept from the provided vocabulary"
          }
      SCHEMA
    end

    # Returns [] for a blank, prefix-missing, or malformed answer so grading
    # degrades to "everything misplaced" rather than raising on a skipped or
    # corrupted submission.
    def parse_order(answer)
      text = answer.to_s
      return [] unless text.start_with?(ANSWER_PREFIX)

      text.delete_prefix(ANSWER_PREFIX).split(",").filter_map { |s| Integer(s, exception: false) }
    end

    # answers["parsons_problem"] is a free-form permitted param, so a saved
    # order can hold duplicate, negative, or out-of-range ids. Anything short of
    # a complete permutation is rejected outright — a partially valid order
    # would drop blocks from the page and then be persisted back by the next
    # autosave.
    def normalize_order(ids, block_count)
      return [] unless ids.size == block_count && ids.uniq.size == block_count
      return [] unless ids.all? { |id| valid_id?(id, block_count) }

      ids
    end

    def valid_id?(id, block_count)
      id.is_a?(Integer) && id >= 0 && id < block_count
    end

    # The arrangement to render on the dashboard: the learner's own saved order
    # if it survives normalization, else the generated scramble, else the
    # stored (correct) order.
    def initial_order(answer:, display_order:, block_count:)
      [ parse_order(answer), Array(display_order) ]
        .filter_map { |ids| normalize_order(ids, block_count).presence }
        .first || (0...block_count).to_a
    end

    # A mismatch count of exactly 1 is impossible for a permutation — the
    # smallest non-zero mismatch is a pair swap — so the table has no `when 1`.
    def grade(submitted_ids, block_count)
      padded     = Array.new(block_count) { |i| submitted_ids[i] }
      mismatches = padded.each_index.count { |i| padded[i] != i }

      rating =
        case mismatches
        when 0 then "strong"
        when 2 then "solid"
        else mismatches <= (block_count / 2.0).ceil ? "developing" : "beginner"
        end

      { mismatches: mismatches, rating: rating }
    end
  end
end

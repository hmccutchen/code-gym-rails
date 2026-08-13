# Blocks are always persisted in correct order (AiService#shuffle_parsons_blocks!
# scrambles only the display order), so a correct submission is always the
# identity permutation. That is what keeps grading local and deterministic —
# the AI is never asked to judge correctness for this kind, only to explain it.
class ExerciseSection::ParsonsProblem < ExerciseSection
  ANSWER_PREFIX = "order:".freeze

  class << self
    def improved_code?
      false
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

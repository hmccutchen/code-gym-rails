# Blocks are always persisted in correct order (AiService#shuffle_parsons_blocks!
# scrambles only the display order), so a fully correct submission is always the
# identity permutation. That keeps grading local and deterministic — the AI is
# never asked to judge correctness for this kind, only to explain the result.
class ExerciseSection::ParsonsProblem < ExerciseSection
  ANSWER_PREFIX = "order:".freeze

  class << self
    def improved_code?
      false
    end

    # Returns [] for a blank, prefix-missing, or malformed answer so grading
    # degrades to "everything misplaced" rather than raising on a skipped or
    # corrupted submission.
    def parse_order(answer)
      return [] unless answer.to_s.start_with?(ANSWER_PREFIX)

      answer.delete_prefix(ANSWER_PREFIX).split(",").filter_map { |s| Integer(s, exception: false) }
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

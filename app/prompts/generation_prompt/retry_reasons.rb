# Design notes: docs/code-notes/app/prompts/generation_prompt/retry_reasons.md
module GenerationPrompt::RetryReasons
  LINES = {
    "scope_mismatch" => "answering it correctly did not need the tagged concept, or the question asked for something the concept does not cover.",
    "unstated_prerequisite" => "solving it needed important knowledge that was neither the tagged concept nor given in the problem.",
    "underdetermined" => "information needed for a defensible answer was missing from it.",
    "reasoning_failure" => "its wording gave away where the problem was or what the solution is, or made the task impossible as set.",
    "code_review.snippet_missing" => "it had no code snippet.",
    "code_review.snippet_too_long" => "its code snippet ran past #{ExerciseSection::CodeReview::MAX_SNIPPET_LINES} lines.",
    "code_review.file_count_wrong" => "it had the wrong number of files, or a single code snippet where files were asked for.",
    "code_review.file_incomplete" => "one of its files had a path without code, code without a path, or a field of the wrong type.",
    "code_review.file_too_long" => "one of its files ran past #{ExerciseSection::CodeReview::MAX_FILE_LINES} lines, " \
                                   "or all of them past #{ExerciseSection::CodeReview::MAX_SNIPPET_LINES}.",
    "code_review.path_invalid" => "one of its file paths ran past #{ExerciseSection::CodeReview::MAX_PATH_LENGTH} characters or " \
                                  "held a line break or another control character, or two of its files had the same path.",
    "code_review.changed_lines_unresolved" => "none of its quoted changed lines matched exactly one line of its file.",
    "security_review.snippet_missing" => "it had no code snippet.",
    "security_review.snippet_too_long" => "its code snippet ran past #{ExerciseSection::SecurityReview::MAX_SNIPPET_LINES} lines.",
    "design_comparison.piece_missing" => "one of its two pieces of code was missing.",
    "design_comparison.piece_too_long" => "one of its two pieces of code ran past #{ExerciseSection::DesignComparison::MAX_PIECE_LINES} lines.",
    "design_comparison.answer_key_incomplete" => "its answer_key was missing one of its fields.",
    "pseudocode_to_code.problem_statement_missing" => "it had no problem statement to plan against.",
    "ambiguity_hunt.planted_ambiguities_missing" => "it listed no planted ambiguities."
  }.freeze

  def self.line(cause) = LINES[cause]
end

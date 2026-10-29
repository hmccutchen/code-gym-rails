# app/models/exercise_section/code_review.rb

## `MAX_SNIPPET_LINES`

The prompt asks for a snippet of about 10 to 15 lines, but until issue #599 nothing checked the reply, and a long snippet costs the most on a phone, where every extra line is more scrolling before the question.

The cap is `RealSource::MAX_LINES` (40) rather than a tighter number. A grounded day asks for a modified copy of a curated excerpt that keeps its shape, and an excerpt can be up to 40 lines, so a lower cap would refuse legitimate grounded sections. A spec runs every curated excerpt through the formatter and the check to hold that. A tighter cap for the toy modes would need a measurement of what providers actually return first. `SecurityReview::MAX_SNIPPET_LINES` reads this constant (#604), so changing it for grounding reasons also moves security_review's cap and its retry line.

Lines are counted after `ProblemSetIngest#format_code!`, so the cap measures the code as shown, and blank lines don't count, the same rule design comparison's `MAX_PIECE_LINES` uses (`ExerciseSection.shown_lines`).

A snippet over the cap is refused, never cut, since cutting code could cut out the planted flaw. `code_review` is a daily kind, so on a judged day a refusal gets up to two retries with its concept fixed before the section is dropped; a weekend set drops it straight away. The refusal message carries the line count and none of the code. A missing or blank snippet is refused the same way.

## Two shapes: one snippet, or two to three files

A `code_review` section comes in one of two shapes. The single-file shape is the `snippet` described above. The multi-file shape replaces it with up to three files in flat fields, `file_N_path`, `file_N_code` and `file_N_changed` for N from 1 to 3, so the problem can sit in how files of one change fit together. A multi-file section has no `snippet` and no diagram: two or three files already show the structure, and a diagram of how they connect would point at the flaw, so `.arrange!` deletes one a provider sends.

`.files(section)` is the one reader of the `file_N_*` fields. It returns a `CodeReview::File` for each file with both a path and code, in order, and an empty list for a single-file section, so the page, the review context and later the key check all read files the same way.

Ingest tells `.reject_unusable!` the file range the day planned (`file_range:`, from `ProblemSetIngest`'s `code_review_files:`). A range whose top is 1 runs exactly the snippet checks above. Any other range runs the multi-file checks, in this order: an incomplete file or a field of the wrong type (`file_incomplete`) first, so half a third file reads as incomplete rather than as a wrong count; then a `snippet` or a file count outside the range (`file_count_wrong`); then length (`file_too_long`); then paths (`path_invalid`); then changed lines (`changed_lines_unresolved`). A passing section loses every field of a file slot that has neither path nor code, so a stray `file_3_changed` reaches nothing.

## Caps on files

Each file may show at most `MAX_FILE_LINES` (15) lines, about a screen and a half on a phone, and all files together at most `MAX_SNIPPET_LINES`, the same 40 a single snippet may show. Lines count the way the snippet cap counts them, with `ExerciseSection.shown_lines` after formatting, so blank lines don't count and there is one way to count. A path may run to `MAX_PATH_LENGTH` (120) characters, and no two files may share one. A file past a cap is refused, never cut, for the same reason a long snippet is: cutting code could cut out the flaw. The refusal messages carry counts and numbers only, never code, a path or a quoted line.

## Why changed lines are quoted, and resolved after formatting

The provider can't count lines reliably, and formatting moves them anyway: RuboCop re-indents Ruby and Prettier rewraps JavaScript. So the provider quotes each changed line's text, and `.reject_unusable!`, which ingest runs after `format_code!`, resolves each quote against the formatted code with `KeyQuote.line`, by whole-line equality with whitespace ignored. A quote matching exactly one line resolves; on JavaScript a quote can also match one run of lines Prettier wrapped, and every line of the run is marked. A quote matching several lines, such as `end`, or none is dropped instead of guessed. The field is replaced with the sorted, unique 1-based line numbers. A section where no file keeps a changed line is refused, since the page would have nothing to mark as the change.

## A single-file range drops every file field

On a range whose top is 1, `.reject_unusable!` also deletes every `file_N_*` field once the snippet passes. `.files` decides the shape for the page, the review context and `.arrange!`, so a stray file field on a single-file day would otherwise turn it into a multi-file section with a snippet nobody shows.

## How files reach a prompt

`CodeReview::File#prompt_text` is the one way a file reads in a prompt: its path, its changed line numbers (or "none") and its code. `.files_context` joins them, and both `.review_context` (in place of the `Code snippet:` line) and `SectionContext` (for the duck and the difficulty assessment) use it, so the two can't describe files differently. A single-file section has no files, so both render as before. Neither reads `answer_key`.

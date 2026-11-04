# `CodeReviewSplit`

The read-only split script the multi-file launch asks for
(`docs/decisions/multi-file-code-review.md`, "The split script"), run as
`bin/rails runner script/split_code_review_results.rb [--log FILE]`, and only
with the owner's approval of the query.

It prints two things, both counts:

- **Reviewed `code_review` results by shape and rung, with each rating.**
  The shape is read from the stored section, since results don't record it:
  `bug_hunt` when the section has a goal line, `multi` when
  `ExerciseSection::CodeReview.files` finds files, and `single` otherwise.
  `bug_hunt` gets its own row because those sections are not mastery
  evidence and would blur the single-file figures the owner compares the
  multi-file ones against. The rung is the section's `pitched_at`; a section
  from before rungs were stamped shows as `unrecorded`. A section left
  unanswered was walked through, not graded, so it counts as `unrated`, and
  so does a rating outside the rubric, which grading logs as `invalid` but
  stores as given, so the buckets always add up to the total.
- **Multi-file key notes by outcome, from a log.** Why a multi-file key was
  dropped is only in the `[planted_key]` line ingest logs; the stored section
  just lacks its key. So `--log` takes a worker log the owner exported, and
  only `kind=code_review` lines marked `code_review_files=multi` count. A line
  from before the field existed has no shape and is left out.

Nothing it prints names an answer, a key, a quote or an account. The log file
holds user ids, so it is saved outside the repository and deleted after the
run, like the baseline export.

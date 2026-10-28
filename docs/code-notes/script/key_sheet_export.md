# `KeySheetExport`

The key sheet for the sampled read of planted keys
(`docs/stored-answer-keys-spec-2026-10-27.md`, section 8, option B), run as
`script/export_review_baseline.rb --key-sheet`.

Each entry is one reviewed section whose kind plants a key and whose stored
section carries one: the kind, scenario, question, the code or plan the key
quotes (`snippet` and `current_schema`, `plan_excerpt`, or
`problem_statement`), and the `answer_key`. A reader judges whether the key
names the real flaw from those alone.

It holds no answer, rating, review, self-rating or date on purpose. The
colleague who reads three of the four kinds sees the problem and its key,
never the owner's work. Only reviewed sections are listed, since a key is
grading data and an unreviewed section may still be answered.

It reads inside `ReviewBaselineExport.read_only`, and its output, like the
baseline export's, is saved outside the repository and deleted after the
read. The key sheet is its own export with its own approval: approving the
baseline export doesn't cover it.

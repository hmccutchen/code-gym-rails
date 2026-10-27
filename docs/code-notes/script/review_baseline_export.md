# script/review_baseline_export.rb

`ReviewBaselineExport` writes one account's graded answers to a JSON file, and
reads that file back as unsaved records, so `script/regrade_review_baseline.rb`
can grade the same days again without a database copy. The entry point for
writing is `script/export_review_baseline.rb`. It is the first step of the
review stability baseline in `docs/stored-answer-keys-spec-2026-10-27.md`.

## What it selects

Up to 50 sections, newest first, from one account's submitted, reviewed days.
A section is taken when `ReviewedSectionResults.for(response, require_rubric:
true, include_eased: true)` returns it, which means it was answered, has a
`pitched_at` rung, a known rating and the current `RUBRIC_VERSION` stamp.
Eased sections stay in, since the grader never sees `eased`. A section whose
rating Ruby fixes (`.fixed_rating` returns one, which today is only Parsons)
is left out, because regrading it would measure nothing. The limit can cut
a day: the day is still exported whole, since grading reads every section of
the day as context, but only the sections taken are listed under `sections`.

## What it writes

Per day: the date, language, `review_provider`, the whole `problem_set`
(answer keys included, since grading needs them and every exported section
has already been reviewed), `plan_notes`, `answers`, `section_ratings` and
`pseudocode_rounds`. Per taken section: the kind, its rung, the answer as
`answer_for` reads it, the stored rating, and `missed` and `essential_gaps`
as the grader wrote them. When the prose judge reworded a review, those two
come from `graded_prose`, so the gaps' positions still point at the list they
number.

The file holds answers and keys, so the runner writes it to stdout for the
caller to redirect outside the repository, and the person running it deletes
the file once the regrade is done. The counts line goes to stderr.
Production logs to stdout, so the runner silences the Rails and Active Record
loggers before it queries anything.

## Read-only

`.read_only` opens a transaction and runs `SET TRANSACTION READ ONLY` first,
so Postgres refuses any write inside it, whatever code runs. The export and
the regrade both run inside it. Nothing in either is meant to write; the
transaction makes that a guarantee rather than a reading of the code.

## Reading it back

`.entries` checks `format`, then builds one unsaved `DailyExercise` and
`DailyResponse` per day for a placeholder `User.new`. Grading reads only
those objects and the section's stamped `pitched_at`, so it sees the day the
way it saw it when the review was written. Building an Active Record object
still reads the table's columns, so the regrade needs a local database with
the schema loaded, but no rows.

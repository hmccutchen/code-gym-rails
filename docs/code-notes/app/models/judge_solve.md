# app/models/judge_solve.rb

`JudgeSolve` keeps one row per blind judge pass on a kind with
`judge_solve_options` (today only `design_comparison`). The full design is in
`docs/answer-key-trust-spec-2026-10-22.md` and
`docs/answer-key-trust-stage1-plan-2026-10-22.md`. This note covers the
reasoning behind the model's code.

## Why `readable` hides a row unless it is proven safe

Each row holds a section snapshot with its `answer_key` and the judge's pick.
If a row for today's design comparison shows up before the engineer answers
it, the page gives the answer away. So `JudgeSolve.readable` starts from
"hidden" and lets a row through only on positive evidence that showing it
gives nothing away:

1. `source = 'synthetic'`. No engineer ever sees the section.
2. The row's own section has been reviewed on the exercise's response, and
   the row belongs to the set that response answered. The engineer has
   already answered it and seen its review.
3. `never_shown_reason` is present. It's written when the row is created, and
   it records that this version's pieces and key never reached the engineer.

Every other row stays hidden, including a live row whose `shipped` is false
by accident or whose reason went missing. The scope doesn't read `shipped`
at all. `shipped` says which version was delivered, and it's set from the
generation control flow. If it were ever wrong, a scope that trusted it
would leak the key. A missing `never_shown_reason` only hides a row that was
safe to show, which costs nothing until the day is reviewed.

## Why `never_shown_reason` leaves out the edit cases

The judge may edit only `title`, `scenario` and `question`. The pieces and
the `answer_key` are the same before and after an edit. Two kinds of record
hold a version that didn't ship, but whose pieces and key did:

- the edited text of a reverted edit (`edit_reverted: true`)
- the pre-edit draft of an edit that was kept

Both carry the engineer's live pieces and key, so neither gets a
`never_shown_reason`. They stay hidden until review. The two allowed reasons
cover versions whose pieces were never delivered:

- `replaced_by_retry`: a rejected attempt that a later, freshly generated
  attempt replaced. A retry builds a new prompt that carries nothing from the
  rejected section, and `DesignComparison.arrange!` rolls the A/B order
  again.
- `section_dropped`: every attempt for a section that was dropped from the
  day.

The check constraint allows a reason only on `source = 'live'` rows with
`shipped = FALSE`. Replay rows judge what shipped, and synthetic rows are
already readable, so neither needs one.

## Why "reviewed" means the row's own section

The engineer's page shows a section's key only once that section has its
review: `DailyResponse#section_reviewed?(section)`, which is
`ai_review&.dig(section).is_a?(Hash)`. A day can be partly reviewed, with
`code_review` graded and `design_comparison` not yet. The response is then
`reviewed?`, but the design comparison's key is still hidden on the page. A
per-response test would show the judge's row for that section early, so
`readable` checks the row's own section.

`DailyResponse.section_reviewed_condition(section)` is the same test in SQL:
`jsonb_typeof(ai_review -> section) = 'object'`. A JSON object is exactly
what Ruby reads back as a Hash, and a missing key, a NULL review or a
non-object value all fail both. `readable` uses it inside a correlated
`EXISTS` on the row's `daily_exercise_id` and `section`, so it composes with
`.or` and never duplicates rows. `judge_solve_spec` ("agrees with
DailyResponse#section_reviewed?") compares scope membership with the
predicate for a reviewed section, another section reviewed, a non-Hash
section value, a submitted response with no review, an unsubmitted one, an
empty review and no response at all.

## Why the review must be of the row's own set

A regeneration replaces the set on the same `daily_exercises` row and keeps
the replaced set's records, under their own `set_generated_at`. It destroys
the old response, and it is refused once a review exists, so a review on that
row is always of the current set. Without a check on the set, the new set's
review would also show the replaced set's rows, whose key the engineer never
answered. So the `EXISTS` joins `daily_exercises` and requires
`daily_exercises.generated_at = judge_solves.set_generated_at`.

That equality holds because `record!` copies `exercise.generated_at`, which
Active Record has already cut to the column's microsecond precision when it
was assigned, into a column of the same precision. `judge_solve_spec` checks
the round trip with a nanosecond-precise time.

## The `human_call` constraint is NULL-safe

The plan wrote the matched branches as `matched = TRUE` and
`matched = FALSE`. In SQL, a CHECK passes when its expression is NULL, and
for an unsolved row (`matched IS NULL`) with a call, the plan's expression
comes out as `FALSE OR NULL OR NULL`, which is NULL. The row would have been
accepted. The migration uses `matched IS TRUE` and `matched IS FALSE`, which
are never NULL, so a call on an unsolved row is refused. The spec "refuses
any call on an unsolved row" pins it.

The model validation (`human_call_fits_matched`, through `.calls_for`) states
the same rule so a form gets a readable error. The spec "matches what the
database constraint allows" tries every pair of `matched` and call against
both, so the two can't drift apart.

## Why the digest isn't used for `shipped`

`section_digest` is the SHA-256 of the section's canonical JSON, with keys
sorted at every depth and array order kept. Two records of the same section
version share a digest, whichever order their keys were built in. It serves
two purposes only: the replay script uses it to skip a section it has already
judged, and the admin header counts one call per section version.

It doesn't decide `shipped`. A server stamp added to a section after
judging changes its hash without changing which version was delivered, so a
digest compared after the fact would mark the delivered version as not
shipped. The generation code already knows which attempt settled and whether
an edit was kept, so `shipped` comes from there.

The digest function lives in `SectionDigest`, a module of its own, so that
`JudgedGeneration::Solve` in the service layer can compute the same value
without naming this model. The model calls it from `before_save` whenever
`judged_section` changes, so every write path fills it in, and
`JudgeSolve.record!` goes through `create!` rather than `insert_all` so that
callback runs.

## `record!` and the `Solve` contract

`JudgeSolve.record!(exercise, solves)` writes one row per solve, all in one
transaction, so one refused row writes none. It reads each solve's
`SOLVE_FIELDS` with `public_send`, so any object that answers those names
works. That's `JudgedGeneration::Solve` in the app and a `Data` stand-in in the
spec. The exercise supplies `user_id`, `daily_exercise_id` and
`set_generated_at` (its `generated_at`). The caller passes `source` (default
`live`) and `draft_model`. `app_revision` defaults to
`JudgeSolve.app_revision`, the one place that reads `RAILWAY_GIT_COMMIT_SHA`,
and it's stored as NULL when the variable is blank or absent.

A refused row raises `JudgeSolve::RecordError`, never the original error.
A PostgreSQL CHECK or NOT NULL violation carries
`DETAIL: Failing row contains (...)`, the whole row with `judged_section`
and its `answer_key`. The jobs log an error's message, so that text would put
the key in the log before review. `RecordError`'s message names only the
constraint (or, for a NOT NULL violation, the column) read from the
PostgreSQL error fields, or the attribute names a validation refused, or the
error class when neither is available. It's raised with `cause: nil` so an
error reporter that walks the cause chain finds nothing either. The
transaction has already rolled back when it's raised, so no row is written.

## The `solve` inflection

Rails singularizes "solves" to "solf" by default, which would break
`has_many :judge_solves` and every route helper for the resource.
`config/initializers/inflections.rb` declares `solve`/`solves` as an
irregular pair, so `judge_solves` maps to `JudgeSolve`.

## One fewer index than the spec lists

The spec asks for an index on each foreign key. The
`(daily_exercise_id, section, section_digest)` index starts with
`daily_exercise_id`, so it already serves any lookup on that key alone, and
the migration leaves out the separate single-column index.

# Spec: make design-comparison key disagreements readable (2026-10-22)

Checked against origin/main at `cb84aec`.

## Why

Every design comparison ships with an answer key: `answer_key.better` (`a`
or `b`, rolled by `ExerciseSection::DesignComparison.arrange!`) plus
`deciding_fact`, `principle` and `why_other_fails`. The judge in
`JudgedGeneration` solves each one blind, and `#solve_matched` compares its
pick with the key. When they disagree, the app writes one log line,
`[judge_solve_mismatch] user=… section=… rung=…`, and then forgets it. The
judge's pick is never written down anywhere, and the log line carries no
section text. Nobody can tell afterwards whether the key or the judge was
wrong.

This change keeps every blind solve, together with the section exactly as
the judge saw it, and adds an admin page for reading the disagreements. It
does not change what a mismatch does: `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL`
stays `false`.

## What exists today

- **`JudgedGeneration#solve_matched`** runs on every judge pass that returns
  a pick. A section can be solved more than once:
  - **The draft**, in `#judge_outcome`.
  - **An edit check.** When the judge edits a design comparison,
    `#confirmed_edit` judges the edited version again, because
    `.rejudge_edits?` is true only for this kind.
  - **Each retry** after a rejection, in `#rejudge`, plus that retry's own
    edit check.
- **What survives a pass.** Only a boolean per pass survives, appended to
  `outcome[:solve_matched]`. The judge's pick (`verdict.solve`) is dropped.
- **Where the booleans go.** `outcomes` reach the `[difficulty_diagnostics]`
  log through `ExerciseDraft.finish` → `GenerationDiagnostics#finished`.
  `AiService::JudgedSet#outcomes` carries them back to the jobs, which never
  store them. Nothing writes `solve_matched` to the database.
- **One side effect already exists.** A mismatch on an edit check reverts
  the edit, whatever the flag says (`reverted = … || matched == false` in
  `#confirmed_edit`). That stays as it is.
- **Judge failures leave no pick.** A judge failure (`#judge_with_fallback`
  returns a reason string) yields no pick at all. The section ships unjudged,
  and the log shows `fallback: "invalid_output"` with no `solve_matched` key.
- **There is no "generation version".** Nothing records a commit, a prompt
  version or a model against a section. `AiService::RUBRIC_VERSION` exists,
  but it versions review ratings, not generation. `ApiUsage` records the
  model for each call, but no row links a call to a section.
- **Only the shipped version is on the row.** `daily_exercises.problem_set`
  holds just the version that shipped. A rejected draft, a reverted edit and
  every retry that was not kept are gone. A regeneration overwrites the row
  in place (`RegenerateExerciseJob`). A day where every section was dropped
  raises `AllSectionsRejectedError` and writes no row.
- **An admin area already exists.** It lives at `Admin::BaseController`,
  gated by `ADMIN_EMAILS`, and has one tool:
  `/admin/suggested_concepts`.

## Where the data lives: a table, not a key on the row

You asked for the result on the row. I recommend a table instead, because
the row only holds the shipped version. A mismatch on a draft that was later
retried, on a reverted edit, or on a set that was regenerated would leave no
pieces to read. Each record therefore carries a snapshot of the section as
the judge saw it. The record is complete on its own, and the admin page
never reads the live row's pieces.

### `judge_solves`, one row per blind solve attempt

| Column | Type | Meaning |
|---|---|---|
| `user_id` | bigint, not null, FK | Owner of the set |
| `daily_exercise_id` | bigint, not null, FK | The row the set was written to |
| `set_generated_at` | datetime, not null | The row's `generated_at` when this set was written, which tells regenerations apart |
| `section` | string, not null | Kind key (today always `design_comparison`; any kind with `judge_solve_options` qualifies) |
| `attempt` | integer, not null | 0 = the draft, 1..n = retry number |
| `edit_check` | boolean, not null | True for the re-judge of an edited version |
| `shipped` | boolean, not null | This exact version is the one delivered |
| `rung` | string, not null | `rung_for(kind)` at judge time |
| `concept` | string | The section's tagged concept |
| `judge_pick` | string, null | `verdict.solve`; null when the judge failed |
| `key_better` | string, not null | `answer_key.better` of the judged version |
| `matched` | boolean, null | Null when the judge failed |
| `unsolved_reason` | string, null | The fallback reason (`invalid_output`, a deadline, …) |
| `judged_section` | jsonb, not null | The section hash the judge was given, plus its `answer_key`: title, scenario, question, `piece_a`, `piece_b`, `deciding_fact`, `principle`, `why_other_fails` |
| `judge_provider` | string, not null | `provider_key` of the service that judged |
| `judge_model` | string, not null | The model the `judge_section` call routed to |
| `draft_model` | string, not null | The model the `generate_exercise` call routed to |
| `app_revision` | string, null | Commit SHA of the running build (see below) |
| `created_at` | datetime | |

Index on `(matched, created_at)` for the page, plus the two foreign keys.
`DailyExercise has_many :judge_solves, dependent: :destroy`. Records are
removed with their exercise, which `User has_many :daily_exercises,
dependent: :destroy` already covers. Anonymizing an account keeps exercises,
so it keeps these records too. They hold generated text only, never an
answer.

**Recording judge failures as well as mismatches.** On 2026-10-19 and
2026-10-20 the judge returned `invalid_output` for user 7's design
comparison, and those sections shipped unjudged. Without these rows, the
page's "N mismatches out of M" would quietly leave out the solves that never
happened.

**What stands in for the generation version.** It's three columns:
`app_revision`, `judge_model` and `draft_model`. A commit SHA pins every
prompt's text exactly, so no separate prompt digest is needed.
`app_revision` reads `RAILWAY_GIT_COMMIT_SHA`. Before relying on it, confirm
that variable reaches the container at runtime: Railway builds this app from
the `Dockerfile`, and nothing in the app reads the variable today. If it
doesn't arrive, pass it in as a Docker build argument. Store null rather
than guessing.

## How the data flows

`JudgedGeneration` stays a module that writes nothing. Each pass that
reaches `#solve_matched`, or that falls back instead, builds a
`JudgedGeneration::Solve` value: section snapshot, attempt, edit_check,
rung, pick, key, matched, unsolved reason. Each value is marked `shipped`
once the section's final version is known. The values go out on a new
`AiService::JudgedSet#solves` field.

**`solves` must never travel through `outcomes` or `finish`.** `outcomes`
are written to the `[difficulty_diagnostics]` log, and the generation rules
say the answer key never reaches that log before review. The existing
booleans in `outcomes[:solve_matched]` and the `[judge_solve_mismatch]` line
stay exactly as they are.

**Who writes the records.** `GenerateDailyExercisesJob#generate_for` and
`RegenerateExerciseJob` write them in the same transaction as the row. In
the regenerate job, that's inside `with_response_locked`, after `update!`.
Both read from one class method, `JudgeSolve.record!(exercise, solves)`. An
unjudged set (weekends, `generate_unjudged_exercise`) passes `solves: []`.

**Where the models come from.** The judge and draft model names come from
the provider class's routing. `route_for` is private today, so expose a
public reader for "the model this purpose routes to". Don't parse the name
out of `ApiUsage`.

**Accepted losses:**
- A day that raises `AllSectionsRejectedError` writes no row, so its solves
  aren't recorded. The `[judge_solve_mismatch]` log line still fires for
  them.
- A regeneration superseded mid-flight (`keep_superseded_set`) writes
  nothing, the same as its set.

## The admin page

`GET /admin/judge_solves` uses `Admin::JudgeSolvesController#index`, which
inherits `Admin::BaseController`. It's plain HTML with no Stimulus
controller.

**Header:** totals for the visible records, by rung and by judge model:
solved, matched, mismatched, unsolved.

**List:** mismatches, newest first. `?show=all` adds matches and unsolved
records, for spot-checking that matches are real too. Each entry shows:

- date, user id, rung, concept, attempt / edit check, shipped or not,
  judge provider and model, draft model, revision
- title, scenario, question
- piece A and piece B, highlighted with `CodeHighlight`, in the order the
  judge saw them
- the key's better piece, `deciding_fact`, `principle`, `why_other_fails`
- the judge's pick

**Spoiler rule, held by a request spec.** A shipped record's key and pick
are rendered only once that exercise's `DailyResponse` is reviewed. Before
that, the entry shows as "waiting for the engineer's review" with no
pieces, key or pick. The reason is that the admin is also a user (user 1),
and the answer-key rule forbids showing a key on a page before review. A
record that never shipped can show at once, because that version never
reached anyone.

**Links.** Add a link from the suggested-concepts page header so the tool
can be found. Page copy goes under `admin.judge_solves` in
`config/locales/en.yml`.

## Out of scope

- `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` and `SOLVE_MISMATCH_TOLERATED_AT`
  stay as they are, and the edit-check revert is unchanged.
- No change to the judge prompt, the draft prompt or `JudgeVerdict`.
- No persistent systems or canon.

## Tests

- **`judged_generation_spec`.** One `Solve` per pass for each of: a matched
  draft, a mismatched draft, an edit check (matched and mismatched; the
  revert behavior stays), a rejected draft then a kept retry (both recorded,
  only the retry `shipped`), and a judge fallback (pick nil, matched nil,
  reason set). Kinds without `judge_solve_options` produce none. Also assert
  that `outcomes` still carry only booleans.
- **`generation_diagnostics_spec`.** The logged payload carries no pick and
  no `answer_key` field, and no `solves` key.
- **Job specs (generate and regenerate).** Records are written with the
  row. A regeneration adds a new `set_generated_at` group and keeps the old
  one. An unjudged weekend writes none.
- **Model spec for `JudgeSolve.record!`.**
- **Request spec for the page:**
  - a non-admin is redirected
  - an unreviewed shipped record hides its key and pick
  - a reviewed one shows them
  - a non-shipped one shows at once
  - `?show=all` includes matches
- **`daily_exercise_plan_notes_spec`** is untouched, since `plan_notes`
  doesn't change.

## Docs to update in the same PR

- `docs/decisions/design-comparison-the-second-fixed-section.md`: blind
  solves are now kept, and how to read them.
- Its `.claude/rules/generation.md` entry: one clause saying solves persist
  to `judge_solves` and never ride `outcomes`.
- `.claude/rules/models.md`: a `JudgeSolve` row.
- `docs/file-map.md`: the model, controller and view.

## What is recoverable today

**No mismatch can be recovered today.**

- **Rows:** nothing. `solve_matched` has never been written to the
  database, and the judge's pick has never been stored anywhere.
- **Logs:** `[judge_solve_mismatch]` and the `solve_matched` booleans have
  been logged since 2026-10-01 (commit `04216b0f`). Railway's production
  logs, however, only reach back to about 2026-10-15; queries before that
  return nothing on both `web` and `worker`. In that window:
  - `[judge_solve_mismatch]` appears zero times on either service.
  - Seven weekday design comparisons were generated through the judge (the
    worker's `[difficulty_diagnostics]`, 2026-10-16 to 2026-10-21; `web`
    logged no generation in the window). Five were solved and matched the
    key. Two (user 7, 10-19 and 10-20) got no solve because the judge
    returned `invalid_output`.
  - None of these logs carry the key or the pick, so even a mismatch logged
    there could not be read without the row.
- **Earlier mismatches** from 2026-10-01 to 2026-10-14 were logged and are
  now gone.

So the data starts with this PR. At the current volume (two active users,
about seven judged design comparisons a week), even a 10% mismatch rate
yields about one disagreement a week. Reading twenty would take months.

### Optional: replay past keys now

The question this data serves is "are the keys right?". Every shipped design
comparison since 2026-10-01 is still on its row with its key and pieces. A
one-off script could send each one through today's `judge_section` and write
the result as a `judge_solves` record with `attempt: 0` and `app_revision`
set to the replay's commit. That separates replayed records from live ones.

It gives readable data right away for the cost of one judge call per
section (Claude routes `judge_section` to `claude-sonnet-5-5` at high
effort). It answers a slightly different question: "does today's judge
agree with that key?" rather than "did the judge at the time agree?". For
judging the keys, today's question is the more useful one.

I did not query the production database, so the number of rows to replay is
unknown. At two users and roughly 15 weekdays it should be about 30 or
fewer. Decide whether to include it in this PR or as a follow-up; it adds a
script under `script/` and nothing under `app/`.

## Open questions for you

1. **Record a human call?** A nullable `human_call` column (`key_right`,
   `judge_right`, `both_defensible`, `neither`) with one form per entry
   would let the later decision count results instead of rereading
   everything. It records your reading; it changes no behavior. I'd include
   it, but you scoped this PR as reading only.
2. **Replay script:** this PR, a follow-up, or not at all.
3. **A table rather than the row:** confirm you accept this change from
   what you asked for. The reason is above.

## Size

One migration, one model, one `Data` value, about 40 lines in
`JudgedGeneration`, a field on `JudgedSet`, a few lines in each job, a
public model-route reader, one controller, one view and the specs. Roughly
400–500 lines with tests. No prompt snapshot changes, because no prompt
text changes.

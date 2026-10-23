# Implementation plan: answer-key trust, stage 1

This plan builds stage 1 of `docs/answer-key-trust-spec-2026-10-22.md`
(from hmccutchen/code-gym-rails#483). Stage 1 is one PR from `main`. Work it
in the order below. Each step is a commit that passes its own specs, so the
branch stays green throughout.

**Merge conditions, from the spec:**
- the OpenAI acceptance passes (step 7)
- the PR description states user 7's provider (step 0)

Everything after the merge is listed at the end for reference and isn't
part of this PR.

**Visibility before review:** the spec's rule was corrected in the same PR
as this plan. Step 1's "Visibility" carries it out.

## Step 0. Before writing code

- Branch from `main` once the spec PR has merged.
- **Rebase risk:** several open PRs touch the same files.
  - #480 sorts `app/services` by layer.
  - #477 moves `CALL_PROFILES` into `CallProfiles`.
  - #478 changes the `ProviderError` classes.
  - #482 rotates `secret_key_base`.

  If any of them merges first, follow its new paths. Paths below are as of
  `cb84aec`.
- **For you to run against production:**
  ```sql
  SELECT provider FROM users WHERE id = 7;
  ```
  Keep the answer for the PR description in step 10.

## Step 1. The `judge_solves` table and `JudgeSolve` model

**Migration:** `db/migrate/<timestamp>_create_judge_solves.rb`.
- It has the columns from the spec's table, including `source`,
  `section_digest`, `edit_reverted`, `revert_reason`, `unsolved_detail`,
  `human_call`, `human_note` and `human_called_at`.
- It adds one column the spec doesn't have: **`never_shown_reason`**
  (string, null). See "Visibility" below.
- Foreign keys go to `users` and `daily_exercises`. Both, plus
  `set_generated_at`, are nullable.
- **Indexes:**
  - `(source, matched, created_at)`
  - `(edit_reverted, created_at)`
  - `(daily_exercise_id, section, section_digest)`

**Check constraints** (each pinned by a model spec that inserts a violating
row and expects `ActiveRecord::StatementInvalid`):
- `source IN ('live', 'replay', 'synthetic')`.
- Non-synthetic rows require `user_id`, `daily_exercise_id` and
  `set_generated_at`.
- `revert_reason` is not null exactly when `edit_reverted` is true.
- **`human_call` is checked against `matched`, not one flat list:**
  ```sql
  CHECK (
    (matched IS NULL  AND human_call IS NULL) OR
    (matched = TRUE   AND (human_call IS NULL OR human_call IN ('key_right', 'both_wrong', 'both_defensible'))) OR
    (matched = FALSE  AND (human_call IS NULL OR human_call IN ('key_right', 'judge_right', 'both_defensible')))
  )
  ```
  A stray `judge_right` on a matched row, or a call on an unsolved row,
  fails in the database, below the model.
- `never_shown_reason IN ('replaced_by_retry', 'section_dropped')`. It is
  allowed only when `shipped = FALSE` and `source = 'live'`.

**Model:** `app/models/judge_solve.rb`.
- `belongs_to :user, :daily_exercise`, both `optional: true`; the check
  constraint enforces them for non-synthetic rows.
- Constants: `SOURCES`, `REVERT_REASONS`, `NEVER_SHOWN_REASONS`,
  `MATCHED_CALLS`, `MISMATCH_CALLS`.
- A model validation repeats the `human_call` rule, so the form gets a
  readable error. The constraint is the guarantee.
- `section_digest` is filled on write from `judged_section`: SHA-256 of the
  canonical JSON, keys sorted recursively. It is used **only** for the
  replay's skip and the header's dedupe, and never to decide `shipped`.
- `JudgeSolve.record!(exercise, solves)` inserts one row per `Solve`.
- **The model must not name `AiService`** (`app_source_spec`).

**Visibility: `JudgeSolve.readable`.** This is the one scope every view
reads for content. It is **hidden unless proven**: a row is readable only
when one of these holds.
1. `source = 'synthetic'`.
2. Its exercise's `daily_response` is reviewed.
3. `never_shown_reason` is present. That's a positive record, written when
   the row is created, that this version's pieces and key never reached
   the engineer.

Anything else is hidden, including a live row whose `shipped` is false by
accident, or whose reason is missing. `shipped` takes no part in the scope.

**The correction to the spec:** two kinds of record carry a version that
didn't ship but whose pieces and key did:
- a reverted edit's edited text
- the pre-edit draft of an edit that was kept

An edit may only touch `title`, `scenario` and `question`, so the code and
the key on both are the engineer's live exercise. They get no
`never_shown_reason` and stay hidden until review. The only safe reasons are:
- **`replaced_by_retry`:** a rejected draft, or a rejected retry, that a
  later attempt replaced with freshly generated pieces.
- **`section_dropped`:** every attempt for a section that was dropped.

**Checked: a retry generates a fresh section and doesn't revise the
rejected one.** `JudgedGeneration#retry_section` hands only the draft, the
kind and the concept to `ExerciseDraft.retry_section`. That method:
- Builds a new `GenerationPrompt` from the plan, history, difficulty and
  ladders. The prompt class takes no problem set at all.
- Renders it with `only: kind, fixed_concept: concept`.
- Sends it as a fresh `retry_section` call. Nothing from the rejected
  section reaches the prompt: not its pieces, its key, its scenario, nor
  the judge's evidence.
- Runs the reply through `ProblemSetIngest` again, where
  `DesignComparison.arrange!` rolls `better` anew. The rejected section's
  only link to the retry is its concept, through `drafted_concept`.

So no path reuses the prior pieces or key, and `replaced_by_retry` is safe
by construction.

**Residual risk, not a reuse path:** the retry is the same prompt with the
same concept, so it can come out close to the rejected draft by chance. The
letter can't carry over, since `better` is re-rolled. A near-identical
`deciding_fact` could. If that's a hint you'd rather not risk, leave
`replaced_by_retry` rows hidden until review too. It costs nothing,
because a rejected draft has no call to make before the day is done.

**A spec pins it.** A `judged_generation_spec` example has the retry
callable record what it receives, and asserts it never gets the rejected
section. An `exercise_draft_spec` example asserts the rendered retry prompt
contains none of the rejected section's piece text. If either fails in
future, `replaced_by_retry` stops being safe.

**Associations:** `DailyExercise has_many :judge_solves, dependent:
:destroy`.

**Specs:** `spec/models/judge_solve_spec.rb`, covering:
- every check constraint, by raw insert
- the `human_call` validation
- the digest: stable across key order, changes when any field changes
- `record!`
- `readable`: each of the three readable cases, and each hidden case
  (unreviewed shipped; shipped false with no reason; a reverted edit; a
  pre-edit draft)

## Step 2. `Solve` values from `JudgedGeneration`

**`app/services/judged_generation/solve.rb`:**
`JudgedGeneration::Solve = Data.define(...)`, holding:
- the judged section
- `attempt`, `edit_check`, `rung`, `locked`
- the verdict status, pick and key
- `matched`, the unsolved reason and detail
- `edit_reverted`, `revert_reason`
- `judge_provider`, `judge_model`
- `shipped`, `never_shown_reason`

**Building them:** build a `Solve` wherever a judge pass runs on a kind
with `judge_solve_options`:
- `#judge_outcome` (the draft)
- `#confirmed_edit` (the edit check)
- `#rejudge` (each retry)
- and each one's fallback branch, when the judge fails

**`shipped` comes from the control flow.** Nothing compares hashes after
the fact. Each kind's solves form a chain, and the code that already knows
which version it kept decides:

- **Edits, in `#confirmed_edit`.** It knows whether the edit was kept.
  - **Kept:** the edit-check `Solve` (the edited version) is the
    candidate. The pre-edit `Solve` is `shipped: false` with no reason,
    because its key shipped.
  - **Reverted:** the pre-edit `Solve` is the candidate. The edit-check
    `Solve` is `shipped: false` with no reason, `edit_reverted: true`, and
    its `revert_reason` from the existing `reverted` test:
    - `check.is_a?(String)` → `judge_failed`
    - `check.reject?` → `judge_rejected`
    - `matched == false` → `solve_mismatch`
- **Attempts, in `#resolve_rejection` and `#rejudge`.** They know which
  attempt settled.
  - **An attempt that was rejected and followed by another:** every
    `Solve` in it gets `never_shown_reason: "replaced_by_retry"`.
  - **The settled attempt:** its candidate is `shipped: true`.
  - **A dropped section:** every `Solve` in its chain gets `shipped: false,
    never_shown_reason: "section_dropped"`. That includes the
    deadline-drop in `#unjudged_retry`, and a retry that returned `nil`.
- **A draft kept on the first pass, in `#judge_outcome`:** that attempt
  settles at 0.

**One way to build it:**
- Accumulate per-kind `Solve`s with their attempt number.
- Return from `#judge_outcome`, `#rejudge` and `#resolve_rejection` which
  attempt settled, if any. A dropped section returns none.
- Finalize every `Solve` once, in one method, from that returned attempt
  and the edit decision already recorded on the `Solve`.

This reads the same values the control flow returns: no digest, no
re-reading of the set.

**Carrying the solves:**
- They travel on an array next to `outcomes`, never inside it.
- `#finish`, `ExerciseDraft.finish` and the `[difficulty_diagnostics]`
  payload don't change.
- `outcomes[:solve_matched]` and the `[judge_solve_mismatch]` line don't
  change either.

**`AiService::JudgedSet`:** add `solves:`. `generate_unjudged_exercise`
passes `solves: []`.

**Provider info:** `JudgedGeneration::Provider` gains `judge_identity`,
the provider key and judge model, as a value next to its callables.
`ReviewGrading::Provider` already carries `provider_key` the same way. It's
built in `AiService#judged_generation_provider`.

**Size:** keep each new method under 25 lines. If `JudgedGeneration`
passes 300 lines, move the chain bookkeeping into
`JudgedGeneration::SolveChain`.

**Specs** (`spec/services/judged_generation_spec.rb`, driven with
lambdas). Assert `shipped` and `never_shown_reason` on every `Solve`:
- a matched draft kept: one `Solve`, shipped
- a mismatched draft kept: shipped, matched false
- an edit kept: the pre-edit `Solve` is not shipped with no reason; the
  edit-check `Solve` is shipped
- an edit reverted (mismatch, rejected, judge failed): the pre-edit `Solve`
  is shipped; the edit-check `Solve` is not shipped, with no reason, and
  with its revert reason
- a rejected draft and then a kept retry: the draft's `Solve`s are
  `replaced_by_retry`; the retry's are shipped
- two rejections and then a drop: every `Solve` is `section_dropped`
- a deadline drop on a retry: `section_dropped`
- a judge failure on the draft: shipped, with pick nil and matched nil
- a kind with no `judge_solve_options`: produces no `Solve`
- a test stamp: a stub that adds a field to the shipped section after
  judging doesn't change any `shipped` value

Also assert that `outcomes` and the revert behavior are unchanged.

## Step 3. Which model each purpose routes to

- Add a public reader to `AiService`, for example `model_for(purpose)`,
  backed by each subclass's private `route_for`. Use it for the judge
  model and `draft_model`.
- **Specs:** one per provider in the existing service specs.

## Step 4. Writing live records from the jobs

- **`GenerateDailyExercisesJob#generate_for`:** wrap `DailyExercise.create!`
  and `JudgeSolve.record!(exercise, judged.solves)` in one transaction.
  `source: "live"`, and `set_generated_at` is the row's `generated_at`.
- **`RegenerateExerciseJob`:** inside `with_response_locked`, after
  `update!`, call `JudgeSolve.record!` with the new `generated_at`. A
  superseded or blocked run writes nothing.
- **`draft_model`:** pass it in from the service that drafted the set.
- **`app_revision`:** `ENV["RAILWAY_GIT_COMMIT_SHA"].presence`, nil when
  absent, read in one place.
- **Specs:**
  - records are written with the row
  - a regeneration adds a new `set_generated_at` group and keeps the old
    one
  - an unjudged weekend writes none

## Step 5. Keeping the refusal message

- **`#fallback_detail`:** include the `JudgeVerdict::Invalid` message for
  every kind. Keep it off for any other error class, since provider error
  bodies can echo content.
- **Storage:** put the message in the `Solve`'s `unsolved_detail`.
- **`spec/models/judge_verdict_spec.rb`:** for every refusal path, the
  message never contains the submitted `better` value.
- **`spec/services/generation_diagnostics_spec.rb`:** the payload carries no
  pick, no `answer_key` and no `solves`.

## Step 6. The `judge_shape` tooling, then the baseline on unmodified code

**Tooling** (commit this first):
- Add a `judge_shape PROVIDER` mode to `script/compare_models.rb`, with the
  method in `script/model_comparison.rb`. It runs the 14
  `spec/fixtures/judge/design_comparison_*.json` fixtures once through that
  provider's `judge_section`.
- **Keys:** read from `OPENAI_API_KEY`, `GEMINI_API_KEY` or
  `ANTHROPIC_API_KEY`. The script's current abort on a missing
  `ANTHROPIC_API_KEY` must allow this mode to use the provider's own key.
- **The route:** pin it the way `#pinned_service` does. For OpenAI it sets
  `reasoning_allowance: 4_000`.
- **Output:** counts only (`invalid_output`, `truncated`, solved), plus
  `JudgeVerdict::Invalid` messages. Never a solve or a key.
- **Specs:** `spec/script/model_comparison_spec.rb`, with stubbed services.

**Baseline** (with that commit checked out and `OpenaiService` untouched):
- Run `judge_shape openai`: 14 calls.
- Record the counts and the commit SHA in the PR description draft.
- **If you need more rounds later:** the baseline commit is the reference.
  Re-run it from a `git worktree` at that SHA, never from a stash.

## Step 7. The OpenAI schema change, then the comparison run

**The change:**
- **`OpenaiService#request_body`:** when `request.response_schema` is
  present, append "Reply with a JSON object matching this JSON Schema:"
  followed by the compact schema. Strict mode stays off.
- **`spec/services/openai_service_spec.rb`:** with a schema the line is
  present, and without one the request is byte-identical to before.
- **Snapshots:** re-record the OpenAI request snapshots in
  `spec/fixtures/request_snapshots/openai__purpose__*.json` for the
  purposes that send a schema, with `UPDATE_PROMPT_SNAPSHOTS=1`. Check
  `git diff --stat spec/fixtures` shows nothing else moving.
- Commit the change and the snapshots together.

**The run:**
1. Run `judge_shape openai` on that commit: 14 calls.
2. Run `judge_shape claude` and `judge_shape gemini`: 28 calls, under $1.
3. Apply the spec's rule:
   - **Pass:** the baseline reproduces the failure, and the change brings
     `invalid_output` to at most 1 of 14.
   - **Ambiguous:** run three rounds per side. The baseline side runs from
     the step 6 worktree.

Put both sides' counts and SHAs in the PR description.

## Step 8. The replay script

**Files:** `script/replay_design_comparison_solves.rb` (the entry point and
usage) and `script/design_comparison_replay.rb` (the class), following the
`compare_models` / `ModelComparison` split.

**Selection:**
- `daily_exercises` where `problem_set -> 'design_comparison' ->
  'answer_key' ->> 'better' IN ('a','b')`, with both pieces present, and
  not dropped
- skip it when a `replay` record already exists for the same
  `(daily_exercise_id, section, section_digest)`, unless `--rejudge`

**Modes:**
- **Dry run, the default:** count by week and by user, the first and last
  date, and the cost bound. Makes no calls.
- **`--run`:** judges with a `ClaudeService` built from
  `ANTHROPIC_API_KEY`. It uses `rung: section["pitched_at"]` and
  `locked: false`, runs sections one at a time, and prints progress. A
  failure becomes an unsolved record.
- **`--synthesize N`:** spreads N sections across the rungs and the
  design-comparison vocabulary, through `retry_section` as
  `ModelComparison#judge_concept` does, then judges each one. It writes
  `source: "synthetic"` with no user or exercise.

**Replay records:** `source: "replay"`, `attempt: 0`, `edit_check: false`,
`shipped: true`, no `never_shown_reason`. They judge what shipped, so they
stay hidden until that day is reviewed.

**Specs:** `spec/script/design_comparison_replay_spec.rb`, driven with a
lambda judge. It covers:
- the dry run makes no calls and writes nothing
- the selection filters
- the digest skip with `app_revision` nil, and `--rejudge`
- `--run` aborts with no key
- a failed call becomes an unsolved record
- synthetic rows have no user or exercise

## Step 9. The admin page

**Routes:** in the `admin` namespace,
`resources :judge_solves, only: [:index, :update]`.

**`app/controllers/admin/judge_solves_controller.rb`:**
- `index` reads the `source`, `show`, `call` and `n` filters, with defaults
  `source=live` and `show=mismatches`.
- `update` loads its row through `JudgeSolve.readable` (a hidden row
  returns 404). It permits `human_call` and `human_note` only, and sets
  `human_called_at`.

**Content always comes through `JudgeSolve.readable`.** A row outside it
renders as "waiting for the engineer's review", showing only its date,
source and rung: no pieces, key, pick or form.

**`matched_sample`:**
- `JudgeSolve.readable`, restricted to the source filter minus synthetic
- matched, unsolved left out, not at `principal_engineer`
- no `human_call` yet
- `ORDER BY random() LIMIT n`

**Header counts:** a query object, `JudgeSolve::Counts`, in
`app/models/judge_solve/counts.rb`.
- It runs SQL `GROUP BY` queries: by source, by matched or mismatched, by
  `human_call`, and reverts by reason.
- The call tables group on `section_digest`, take the latest
  `human_called_at` per digest, and leave out unsolved records and
  `rung = 'principal_engineer'`.
- **Every count is computed over `JudgeSolve.readable` only.** A raw
  matched or mismatched tally including today's hidden row would say
  whether the unanswered design comparison was a mismatch, before you've
  done it.
- The header adds one separate line, **"withheld pending review: n"**. It's
  a single count of non-readable rows, broken down by nothing: no source,
  outcome or rung.
- The call tables are unaffected either way, since a hidden row can't carry
  a call. The update action 404s on a hidden row.
- No computed bound and no branch.

**View:** `app/views/admin/judge_solves/index.html.erb`, plus a partial per
entry, its required locals noted in its one comment.
- Pieces use `highlighted_code`.
- A reverted edit shows the shipped original's prose beside the edited
  prose, once both rows are readable.
- A live record links to its replay record, and back.
- No `<script>`. The form is a plain `form_with`.

**Copy:** under `admin.judge_solves` in `config/locales/en.yml`. Link to the
page from `admin/suggested_concepts/index.html.erb`.

**Specs:**
- `spec/requests/admin/judge_solves_spec.rb`:
  - a non-admin is redirected on both actions
  - unreviewed shipped rows are hidden, for live and replay
  - **a live row with `shipped: false` and no `never_shown_reason` (the
    accidental case) is hidden, and its key and pick never appear in the
    response body**
  - a reverted edit's edit-check row is hidden before review
  - a pre-edit draft of a kept edit is hidden before review
  - `replaced_by_retry`, `section_dropped` and synthetic rows are shown
  - reviewed rows are shown
  - `PATCH` on a hidden row returns 404
  - each filter works
  - `matched_sample` draws only readable rows and respects the limit
  - `PATCH` accepts the allowed values per `matched`, refuses `judge_right`
    on a matched row, and ignores any other attribute
- `spec/models/judge_solve/counts_spec.rb`:
  - a hidden mismatched row changes no outcome count, only the withheld
    count
  - the withheld line carries no breakdown
  - one count per digest
  - unsolved and principal-engineer rows left out
  - matched and mismatched calls counted apart
  - every count split by source

## Step 10. Docs, checks and the PR

**Docs:**
- `docs/decisions/design-comparison-the-second-fixed-section.md`: solves
  and reverts are kept, the replay exists, how to read both, and the
  hidden-unless-proven visibility rule.
- `.claude/rules/generation.md`: one clause, "solves persist to
  `judge_solves` and never ride `outcomes`".
- `.claude/rules/models.md`: a `JudgeSolve` row.
- `docs/file-map.md`: the new files.

**Checks:**
- `bundle exec rubocop` and `bin/comment-check`.
- The full unit suite, since `AiService` and `JudgedGeneration` are shared
  authorities.
- `spec/system` once.
- `bin/brakeman`.
- Grep for dead locals; `Lint/UselessAssignment` is off.
- The isolation specs still pass untouched.

**PR description:**
- what was built
- the baseline and comparison counts, with both SHAs
- user 7's provider, and whether the `invalid_output` cause is confirmed or
  still open
- that `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` is untouched
- the local-first replay plan
- the `judge_identity` value on `JudgedGeneration::Provider`, as a pattern
  note

**Intent log:** add the entry, then run `compose.rb` and `check.rb`.

## After merge (not this PR)

1. Run the SQL count, then dump `users`, `daily_exercises` and
   `daily_responses` locally. Run the replay dry, then with `--run`. Read
   the mismatch rate, and delete the dump.
2. Re-run the replay against production once deploys work.
3. Call the mismatches and the first matched draw. Draw again if 3 or more
   are bad.
4. Decide on synthesis from the replay's real numbers.
5. Apply the decision rule by hand. Stage 2 is its own PR.

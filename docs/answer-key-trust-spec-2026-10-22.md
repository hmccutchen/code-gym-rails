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

This change does six things:

- keeps every blind solve, with the section exactly as the judge saw it
- replays every stored design comparison through today's judge, so there
  is data to read now
- adds an admin page for reading the disagreements and recording a verdict
  on each one
- records the edits that a mismatch already throws away
- sends OpenAI the reply schema it's held to, and confirms or reopens the
  diagnosis of the judge's `invalid_output` failures, which lost two of the
  seven blind solves in the last week of logs
- commits, before any data exists, to which fix gets built at what count

The work is split into two PRs, with the hand calls in between on merged
`main`:

- **Stage 1 (this spec's PR)** builds the record, the replay, the page and
  the OpenAI schema change. `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` stays
  `false`.
- **Stage 1 merges** once both of these are true. Nothing else holds it,
  and no hand call is a merge condition:
  - the OpenAI acceptance passes (see "Acceptance before stage 1 merges")
  - the PR description states user 7's provider (see "Confirming the
    diagnosis, before stage 1 merges")
- **After the merge, on `main`:**
  - run the replay
  - make your hand calls on its mismatches and on the matched sample (see
    "Matched spot-checks")
  - let live solves accumulate

  This takes weeks, and no branch is held open for it.
- **Stage 2 is its own PR:** the fix the decision rule picks, once the
  calls clear its bar. It is mechanical by design, because the rule below
  names exactly what gets built for each outcome.

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
  The booleans reach the `[difficulty_diagnostics]` log through
  `ExerciseDraft.finish` → `GenerationDiagnostics#finished`, and nothing
  writes them to the database.
- **A mismatch already changes what ships.** `#confirmed_edit` reverts an
  edit when its re-check mismatches (`reverted = check.is_a?(String) ||
  check.reject? || matched == false`), whatever
  `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` says. Edits only touch `title`,
  `scenario` and `question` (`.prose_fields`). The pieces and the key are
  the same before and after, so a revert on a mismatch means the prose
  change alone moved the judge's pick. The only trace today is
  `edit_reverted: true` in the log's outcome hash. The edited text is
  discarded.
- **Judge failures leave no pick.** A judge failure (`#judge_with_fallback`
  returns a reason string) yields no pick at all. The section ships unjudged,
  and the log shows `fallback: "invalid_output"` with no `solve_matched` key.
- **There is no "generation version".** Nothing records a commit, a prompt
  version or a model against a section. `ApiUsage` records the model for
  each call, but no row links a call to a section.
- **Only the shipped version is on the row.** `daily_exercises.problem_set`
  holds just the version that shipped. A rejected draft, a reverted edit and
  every retry that was not kept are gone. A regeneration overwrites the row
  in place.
- **An admin area already exists.** It lives at `Admin::BaseController`,
  gated by `ADMIN_EMAILS`, and has one tool:
  `/admin/suggested_concepts`.

## The answer to your question: reverted edits

**The first draft of this spec did not record reverts as reverts.** It
stored the edit check's solve as a record with `edit_check: true` and
`matched: false`. That captured the mismatch, but it left the revert to be
inferred from three columns. It also missed two kinds of revert entirely:

- an edit check that **rejected** the edited version
- an edit check where the **judge failed** on the edited version

Both of these revert the edit too, without any mismatch.

**This version records a revert explicitly.**
- Every edit-check record carries `edit_reverted` and `revert_reason`
  (`solve_mismatch`, `judge_rejected` or `judge_failed`).
- The edited text is kept in that record's `judged_section`.
- The shipped original sits in the matching record with `edit_check: false`,
  so the page can show the two versions side by side.
- The page lists reverted edits first.

## Where the data lives: `judge_solves`

A table, one row per judge pass on a kind with `judge_solve_options`
(today only `design_comparison`). Each row carries a snapshot of the section
as the judge saw it. The record is complete on its own, and the admin page
never reads the live row's pieces.

| Column | Type | Meaning |
|---|---|---|
| `user_id` | bigint, not null, FK | Owner of the set |
| `daily_exercise_id` | bigint, not null, FK | The row the set was written to |
| `set_generated_at` | datetime, not null | The row's `generated_at` for this set, which tells regenerations apart |
| `source` | string, not null | `live` (a blind solve made while generating the set), `replay` (a stored section judged later by the replay script) or `synthetic` (a section generated by the script for measurement only; see "Topping up") |
| `section` | string, not null | Kind key |
| `attempt` | integer, not null | 0 = the draft, 1..n = retry number; always 0 for a replay |
| `edit_check` | boolean, not null | True for the re-judge of an edited version; always false for a replay |
| `shipped` | boolean, not null | This exact version is the one delivered |
| `edit_reverted` | boolean, not null | True on an edit check whose edit was thrown away |
| `revert_reason` | string, null | `solve_mismatch`, `judge_rejected` or `judge_failed`; set only when `edit_reverted` |
| `rung` | string, not null | The rung the judge was told |
| `locked` | boolean, not null | The `locked:` flag the judge was told; always false for a replay, which can't recover it |
| `concept` | string | The section's tagged concept |
| `judge_status` | string, null | `keep`, `edit` or `reject`; null when the judge failed |
| `judge_pick` | string, null | `verdict.solve`; null when the judge failed |
| `key_better` | string, not null | `answer_key.better` of the judged version |
| `matched` | boolean, null | Null when the judge failed |
| `unsolved_reason` | string, null | The fallback reason when the judge failed |
| `unsolved_detail` | string, null | `JudgeVerdict::Invalid`'s message, which never quotes the solve (see "Judge failures") |
| `judged_section` | jsonb, not null | The section hash as judged, with its `answer_key` |
| `section_digest` | string, not null | SHA-256 of `judged_section`, computed on write from its canonical JSON (keys sorted recursively), so two records of the same section version share a digest |
| `judge_provider` | string, not null | `provider_key` of the service that judged |
| `judge_model` | string, not null | The model the `judge_section` call routed to |
| `draft_model` | string, null | The model that drafted the set; null for a replay, since nothing recorded it |
| `app_revision` | string, null | Commit SHA of the running build |
| `human_call` | string, null | On a mismatch: `key_right`, `judge_right` or `both_defensible`. On a matched record: `key_right`, `both_wrong` or `both_defensible` (see "Matched spot-checks") |
| `human_note` | text, null | Free text alongside the call |
| `human_called_at` | datetime, null | When the call was last saved |
| `created_at` | datetime | |

Indexes:
- `(source, matched, created_at)` for the page
- `(edit_reverted, created_at)` for the revert list
- `(daily_exercise_id, section, section_digest)`, for the replay's skip
  and the header's dedupe
- the two foreign keys

`DailyExercise has_many :judge_solves, dependent: :destroy`, which a
user's deletion already reaches through `has_many :daily_exercises`.
Anonymizing an account keeps exercises, so it keeps these records too. They
hold generated text only, never an answer.

**What `human_call` means.** `both_defensible` is the finding that points
at an ambiguous problem rather than a bad key or a bad judge. The page
counts it on its own.

A matched record needs one value a mismatch can't take. When the key and
the judge picked the same piece, `judge_right` is impossible. The failure a
matched record can hide is that both are wrong, so a matched record takes
`both_wrong` in its place.

A model validation holds each record's three values, chosen by `matched`.
`human_call` and `human_note` are the only columns the page may write.

**Recording judge failures.** These rows make the "N mismatches out of M"
count honest. On 2026-10-19 and 2026-10-20 the judge returned
`invalid_output` for user 7's design comparison, and those sections shipped
unjudged.

**What stands in for the generation version.** It's three columns:
`app_revision`, `judge_model` and `draft_model`. `app_revision` reads
`RAILWAY_GIT_COMMIT_SHA` and stores null when it's absent. Check the
first records written after the first deploy. If the column is null there,
the variable isn't reaching the container, and passing it in is a separate
follow-up.

## Live flow

`JudgedGeneration` stays a module that writes nothing. Each judge pass on a
kind with `judge_solve_options` builds a `JudgedGeneration::Solve` value
carrying the snapshot and the columns above, including passes where the
judge failed. `#confirmed_edit` sets `edit_reverted` and `revert_reason` on
the edit-check `Solve` it creates. Each value is marked `shipped` once the
section's final version is known. The values go out on a new
`AiService::JudgedSet#solves` field.

**`solves` must never travel through `outcomes` or `finish`.** `outcomes`
are written to the `[difficulty_diagnostics]` log, and the key must never
reach that log before review. `outcomes[:solve_matched]`, `edit_reverted`
and the `[judge_solve_mismatch]` line stay exactly as they are.

**Who writes the records.** `GenerateDailyExercisesJob#generate_for` and
`RegenerateExerciseJob` write them with `JudgeSolve.record!(exercise,
solves)`, in the same transaction as the row. In the regenerate job, that's
inside `with_response_locked`, after `update!`. An unjudged weekend set
passes `solves: []`.

**Where the models come from.** The judge and draft model names come from
the provider class's routing. `route_for` is private today, so expose a
public reader for "the model this purpose routes to". Don't parse the name
out of `ApiUsage`.

**Accepted losses:**
- A day that raises `AllSectionsRejectedError` writes no row, so its solves
  aren't recorded. The log line still fires.
- A regeneration superseded mid-flight (`keep_superseded_set`) writes
  nothing, the same as its set.

## Replay

`script/replay_design_comparison_solves.rb`, run with `bin/rails runner`.
It asks today's judge to solve every stored design comparison blind and
writes one `source: "replay"` record per section. It never changes an
exercise.

### How far back the data goes

Design comparison is the only kind with a key that can be scored. It went
in on 2026-10-01 (`855faedb`, 18:30 ET). The judge started solving it blind
an hour later, on the same evening (`04216b0f`). Mismatch logging started
with that second commit, so 2026-10-01 is the start of both the kind and the
logging.

**The stored key's shape hasn't changed since the kind went in:**
- `arrange!` writes `{ "better" => "a"|"b" }` plus `deciding_fact`,
  `principle` and `why_other_fails`.
- `reject_unusable!` has refused a key missing any of those three since the
  first commit.
- No migration has touched `problem_set`'s design comparison.

So every stored design comparison can be scored, back to the first one.
Every one also carries `pitched_at`, which ingest has stamped since
2026-09-24 (#199), so the replay can tell the judge its rung.

**Two differences from what shipped:**
- Pieces stored before 2026-10-10 (#331) were never re-indented at ingest,
  so the judge sees them as they were shown at the time.
- The `locked` flag was never stored, so a replay passes `locked: false`.
  The record says so.

### Which sections the replay picks

Every `daily_exercises` row whose `problem_set` has a `design_comparison`
with `answer_key.better` in `a`/`b`, `piece_a` and `piece_b`, and whose
`dropped_sections` doesn't name `design_comparison`. That includes weekend
sets, which were never judged live, and it includes today.

A row that was regenerated holds only its current set, so the replay judges
that set.

**Already-replayed sections are skipped.** The skip keys on
`(daily_exercise_id, section, section_digest)` with `source: "replay"`, so
re-running after an interruption costs nothing extra.

It does not key on `app_revision`. That column is expected to be null until
Railway's SHA is confirmed reaching the container, and `= NULL` never
matches, so a revision key would re-judge every section already paid for.
To deliberately re-judge with a changed judge, such as branch A's
acceptance run, pass `--rejudge`.

### Running it

- **Dry run is the default.** It prints the count by week and by user, the
  earliest and latest date, and the cost bound below. No provider call is
  made.
- **`--run`** makes the calls, billed to `ANTHROPIC_API_KEY` from the
  environment. It never uses a user's stored key, the same rule
  `script/compare_models.rb` follows, and builds its `ClaudeService` the way
  `ModelComparison` does. Every replay record therefore comes from the same
  judge: `claude-sonnet-5-5` at high effort, through today's
  `SectionJudgePrompt`.
- It runs one section at a time and prints progress. A failed call becomes a
  record with `unsolved_reason`, and the run continues.

### Count and cost before you run it

**I couldn't get the exact count from this session.** The production
database isn't reachable from here: the session's network goes through an
HTTPS proxy and `psql` can't use it. The dry run prints the count. So does
this query, run read-only against production:

```sql
SELECT date_trunc('week', date)::date AS week, count(*) AS sections,
       min(date) AS first, max(date) AS last
FROM daily_exercises
WHERE problem_set -> 'design_comparison' -> 'answer_key' ->> 'better' IN ('a', 'b')
  AND NOT dropped_sections ? 'design_comparison'
GROUP BY 1 ORDER BY 1;
```

**Bound on the count:** at most one section per user per day, from
2026-10-01 to today, which is 22 days. Users 1 and 7 are the only ones who
generated a set in the logs I can see.

**This bound may be low.** Those logs start on 2026-10-15, but design
comparison went in on 2026-10-01, so other users may have generated sets in
that first fortnight. Run the SQL count above before budgeting the replay.
The table below shows how the cost scales.

**Cost per call.** Each call sends about 3,000–3,500 input tokens: the
design comparison judge's system prompt is 5.3k characters, its schema
2.6k, and the prompt carries both pieces, about 3–5k characters. Output is
capped at 1,200 tokens (`JUDGE_MAX_TOKENS`), thinking included. At Sonnet
5.5's $2 / $10 per million tokens, that's at most about $0.019 per call.

**Total:**

| Sections | Worst case |
|---|---|
| 44 (two users, every day) | about $0.85 |
| 220 (ten users, every day) | about $4.20 |

### Topping up with generated sections

`--synthesize N` generates N fresh design comparisons, spread evenly across
the four rungs and the design-comparison vocabulary, the way
`ModelComparison#judge_concept` already does. It judges each one blind and
writes `source: "synthetic"` records with no user and no exercise.
`user_id`, `daily_exercise_id` and `set_generated_at` become nullable for
this source only, enforced by a check constraint.

**Synthetic records support a branch. They never select one.** The even
spread doesn't match the real mix of rungs and concepts, so it could give
a branch (C most easily) a win the real data wouldn't. The decision rule
counts them separately and lets them corroborate only.

**Whether to run it at all is decided after the replay.**
- Run the replay first, and read its mismatch count and rate.
- If live plus replay already holds 12 or more mismatches to call, skip
  synthesis and its cost.
- If it holds fewer, synthesis still can't select a branch, so it buys
  corroboration and nothing else. Run it only if you want that while live
  solves accrue.

**Cost:** each section is one `retry_section` call on `claude-opus-5-5`
plus one judge call, about $0.12 at worst, so 120 sections cost about $15.

**Spoiler rule:** synthetic records never reached anyone, so the page
shows them at once.

## Judge failures (`invalid_output`)

### What the logs show

User 7's design comparison judge failed on 2026-10-19 and 2026-10-20 and
succeeded on 2026-10-21. Everything the log can say about those two
failures:

- **The JSON parsed.** `invalid_output` comes only from
  `JudgeVerdict::Invalid` (`AiService.judge_fallback_reason`). Unparseable
  JSON logs `invalid_json`, and a reply cut short at the token cap logs
  `truncated`. So this is neither a format failure nor a truncation: the
  reply was valid JSON whose content `JudgeVerdict.parse` refused.
- **The judge answered quickly,** in 4.1 and 3.5 seconds. That doesn't fit
  a reply that hit the cap.
- **The other judge passed.** In both runs the `code_review` judge for the
  same user succeeded. The difference is the field only design comparison
  needs: `better`.
- **No retry happened.** `#judge_with_fallback` makes one call, and a
  `JudgeVerdict::Invalid` ships the section unjudged.
- **The message was dropped.** `#fallback_detail` leaves the error message
  out for any kind with `judge_solve_options`, so the log can't say which
  check failed. That's more caution than needed: `JudgeVerdict`'s own class
  comment guarantees no error message quotes the solve. Its messages name
  a missing or unknown value, never `better`'s content.

### Most likely cause: OpenAI never receives the reply's shape

The three providers send the verdict schema differently:

| Provider | How the schema is sent | Enforced? |
|---|---|---|
| Claude | `output_config.format`, a `json_schema` | Yes |
| Gemini | `response_format` with `schema` | Yes |
| OpenAI | JSON mode only (`text.format: json_object`, plus "Reply with a JSON object."); the schema itself is never sent, because strict mode can't take `VerdictSchema`'s root `anyOf` (`openai_service.rb:55`) | No |

On OpenAI the model learns the reply's shape from the prompt text alone.
The judge's system prompt lists the three reply shapes (`{"status":"keep"}`
and the edit and reject forms) **without** `better`. Only one sentence in
the per-kind prompt adds it: `Put your solve in "better" ("a" or "b") and
nowhere else`. A low-effort model (`gpt-6-astra`, effort `low`) copying
the listed shapes leaves `better` out, or writes `"A"`. Either way,
`JudgeVerdict.parse_solve` raises, and that fits every fact above.

**One fact is not confirmed: that user 7 is on OpenAI.** Nothing in the
logs names the provider, and I couldn't reach the production database.

### What gets built, whatever the diagnosis

1. **Give OpenAI the shape it's held to.** This is right on its own
   merits: every OpenAI call with a `response_schema` is held to a shape it
   never sees. With JSON mode on, `OpenaiService#request_body` appends the
   request's `response_schema` to the prompt, as compact JSON after "Reply
   with a JSON object matching this JSON Schema:". Strict mode stays off for
   the `anyOf` reason above.
   - **Where it lives:** this is provider-specific, so it belongs in
     `OpenaiService`. No prompt class changes.
   - **What it covers:** every purpose that sends a schema on OpenAI, which
     also includes the review prose judge.
   - **Snapshots:** OpenAI request snapshots for schema'd purposes change.
     No other snapshot does.
2. **Log and store the refusal's message.**
   - `#fallback_detail` includes `JudgeVerdict::Invalid`'s message for
     every kind.
   - The message is stored in `judge_solves.unsolved_detail`.
   - A spec holds that no `JudgeVerdict::Invalid` message contains the
     submitted `better` value.
3. **No retry.** Revisit only if the acceptance check below still fails.

### Confirming the diagnosis, before stage 1 merges

Run `SELECT provider FROM users WHERE id = 7;` against production, and
state the result in the PR description:

- **User 7 is on OpenAI.** The `invalid_output` cause is confirmed as the
  missing schema, and the acceptance check below is its test.
- **User 7 is on Claude or Gemini.** The cause is still open. The schema
  change stands on its own and still merges. The investigation reopens
  with the logging change in place, which names the failing check on the
  next `invalid_output`. The PR description says the cause is open and
  what the next failure will show.

### Acceptance before stage 1 merges

- **OpenAI, first pass: 28 calls.** Run the 14 design-comparison judge
  fixtures in `spec/fixtures/judge` through `OpenaiService#judge_section`
  once on the current code and once with the schema change, billed to
  `OPENAI_API_KEY` from the environment. A missing instruction fails the
  same way every time, so one round per side is enough.
- **Reasoning is capped for this run only.** The run pins its route the way
  `ModelComparison#pinned_service` does, with `reasoning_allowance: 4_000`
  in place of production's 25,000. That makes the per-call output cap
  1,200 + 4,000 = 5,200 tokens. Production's route doesn't change.
- **Report three counts per side:** `invalid_output`, `truncated`
  (a reply that hit the lower cap), and solved.
- **Pass:** the current code reproduces the failure on some fixtures, and
  the schema change brings `invalid_output` to 0 or 1 of 14.
- **Ambiguous:** expand to three rounds per side, 84 calls at the same cap,
  only in these cases:
  - the current code shows no failures, so the cause didn't reproduce
  - the fixed side still fails 2 or more
  - `truncated` appears, so the cap itself is in the way
- **Claude and Gemini:** run the same 14 fixtures once through each, to
  confirm the change touched neither. That's 28 calls.
- This needs a small `judge_shape` mode in `script/compare_models.rb` that
  can take a provider and a reasoning cap. Today that script is
  Claude-only.

**Token arithmetic for the 28 OpenAI calls:**

| | Per call | 28 calls |
|---|---|---|
| Input | system 5.3k chars + prompt about 1.5k + section about 1.0k (the fixtures run 0.4–1.7k) + schema 2.6k (the fixed side only) ≈ 10.4k chars ≈ **2,600 tokens**; without the schema ≈ 2,000 | 14 × 2,000 + 14 × 2,600 ≈ **64k tokens** |
| Output, expected | reply about 150 tokens + reasoning at effort `low`, assumed about 1,000–2,000 | **about 32k–60k tokens** |
| Output, worst case | the run's cap: 1,200 + 4,000 = 5,200 | **146k tokens** |

**Cost = 0.064 × (input price per million) + 0.06 × (output price per
million) expected, or 0.064 × the input price + 0.146 × the output price
at worst.** OpenAI bills reasoning as output. `gpt-6-astra`'s price is
unverified: look it up and multiply. Expanding to three rounds triples
both figures (0.19M input, 0.44M output at worst). Claude and Gemini's 28
calls are under $1.

## Decision rule

This section is written before any data exists, and stage 2 builds
whatever it selects. You apply it by hand from the page's counts; no code
computes it.

**Counting rules:**
- **The unit is a distinct section version,** not a record.
  - Records with the same `section_digest` (a live solve and its replay,
    for example) count once, using the human call on either. If they carry
    different calls, the more recent `human_called_at` counts.
  - The header does this in SQL, grouping on `section_digest`, rather than
    hashing jsonb in Ruby.
  - Edit-check versions count as their own versions.
- **Unsolved records don't count.** Neither do principal-engineer sections,
  because `SOLVE_MISMATCH_TOLERATED_AT` already accepts disagreement there.
- **Every count is reported by source.** Only live plus replay can select
  a branch.
  - Synthetic records corroborate: if their leading call agrees with live
    plus replay's, say so in the PR. They never push a count over a bar,
    and they never count toward the 30 that triggers branch D.
  - The page's live-only default is for reading what shipped. The decision
    counts use live plus replay together.

### Mismatch bar

A branch is chosen when **at least 12** live-plus-replay mismatches carry a
human call **and** one call clears the threshold below. The threshold is
where a one-sided 90% Wilson lower bound on that call's share passes 50%.
Put plainly: at that bar you can be 90% sure that call is truly a majority,
not a lucky streak.

| Called mismatches (live + replay) | Needed for one call |
|---|---|
| 12 | 9 (75%) |
| 15 | 10 (67%) |
| 20 | 13 (65%) |
| 25 | 16 (64%) |
| 30 | 19 (63%) |

**Stopping:** decide at the first count from 12 onward where a call clears
the bar. If none has cleared it by 30, take branch D.

### Matched spot-checks

The drafter (`claude-opus-5-5`) and the judge (`claude-sonnet-5-5`) are one
model family. When both are wrong the same way they agree, and the section
records as matched. A mismatch-only sample can't see that failure, however
large it grows.

**After stage 1 merges, the hand calls include 10–15 matched records, plus
a second draw of 15–20 if the first shows 3 or more bad.**
- The page's random matched sample serves them from live plus replay, and
  never synthetic.
- Each gets `key_right`, `both_wrong` or `both_defensible`.
- The page counts matched calls apart from mismatch calls, so they never
  mix.

**The matched sample triggers a second draw. It never selects a branch
from the first draw alone.**

- **First draw, 10–15 records.** If **3 or more** are `both_wrong` or
  `both_defensible`, draw another 15–20 matched records and call those too.
  At 3 of 15 the one-sided 90% Wilson lower bound on the bad share is
  0.1005, which clears 10% by a hair. One call either way would flip which
  branch gets built, so the first draw only earns a second look.
  - **Below 3:** the matched sample selects nothing, and the mismatch bar
    decides alone.
- **Combined sample, 25–35 records.** The combined sample selects a branch
  when **6 or more** are bad. At 6 bad the lower bound stays above 10% at
  every size from 25 to 35 (0.105 at 35). Below 6, the matched sample
  selects nothing.
  - **Which branch:** B when `both_wrong` makes up at least two-thirds of the
    bad calls, and C when `both_defensible` does.
  - **Short of two-thirds:** build B first and then C, since both are
    evidenced. B goes first because a wrong key grades the engineer wrong,
    while an ambiguous one is at worst arguable.
- **Why 10% is the line:** matched sections are most of all sections. With
  10% of them bad, they hold more bad keys than the whole mismatch pool at a
  10% mismatch rate, and the mismatch count cannot see any of them.
- **When both samples select:** only a branch the combined sample selects
  takes precedence over the mismatch branch. Build both fixes, the matched
  one first when they differ, because only it fixes sections the judge
  can't catch.
- **What branch D can't fix:** flipping
  `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` does nothing for a matched bad
  key, because the judge agreed with it. Branch D is never the response to
  a matched-sample result.
- **Cost:** reading time, not money. Those 6–8 observations are the
  difference between rewriting a generation prompt on solid ground and
  rewriting it on 3.
- **Is the pool big enough?** At a 10% mismatch rate, 44 replayed sections
  leave about 40 matched records. After a first draw of 15, about 25
  remain for the second. If fewer remain, call what's there. A combined
  sample under 25 can't select a branch, so live solves fill the gap.

### The branches

- **A. Mostly `key_right` among mismatches: the judge is the problem.**
  - Fix the judge's prompt for the error pattern the `judge_right`
    notes and the `key_right` mismatches show.
  - If the pattern is "the model can't do this", change the judge's model
    for `judge_section` instead, on Claude first.
  - Re-run the replay with the fixed judge. That re-run is the acceptance
    check: agreement on the A-called sections must reach at least 10 of 12
    (or the same Wilson bar).
  - Then set `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL = true`.
- **B. Mostly `judge_right`: generation is the problem.** The key, or the
  text that produces it, is wrong.
  - Read the `judge_right` cases for which way they fail.
    - **The better piece is wrong but `deciding_fact` argues for the other
      one:** first rule out `.arrange!`. It rolls `better` server-side and
      swaps the pieces to match. It reads correctly today, but it's cheap
      to verify against the cases. If it holds, the provider put the wrong
      code under `better_piece`, so fix the generation prompt's
      `better_piece` and `other_piece` instructions.
    - **`deciding_fact` names a fact that doesn't decide:** fix the
      generation prompt's instructions for `better_piece` and
      `deciding_fact`.
  - Then make the judge a hard gate: set the flag to `true`.
- **C. Mostly `both_defensible`: the scenarios aren't decisive.**
  - Tighten the generation rules for what makes a scenario decisive. The
    design comparison's generation guidance must require one stated fact
    that rules the other piece out, and the judge's `underdetermined`
    check gets the same wording.
  - Re-run synthetic generation and confirm `both_defensible` drops below a
    third of called mismatches.
- **D. No mismatch call clears the bar by 30 and the matched sample
  selects nothing.** Set the flag to `true` and nothing else. A hard gate is the one change that helps in every case:
  - a wrong key gets regenerated
  - an ambiguous section gets regenerated
  - a wrong judge costs one retry on a good section

  `judge_retries` already limits that cost.

Each branch keeps recording live solves after it lands, and the same counts
show whether the mismatch rate falls.

## The admin page

The page lives at `GET /admin/judge_solves` (`Admin::JudgeSolvesController#index`).
Saving a verdict is `PATCH /admin/judge_solves/:id`, which writes only
`human_call` and `human_note`. Both inherit `Admin::BaseController`. The
page is plain HTML and the form is a normal `form_with` post, so no
Stimulus controller is needed.

**Filters,** as query params:
- `source`: `live` (the default), `real` (live plus replay, the set the
  decision rule counts), `replay`, `synthetic` or `all`. Live is the
  default because only live solves are evidence about what shipped.
- `show`: `mismatches` (the default), `reverts`, `matched_sample` or `all`.
  `all` adds matched and unsolved records.
  - `matched_sample` serves `n` (default 15) random matched records with no
    `human_call`, drawn from the source filter (synthetic is never drawn,
    even under `all`), solved and not at principal_engineer.
  - It is seeded per page load, so a reload can serve a different draw;
    called records leave the pool either way.
  - The spoiler rule still applies: a shipped record whose day isn't
    reviewed is never drawn.
- `call`: `uncalled`, `key_right`, `judge_right`, `both_wrong` or
  `both_defensible`.

**Header:** plain counts, no computed bound or branch. You apply the
decision rule from these yourself.
- solved, matched, mismatched and unsolved, by source
- edits reverted, by reason and by source
- **mismatch calls:** a table of `human_call` by source (live, replay,
  synthetic), counted under the decision rule's counting rules: deduplicated
  by section version, with unsolved and principal-engineer records left out
- **matched calls:** the same table for matched records, kept apart from
  the mismatch table

**Order:** reverted edits first, then mismatches, newest first within each.

**Each entry shows:**
- **Metadata:** date, user id, source, rung (and locked), concept, attempt
  and edit check, shipped or not, judge status, judge provider and model,
  draft model, revision.
- **The problem:** title, scenario and question.
- **The pieces:** piece A and piece B, highlighted with `CodeHighlight`, in
  the order the judge saw them.
- **The key and the pick:** the key's better piece, `deciding_fact`,
  `principle` and `why_other_fails`, then the judge's pick.
- **For a reverted edit:** the shipped original's title, scenario and
  question beside the edited ones, with the revert reason.
- **For a live record:** a link to any replay record of the same section,
  and the reverse, so you can compare today's judge with the one at the
  time.
- **The verdict form:** `human_call`, offering the three values that fit
  whether the record matched, and the `human_note` box.

**Spoiler rule, held by a request spec.** A shipped record's key and pick
are rendered only once that exercise's `DailyResponse` is reviewed. Before
that, the entry shows as "waiting for the engineer's review", with no
pieces, key, pick or form. This applies to replay records too, since a
replay judges a shipped section. A record that never shipped (a rejected
draft, a dropped retry, a reverted edit's edited text) shows at once. The
admin is also a user, and the answer-key rule forbids showing a key on a
page before review.

**Links.** The suggested-concepts page links to this page. Copy goes under
`admin.judge_solves` in `config/locales/en.yml`.

## Out of scope

- **Stage 1** leaves `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL`,
  `SOLVE_MISMATCH_TOLERATED_AT`, the judge prompt, the draft prompt and
  `JudgeVerdict` unchanged. Stage 2 changes whichever the decision rule
  selects, and nothing else.
- **The edit-check revert keeps its current behavior** in both stages.
  Stage 1 records it and changes nothing about it.
- No persistent systems or canon.

## Tests

- **`judged_generation_spec`.** One `Solve` per pass for each of:
  - a matched draft
  - a mismatched draft
  - an edit check that matches (no revert)
  - an edit check that mismatches (`edit_reverted`, `solve_mismatch`)
  - an edit check the judge rejects (`judge_rejected`)
  - an edit check where the judge fails (`judge_failed`)
  - a rejected draft then a kept retry (both recorded, only the retry
    `shipped`)
  - a judge failure on the draft (pick nil, matched nil, reason set)

  Kinds without `judge_solve_options` produce none. `outcomes` still carry
  only booleans, and the revert behavior is unchanged.
- **`generation_diagnostics_spec`.** The logged payload carries no pick, no
  `answer_key` field and no `solves` key.
- **Job specs (generate and regenerate).**
  - Records are written with the row, all `source: "live"`.
  - A regeneration adds a new `set_generated_at` group and keeps the old
    one.
  - An unjudged weekend writes none.
- **Model spec for `JudgeSolve`.**
  - `record!`
  - the `human_call` values: the mismatch set on a mismatch, the matched
    set (with `both_wrong`) on a matched record, nothing on an unsolved one
  - `revert_reason` is present exactly when `edit_reverted` is
  - `section_digest` is computed on write, is equal for two key orders of
    the same section, and differs when any field differs
- **Replay script spec,** driven with a lambda judge:
  - the dry run makes no call and writes nothing
  - selection skips dropped and malformed sections
  - a second run skips what's done, keyed on the digest, with
    `app_revision` null; `--rejudge` re-judges
  - `--run` without `ANTHROPIC_API_KEY` aborts before any call
  - a failed call becomes an unsolved record
  - `--synthesize` writes `synthetic` records with no user or exercise, and
    the check constraint refuses a `live` record without them
- **Judge failure fix:**
  - `openai_service_spec`: a request with a `response_schema` carries the
    schema text after the JSON-mode line; one without it doesn't change.
  - Re-record the OpenAI request snapshots for schema'd purposes with
    `UPDATE_PROMPT_SNAPSHOTS=1`. That's the intended deliverable, and no
    other snapshot moves.
  - `judged_generation_spec`: the fallback log line and `unsolved_detail`
    carry the `JudgeVerdict::Invalid` message.
  - `judge_verdict_spec`: no `Invalid` message includes the submitted
    `better` value, for each refusal path.
- **Header counts:** a spec for the query that builds the call tables. It
  covers:
  - deduplication by `section_digest`, in SQL
  - unsolved and principal-engineer records left out
  - mismatch and matched calls counted apart
  - every count split by source
- **Request spec for the page:**
  - a non-admin is redirected on both actions
  - an unreviewed shipped record hides its key, pick and form, for both
    sources
  - a reviewed one shows them
  - a never-shipped one shows at once
  - each filter works
  - `matched_sample` serves only uncalled, solved, matched records, from
    live and replay only, never past `n`, and never an unreviewed shipped
    record
  - `PATCH` saves `human_call` and `human_note`, refuses any other value,
    and ignores any other column

## Docs to update in the same PR

- `docs/decisions/design-comparison-the-second-fixed-section.md`: blind
  solves and edit reverts are now kept, the replay exists, and how to read
  both.
- Its `.claude/rules/generation.md` entry: one clause saying solves persist
  to `judge_solves` and never ride `outcomes`.
- `.claude/rules/models.md`: a `JudgeSolve` row.
- `docs/file-map.md`: the model, controller, view and script.

## What is recoverable from the past

**No past mismatch can be recovered.**

- **Rows:** nothing. `solve_matched` has never been written to the
  database, and the judge's pick has never been stored anywhere.
- **Logs:** Railway's production logs only reach back to about 2026-10-15.
  Queries before that return nothing on both `web` and `worker`. In that
  window:
  - `[judge_solve_mismatch]` appears zero times.
  - Seven weekday design comparisons were judged (the worker's
    `[difficulty_diagnostics]`, 2026-10-16 to 2026-10-21; `web` logged no
    generation in the window). Five matched the key. Two got no solve
    because the judge returned `invalid_output`. None reverted an edit.
  - Those logs never carried the key or the pick.
- **Earlier mismatches and reverts** from 2026-10-01 to 2026-10-14 were
  logged and are now gone.

The replay fills that gap for the question "are the keys right?". It can't
show what the judge at the time picked. That evidence, live solves, starts
when stage 1 merges. At about seven judged design comparisons a week, even a 10%
mismatch rate yields about one live disagreement a week.

## Size

- one migration, one model, one `Data` value
- about 50 lines in `JudgedGeneration`
- a field on `JudgedSet` and a few lines in each job
- a public model-route reader
- one controller with two actions and one view
- one script, with replay and synthesize modes
- a `judge_shape` mode for `script/compare_models.rb`
- the `OpenaiService` schema line and the `#fallback_detail` change
- a small query object for the header's call tables
- the specs

Stage 1 is roughly 750–900 lines with tests. The header's counting lives
in its own query object, so no controller method passes 25 lines. The only prompt
snapshots that change are the OpenAI request snapshots for schema'd
purposes.

**Money spent, by when:**

| Step | Cost |
|---|---|
| Before stage 1 merges: OpenAI schema acceptance, 28 calls, reasoning capped at 4,000 | 0.064M input tokens × the input price + 0.06M output tokens × the output price (expected); 0.146M output tokens × the output price (worst case); three times both if the first pass is ambiguous. `gpt-6-astra`'s prices are unverified |
| Before stage 1 merges: Claude and Gemini acceptance, 28 calls | under $1 |
| After the merge: replay, Claude judge | about $0.85 to $4.20; run the SQL count first |
| After the merge: synthetic top-up, decided after the replay; corroboration only | about $15 for 120 sections, or $0 if skipped |
| After the merge: hand calls | your time: the replay's mismatches, 10–15 matched records, and 15–20 more if the first draw shows 3 or more bad |

Stage 2 is a separate PR, and its size depends on the branch. D is a one-line flag change plus its
spec. A, B and C are each a prompt or `.arrange!` change, then a replay
re-run as acceptance.

# script/design_comparison_replay.rb

`DesignComparisonReplay` asks today's judge to solve stored design comparisons
blind and writes one `source: "replay"` row in `judge_solves` for each. The
design is in `docs/answer-key-trust-spec-2026-10-22.md` ("Replay" and "Topping
up with generated sections") and step 8 of
`docs/answer-key-trust-stage1-plan-2026-10-22.md`. The entry point is
`script/replay_design_comparison_solves.rb`, the same split as
`script/compare_models.rb` and `ModelComparison`.

## What it prints

Counts, dates, user ids, exercise ids, rungs, concept names and unsolved
reasons. It never prints a solve, a pick, a key, `deciding_fact`, any section
text or a provider error's message, so its output can be pasted anywhere.

A progress line says only `recorded` or `unsolved (<reason>)`, never match or
mismatch, and the summary gives no agreement count either. The person running
it may have today's design comparison still unanswered, and "mismatch" next to
that exercise's id says something about its key. The admin page computes
agreement over `JudgeSolve.readable` only, so that is where to read it.

## Selection

`#candidates` is the spec's SQL: a `design_comparison` whose
`answer_key.better` is `a` or `b`, with non-empty `piece_a` and `piece_b`, and
whose `dropped_sections` doesn't name the kind. It also requires a
`pitched_at` that is one of `KindDifficulty::LEVELS`, since the judge is told
that rung and `judge_solves.rung` is not null. Every stored design comparison
should carry one (ingest has stamped it since before the kind existed), so a
section without one is malformed and skipped.

## The skip

A section is skipped when a `replay` row already exists for the same
`(daily_exercise_id, section, section_digest)`. The digest is computed with
`SectionDigest` from the stored section, the same function `JudgeSolve`
stamps on save, so an interrupted run resumes without paying twice, and a
section that changed since its replay is judged again. It does not key on
`app_revision`, which is expected to be null for now, and a live row never
counts as replayed. `--rejudge` turns the skip off.

## Building each record

The script builds its `Solve` through `JudgedGeneration::SolveChain`, the
same code the live flow uses: one `record` at attempt 0, then `settle(0)`.
That gives `edit_check: false`, `edit_reverted: false`, `shipped: true` and no
`never_shown_reason`, which is exactly a replay record, and keeps one place
that maps a verdict onto the `Solve` fields. `locked` is always false, since
the flag was never stored, and `draft_model` is nil, since nothing recorded
it. `judge_provider` and `judge_model` come from the service's own
`provider_key` and `model_for("judge_section")`.

Each record takes the exercise's current `generated_at` as its
`set_generated_at`, through `JudgeSolve.record!`. `JudgeSolve.readable`
matches a review to the set it answered, so a replay record becomes readable
only once that set's design comparison has its review.

## Which failures are recorded and which stop the run

A failure that belongs to the reply itself becomes an unsolved record: the
`AiService.judge_fallback_reason` codes `invalid_output`, `refusal`,
`truncated` and `invalid_json` (`OWN_FAILURES`). Judging the same section
again would likely fail the same way, so the record is the honest result,
and it counts toward "N mismatches out of M" the way a live failure does.
Only a `JudgeVerdict::Invalid` message is kept as `unsolved_detail`, cut to
`JudgedGeneration::REFUSAL_DETAIL_LIMIT`, the same rule as the live flow,
because a provider error body can echo content.

Every other failure says nothing about the section: a rejected key, an
account out of credit, a rate limit, a timeout, a 5xx, a dropped database
connection, any of `AiService::INFRASTRUCTURE_ERRORS`, or a `SetupError`.
Recording one would mark the section as replayed, and the skip would never
judge it again. So the run stops at once, writes no row for that section, and
prints the exercise id, the reason code and how many were recorded before it.
A re-run starts with that section. A `JudgeSolve::RecordError` stops the run
the same way, printing only its scrubbed message.

## Synthetic sections

`--synthesize N --user ID` brings the synthetic records up to N. Without
`--run` it is a dry run like the replay's: it prints how many sections are
left to draft, how many go to each rung, and the worst-case bound, and makes
no call. With `--run` it drafts each fresh section through `retry_section`
with the concept fixed, as `ModelComparison#judge_concept` does, using
`ForcedConceptDrafts.rung_draft` to pitch it at its rung.

Slot `i` goes to rung `i mod 4` and takes the next concept in that rung's
`ConceptVocabulary.selectable_for_section` list, so the spread is even and the
principal rung also draws its tradeoff concepts. The plan starts at the count
of synthetic rows already written, so a run that stopped continues with the
next slot instead of starting over. A slot whose draft ingest refused wrote no
row, so later slots shift by one; the spread stays even to within one
section.

The user supplies only the plan, language and time zone the prompt is built
from. Planning and drafting both run inside
`Time.use_zone(user.effective_time_zone)`, as `#judge_concept` does, so the
draft is built for the user's own date, not the runner's. The rows carry no
user or exercise (`JudgeSolve.record_synthetic!`), `draft_model` is the
`retry_section` route, and `shipped` is false, since nothing was delivered to
anyone. A draft the reply's own fault spoiled, or one ingest refused, records
nothing and the run carries on; any other draft failure stops it as above.

## The service

`#claude_service` builds a `ClaudeService` subclass from `ANTHROPIC_API_KEY`,
never a user's stored key, and raises `MissingKey` before any call when it is
blank. Like `ModelComparison#pinned_service`, it writes no `ApiUsage` rows and
collects token counts for the summary instead, so a teammate's usage history
isn't charged for a run they never made. It records no suggested concepts
either. It keeps the production routes, so every replay record comes from the
production judge. The billing spec drives `--run` through the real
connection with only the adapter swapped, and checks the `x-api-key` header.

Its subclass repeats a few lines of `ModelComparison#pinned_service`. A
shared class is a follow-up once the sibling change to `#pinned_service`
lands, since extracting it now would conflict with that change.

## Cost bounds

Each printed figure is a worst-case bound, worked out per call by
`.worst_case_cost` from `ClaudeService::PRICE_PER_MILLION` for the
model the purpose routes to, an input estimate, and the call's full output
cap. The output cap is the purpose's `max_tokens` in `CallProfiles`,
or `ClaudeService::MAX_TOKENS` when the profile sets none. The printed line
names each call's model, input estimate and cap.

- **Judge call:** 3,500 input tokens (`JUDGE_INPUT_TOKENS`, the top of the
  spec's 3,000–3,500 estimate) and `JUDGE_MAX_TOKENS` (2,000) out on
  `claude-sonnet-5-5`: $0.027.
- **Synthetic section:** one draft plus one judge call. `retry_section` has no
  token cap, so the draft is bounded by `ClaudeService::MAX_TOKENS` (16,000)
  out on `claude-opus-5-5`, plus 10,000 input tokens (`DRAFT_INPUT_TOKENS`).
  The rendered retry prompts in `spec/fixtures/prompt_snapshots/case__retry__*`
  are 18–20k characters, and the generation system prompt adds under 1k, which
  is about 6k tokens; 10,000 leaves room for a real engineer's history. That
  gives $0.36 for the draft and $0.387 per section, against the spec's
  earlier $0.12, which left out the draft's full output cap.

The script adds no token cap to the production profile; the bound is
deliberately pessimistic instead.

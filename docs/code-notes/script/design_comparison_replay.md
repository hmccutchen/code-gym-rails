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

A judge failure becomes an unsolved record with
`AiService.judge_fallback_reason` as its reason. Only a
`JudgeVerdict::Invalid` message is kept as `unsolved_detail`, cut to
`JudgedGeneration::REFUSAL_DETAIL_LIMIT`, the same rule as the live flow,
because a provider error body can echo content.

Each record takes the exercise's current `generated_at` as its
`set_generated_at`, through `JudgeSolve.record!`. `JudgeSolve.readable`
matches a review to the set it answered, so a replay record becomes readable
only once that set's design comparison has its review.

## Synthetic sections

`--synthesize N --user ID` drafts N fresh sections through `retry_section`
with the concept fixed, as `ModelComparison#judge_concept` does, using
`ForcedConceptDrafts.rung_draft` to pitch each one at its rung. Section `i`
goes to rung `i mod 4` and takes the next concept in that rung's
`ConceptVocabulary.selectable_for_section` list, so the spread is even and
the principal rung also draws its tradeoff concepts. The user only supplies
the plan and language the prompt is built from. The rows carry no user or
exercise (`JudgeSolve.record_synthetic!`), `draft_model` is the
`retry_section` route, and `shipped` is false, since nothing was delivered to
anyone. A draft that ingest refuses, or a draft call that fails, records
nothing.

## The service

`#claude_service` builds a `ClaudeService` subclass from `ANTHROPIC_API_KEY`,
never a user's stored key, and raises `MissingKey` before any call when it is
blank. Like `ModelComparison#pinned_service`, it writes no `ApiUsage` rows and
collects token counts for the summary instead, so a teammate's usage history
isn't charged for a run they never made. It keeps the production routes, so
every replay record comes from the production judge.

## Cost bounds

`JUDGE_CALL_COST_BOUND` and `SYNTHETIC_SECTION_COST_BOUND` are the spec's
worst-case figures per judge call and per synthetic section. The dry run
multiplies the pending count by the first, and `--synthesize` prints N times
the second before it starts.

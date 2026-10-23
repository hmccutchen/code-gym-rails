# script/model_comparison.rb

## `ModelComparison`

The script writes no `ApiUsage` rows. A row would charge a teammate's usage history for a comparison they never ran.

## `CANDIDATES`

The `review_calibration` candidate is the production grading route, so a run measures the rubric as deployed.

## `LIST_PRICE_PER_MILLION`

These are list prices for comparing candidates. Nothing that bills reads them.

## `ProseResult`

A result is kept whole, failures included, so a model's summary counts every input and all of its waiting time.

## `#judge`

When one section fails, its error is printed in its place, so a single bad section never loses the rest of a candidate's output.

## `#judge_fixtures`

It takes no `user_id`: each fixture carries its own rung and lock, and the fixture user is never persisted.

## `#review_prose`

When the live judge already edited a stored review, the comparison starts from the grader's original prose under `graded_prose`.

## `#judge_concept`

Drafts are planned in the user's own time zone, the way `GenerateDailyExercisesJob` plans them.

## `#concept_judgment`

The judge sees each draft as locked, as the draft was, so it measures against exactly the rung the draft was written to.

## `#fixture_row`

A provider failure becomes an error row. One timeout neither ends the run nor counts as invalid output.

## `JUDGE_SHAPE_PROVIDERS`

OpenAI's judge route runs with a 4,000-token reasoning allowance here, in place of production's 25,000. The run checks whether replies carry the verdict's shape, and a lower cap keeps 14 calls cheap while a reply that hits it still shows up as `truncated`. The other providers run their production route unchanged. The reasoning is in `docs/answer-key-trust-spec-2026-10-22.md`, under "Acceptance before stage 1 merges".

## `#judge_shape`

It prints counts and `JudgeVerdict::Invalid` messages only. That class's messages name a missing or unknown value and never the pick, and other errors print as their class name, since a provider's message can quote the reply.

## `#pinned_service`

The pinned service answers `judges_review_prose?` with false, so a run measures the grader alone whatever the deployment's `REVIEW_PROSE_JUDGE` switch says.

## `#judge_prose_input`

Time and tokens are recorded on failure too, so a model that keeps timing out cannot look fast.

## `#print_prose_result`

It prints review text on purpose. A person reads it in a terminal, and it never reaches application logs.

## `#print_prose_extremes`

The review prose judge's activation gate checks single replies against `REVIEW_JUDGE_MAX_TOKENS` and `REVIEW_JUDGE_READ_TIMEOUT`, and totals hide the worst single reply, so this prints the largest and slowest.

## `#calibration_row`

Each answer is `[label, expected ratings, run]`. The first three are the quality ladder, in order.

## `#review_heading`

A real review translates pseudocode before grading. This script writes nothing, so an untranslated plan is graded as written, and the heading says so.

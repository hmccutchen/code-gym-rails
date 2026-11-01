# app/models/call_profiles.rb

## Why a module of its own

A purpose's call settings and the timing built from them are the same for
every provider, so they live here rather than on `AiService` (#447). A model,
view or job that needs a worst-case call time reads this module and never
names a provider class: `DailyExercise::REGENERATION_DEADLINE`, the
dashboard's generation poll, Learn's write-up poll and the generation jobs'
concurrency durations all do. `AiService.request_for` builds each request from
`BY_PURPOSE`, and each provider's Faraday connection and `RETRY_OPTIONS` take
their timeouts and retry counts from here. `AiProvider` keeps only facts that
do vary by provider, such as a provider's own quota day.

## `OPEN_TIMEOUT`

The longest `#review` chain must stay under
`DailyResponse::REVIEW_CLAIM_STALE_AFTER`, and `ai_service_spec` asserts it.

## `GENERATION_READ_TIMEOUT` and `SYNC_GENERATION_READ_TIMEOUT`

Generation runs on the worker and can wait. `SYNC_GENERATION_READ_TIMEOUT` has
no caller today, but it bounds any future synchronous caller and the
one-section retries.

## `CONCEPT_REFERENCE_READ_TIMEOUT`

Set above `READ_TIMEOUT` so the call counts as long-running, which makes a
timeout final instead of retried into duplicate spend.

## `REVIEW_READ_TIMEOUT`

The slowest measured grades took about 80 seconds. Being above `READ_TIMEOUT`
also makes a timeout final instead of retried and billed again.

## `RETRY_MAX` and its neighbours

Every provider's `RETRY_OPTIONS` share this policy, so the timeout budgets read
one number.

## `.call_budget_seconds`

A poller must pass the same read timeout as the call it waits on, or it waits
too little.

## `.worst_case_call_seconds`

Counts every attempt even when the read timeout is final, since a 429 or a 5xx
still retries.

## `DUCK_RESPONSE_MAX_TOKENS`

A budget, not an enforcement mechanism. It is one ceiling for every reply,
since a reply type the client declares can't be trusted.

## `CONCEPT_ALTERNATE_MAX_TOKENS`

Free prose has no largest valid reply to derive a cap from. Passing any
`max_tokens` also turns extended thinking off.

## `PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS`

The critique cap is derived from the largest valid critique, because a flat cap
truncated the longest valid replies mid-JSON.

## `DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS`

Both margins in the difficulty cap are chosen, not measured. A cap that is too
tight loses the note silently.

## `JUDGE_MEASURED_MAX_OUTPUT_TOKENS`

The largest finished section-judge reply measured in production, in output
tokens: 654, from `claude-sonnet-5-5`, over 47 `judge_section` usage rows from
2026-10-05 to 2026-10-30 (39 Sonnet, 8 OpenAI, whose largest was 163), none of
them truncated (#639). `ai_service_spec` asserts `JUDGE_MAX_TOKENS` holds three
times it. A later measurement past a third of the cap needs a decision about
the cap, not just a new number here.

## `JUDGE_MAX_TOKENS`

Raised from 1,200 to 2,000 after one reply in the first `code_review` triage
run (2026-10-30) passed 1,200 and fell back as `truncated`, so its section
would have shipped unjudged (#639). An `edit` verdict writes back every prose
field it rewrites, so the reply grows with the section's prose, not its rung,
and one cap serves every rung. Three times the measured largest reply, rather
than the review judge's four, keeps a full reply near 33 seconds at Sonnet's
speed, inside `READ_TIMEOUT`, so the judge's worst-case call time and the
regeneration deadline that reserves it stay as they were. The judge is billed
only for the tokens it writes, so the room costs nothing until a reply uses
it. Passing the cap turns thinking off.

## `REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS`

The largest prose-judge reply measured, in output tokens. `ai_service_spec`
asserts `REVIEW_JUDGE_MAX_TOKENS`' headroom over it. A later run that measures
more than a quarter of the cap needs a decision about the cap, not just a new
number here.

## `REVIEW_JUDGE_MAX_TOKENS`

Review output is unbounded, so a long review can still fall back as
`truncated`. Passing this cap turns thinking off.

## `BY_PURPOSE`

A purpose's token cap, read timeout, caching, single attempt and allowed
truncation are facts about the purpose, so they live in one row per purpose
instead of at each call site. The values are the named constants above, so
the timeout budget specs and the notes on each constant still apply.
`ai_service_request_spec` holds the keys equal to `ApiUsage::PURPOSES`.
`provider_request_characterization_spec` fails if a row changes the body its
purpose sends to any provider, which covers the token cap and caching. The
read timeout, single attempt and allowed truncation appear in no body, so
`ai_service_request_spec` pins them, by driving each purpose's real caller and
comparing the request it sends with the settings its call site passed before
the profiles existed.

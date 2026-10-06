# Provider limits, informative errors and trial mode: investigation and design, 2026-10-06

Sections 1, 2 and 4 describe what the first PR of the stack built, and say
so where the build departed from the design; sections 3 and 5 to 8 remain
the design for the PRs that follow. The investigation branch added:

- `spec/requests/provider_failure_characterization_spec.rb`: 49 passing
  examples that drive every provider-calling path against a stubbed Gemini
  answering a daily-quota 429, a per-minute 429, an invalid key (400), a
  revoked key (403), an outage (503) and a timeout. They pin what the app
  shows today, including the parts the work below changes.
- `spec/fixtures/provider_errors/`: the stubbed bodies. They follow Google's
  documented `generateContent` error shape. **Pending replacement:** the
  Interactions API's real 429 is unconfirmed until the probe (section 3)
  records one, and the fixtures are to be replaced with what it captures.
  The `quotaId` strings are what `ProviderFailure` keys on (`PerDay`), so
  the capture decides whether that pattern holds.

How it was checked: code reading with every claim cited to a file, the
characterization specs run locally against PostgreSQL 16, the security audit
of 2026-10-05 for the open rate-limit and signup findings, and the Anthropic
error reference for the Claude side. Google's rate-limit page
(`ai.google.dev/gemini-api/docs/rate-limits`) could not be fetched from this
environment, so every Gemini free-tier number below is a value to read off
that page or measure with the probe, not a fact this document asserts.

What the audit already landed: `ProviderCallLimits` (60/hour, 300/day per
user across the duck, follow-ups, both explain-differently routes and the
pseudocode critique), `/generate` at 3/hour, Learn prepares at 10/hour, one
generation job per user at a time, `raise_if_key_rejected` on every provider
(401/403 fixed message, body never logged), and the anchored `code` filter.
This document builds on those.

---

## 1. What users saw before this work, by path and failure

Observed with the characterization spec as it was on the investigation
branch. The spec is now the target (section 4.4), and every row below is
what the first PR replaced. "Requests" is how many HTTP attempts
one call made: `faraday-retry` retries 429 and 5xx twice with 0.5 to 8 second
backoff, and refuses to retry at all when the reply carries a `Retry-After`
longer than 8 seconds (`faraday-retry` 2.4.0, `calculate_sleep_amount`
returns nil past `max_interval`). A read timeout on generation is final; on
short calls it retries.

### 1.1 Generation (nightly batch, on-demand, "Try again", regeneration)

`GenerateDailyExercisesJob#generate_for` rescues by class and writes
`users.last_generation_error`; the dashboard renders it under "Couldn't
generate today's exercises." with a Try again button, and `/dashboard/status`
returns it as `{"status":"failed","message":…}`. Regeneration takes the same
rescues and prefixes "Couldn't generate a new set: ". Nothing is lost: no row
is written on failure, and the Try again button re-enqueues.

| Failure | Requests | Text shown | Verdict |
|---|---|---|---|
| Daily-quota 429 (`Retry-After: 3600`) | 1 | "The AI provider is rate-limiting requests — try again shortly." | Wrong advice: "shortly" for a limit that resets at midnight Pacific |
| Per-minute 429 (no header) | 3 | same | Right advice, no time |
| Invalid key, Gemini 400 `API_KEY_INVALID` | 1 | "API key not valid. Please pass a valid API key." | Raw Google text; read as a generic error, not a key problem, so no pointer to Settings |
| Revoked key 403 | 1 | "Your API key was rejected — check it in Settings." | Fine |
| Outage 503 (HTML body) | 3 | "Gemini API error 503" | A status code as a sentence |
| Timeout | 1 | "Generation took longer than the provider's budget — try again." | Fine |

The judge (`JudgedGeneration`) never fails the day: a 429 on `judge_section`
ships the unedited draft and records `fallback: "rate_limit"` on the outcome
(pinned). A 429 on a retry generation drops the section
(`[judge_retry_failed]`, code reading). Neither tells the user anything beyond
"one section was left out".

### 1.2 Review (grading, difficulty check, pseudocode translation)

`ResponsesController#review` fans out one grading call per section plus one
difficulty call. `grade_section` rescues `AiService::Error` per section and
stores `{code, message}` in `daily_responses.review_errors`, which no view
renders. The controller flashes `zero_success_alert` when every section
failed, or `review_partial` when some did. Answers and the submission are kept
and the review button stays, so a retry is one click. The difficulty check is
swallowed (`safe_difficulty_assessment`), and the review goes out without its
note; pseudocode translation likewise.

| Failure | Flash |
|---|---|
| Daily or per-minute 429 | "The AI provider is rate-limiting requests — try again shortly." |
| Invalid key 400 | "Couldn't generate the review: API key not valid. Please pass a valid API key." (raw provider text) |
| Revoked key 403 | "Your API key was rejected — check it in Settings." |
| Outage 503 | "Couldn't generate the review: Gemini API error 503" |
| Timeout | "Couldn't generate the review: Network error calling Gemini: Net::ReadTimeout with #<TCPSocket:(closed)>" (socket detail) |

### 1.3 Duck, follow-ups, explain differently (review and concept), pseudocode critique

All five rescue `AiService::Error` and render `{status: "error", error:
e.message}` with HTTP 503; each page's script shows `e.message` in its status
line. The duck leaves the typed message in the box and the follow-up leaves
its question, so both can be resent without retyping; the critique releases
its round claim. Nothing is stored.

| Failure | JSON `error` |
|---|---|
| Daily or per-minute 429 | Google's own sentence: "You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits." |
| Invalid key 400 | "API key not valid. Please pass a valid API key." |
| Revoked key 403 | "Google rejected your API key or its permissions. Check it in Settings." |
| Outage 503 | "Gemini API error 503" |
| Timeout | "Network error calling Gemini: Net::ReadTimeout with #<TCPSocket:(closed)>" |

### 1.4 Learn references, ladders, the backfill

`GenerateConceptReferenceJob` and `GenerateRecognitionGuideJob` rescue every
`AiService::Error`, log a warning and write nothing. The concept page polls
`/learn/:bucket/:concept/status` for the call budget and then says "Still
working on it. Reload this page in a minute to check." The ladder rewrite
leaves the shared row unchanged (`generation_version` stays). The "Write up
the rest" backfill redirects with "Writing them up now — they'll appear as
each one finishes." and nothing appears. No failure reaches the page, so a
user on a spent quota reloads indefinitely.

### 1.5 Drills

`ConceptDrillsController` and `ConceptDrills` make no provider call. A drill
only orders tomorrow's reinforcement list. Nothing to classify.

### 1.6 Two cross-cutting facts

- No usage row is written for a failed call: every provider raises inside
  `#call`, and `call_and_log` reaches `log_usage` only on a 2xx
  (`ai_service.rb:3214-3232`; pinned by `ApiUsage.count == 0` in the spec).
  The 429s that matter most for capacity planning leave no trace but a log
  line.
- Gemini reports an invalid key as HTTP 400 with `error.details[].reason ==
  "API_KEY_INVALID"`, not 401 or 403. `raise_if_key_rejected` checks only
  401 and 403, so a mistyped Gemini key is a generic `AiService::Error`
  whose message is Google's text. The probe should confirm the Interactions
  API does the same; the fixture encodes the `generateContent` behavior.

### 1.7 Comparison with the real 429

Pending. Section 3's probe writes the real body and headers to
`tmp/gemini_probe/`; the fixtures in `spec/fixtures/provider_errors/` are then
replaced and the characterization spec re-run. Two things to look for: whether
the Interactions API sends `Retry-After` at all (which decides whether
`faraday-retry` retries a 429 three times or once), and the exact `quotaId`
strings, which section 4's classifier keys on.

---

## 2. The usage record

### 2.1 Today

`api_usages`: `user_id`, `date` (the user's local day, from `Date.current`
inside the caller's zone), `purpose` (closed list `ApiUsage::PURPOSES`),
`tokens_in`, `tokens_out`, `model`, `cache_read_tokens`,
`cache_write_tokens`, timestamps. Index on `[user_id, date]`. One row per
successful provider call, written by `AiService#log_usage`, which rescues
database errors so a usage write can never fail a call. Rows before
2026-10-01 have null `model` and cache counts.

Issue #237 ("ApiUsage does not record which model ran") is already closed by
PR #242, which added `model` and the cache columns. What this work adds on
top is the provider column the issue left as optional, the HTTP status, and
rows for failed calls.

### 2.2 What was built

One migration, `AddOutcomeToApiUsages` (flagged):

| Column | Type | Meaning |
|---|---|---|
| `provider` | string, null | `anthropic` / `gemini` / `openai` / `fake`, the provider class that wrote the row; backfilled from `model` in the same migration, since every model name identifies its provider, and left null where `model` is null |
| `http_status` | integer, null | the reply's status; null for a reply that never arrived |
| `failure` | string, null | null when the reply was used; otherwise one of `ApiUsage::FAILURES`: `rate_limit`, `authentication`, `out_of_credit`, `timeout`, `network`, `refusal`, `truncated`, `invalid_response`, `provider_error` |
| `quota_id` | string, null | the limit a 429 named, in the provider's vocabulary: Gemini's `QuotaFailure.violations[].quotaId`; on Claude the first `anthropic-ratelimit-{requests,input-tokens,output-tokens,tokens}-remaining` header reading zero, as `anthropic-ratelimit-<family>`, else the error type; on OpenAI the first `x-ratelimit-remaining-{requests,tokens}` reading zero, else the error code |
| `house_key` | boolean, default false, null false | the call was billed to a house key (section 6); nothing sets it yet |

Index added: `[provider, house_key, created_at]`, for the global guard's
count.

Rows for failures carry zero tokens. `call_and_log` writes them: it rescues
`AiService::Error` around `call`, builds a result from the error's
`http_status`, `quota_id` and class (`AiService.failure_code_for`) and the
routed model, writes it through the same `#log_usage`, which never raises,
and re-raises the same error. The providers put `quota_id` and
`retry_after` on the `RateLimitError` they already build, reading the 429
body's `details` on Gemini (`QuotaFailure` and `RetryInfo`) and the
rate-limit headers on Anthropic and OpenAI, none of it logged. A refusal or
truncation is marked on the row that carries its tokens. One row per
`call`, not per HTTP attempt: `faraday-retry`'s retries stay inside the
adapter, and the probe measures per attempt by turning retries off. Two
departures from the design: `provider_error` names a non-2xx reply with no
narrower class, and `out_of_credit` was added for section 4.1.

The queries the caps and the trial screen need, as built:

```ruby
# app/models/api_usage.rb
ApiUsage.requests_on(user, day, provider:)               # the user's local day, attempts included
ApiUsage.house_requests_between(provider:, from:, to:)   # created_at inside a window the caller sets
```

The second counts by `created_at` because Google's daily quota resets at
midnight Pacific, which is not any user's `date`; trial mode hands it the
quota day's bounds from `ResetClock`.

Usage dating: `GenerateRecognitionGuideJob` wraps its call in the user's zone
so `date` is their day; `GenerateConceptReferenceJob` does not, so a
reference written from a job runs in the worker's zone (`America/New_York`
default). Not a bug for cost, but the per-account cap must count what the
user sees as today, so the gate reads the user's zone explicitly rather than
`Date.current`.

---

## 3. The capacity probe, as built

### 3.1 Design

`script/probe_gemini_capacity.rb` (runner) and `script/gemini_capacity_probe.rb`
(`GeminiCapacityProbe`, with `spec/script/gemini_capacity_probe_spec.rb`
driving it against a stubbed connection that answers every production
prompt the way `FakeService` does, then refuses with the stored 429 body).
Never in CI; `GEMINI_API_KEY` from the environment; writes no `ApiUsage`
rows and no exercise, response or reference. It builds an anonymous
`GeminiService` subclass that overrides `log_usage` to write nothing and
`build_connection` to use no retry middleware and a `Recorder` middleware
that keeps every HTTP attempt's status, response headers, latency and
usage block in an `AttemptLog` shared by every service thread of a step;
a step reads its attempts only once none is still on the wire, since the
review's difficulty thread can outlive `review_sections` by its grace
period. It runs in the user's `effective_time_zone`, as generation does,
so the day and a mixed account's language are theirs. The prompts are the production ones: it goes through
`AiService`'s entry points, as `ModelComparison` does.

```
GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID
GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID --no-pace
GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID --pace 20 --max-days 3
```

`--user ID` is required: the prompts are built from that stored account's
history, so the day is a realistic one. The plan is held to two sections by
setting `daily_section_count` on the loaded user in memory only; the stored
setting is untouched (pinned by the spec). One tester-day, in order:

| Step | Entry point | Calls |
|---|---|---|
| Draft | `draft_exercise(user, language:, blocking: false)`, the batch's budget | 1 |
| Judge | `judge_section` for each fixed section, at the user's rung and lock | 2 |
| Review | `review_sections` on an in-memory `DailyResponse` with short answers | 2 grading + 1 difficulty |
| First-exposure reference | `generate_concept_reference` for the draft's `code_review` concept | 1 |
| Duck | `duck_response` three turns on `code_review`, each carrying the thread | 3 |

`GeminiCapacityProbe.calls_per_day` derives the ten from the fixed-kind
count and `DUCK_TURNS`. It repeats tester-days until a provider reply is a
429 or `--max-days N` is reached, pacing steps with `--pace SECONDS`
(default 15) so the daily limit is what trips, with `--no-pace` to measure
the per-minute limit instead. The review fan-out still sends its three
calls together, so the wait before a step is the pace times the requests on
either side of it (three paces before and after the fan-out); at the default
no rolling minute holds more than five requests, which the spec checks. A reply the app could not use (a
judge verdict that fails `JudgeVerdict.parse`, an unparseable reference) is
recorded with its error and the day goes on, since the probe measures quota,
not output quality. A 429 inside the review fan-out raises nothing of its
own, so it is read off the recorded attempts and still ends the run.

Per attempt it prints: day, step, HTTP status, latency, `total_input_tokens`,
`total_output_tokens`, `total_thought_tokens`, `total_cached_tokens`. On a
non-2xx it writes the status, response headers and full body to
`tmp/gemini_probe/<timestamp>-<sequence>-<status>.json`, one file per
attempt (`tmp/` is gitignored; request headers are never captured, and the
body of a 401, 403 or `API_KEY_INVALID` reply is left out, since Google's
rejected-key reply can echo the key) and prints the
`quotaId`, `quotaValue`, `retryDelay` and any `Retry-After` header. The
first 429 body is also written as `tmp/gemini_probe/gemini_429_capture.json`,
the shape `spec/fixtures/provider_errors/` holds, so replacing a fixture is a
copy.

The report at the end: requests made; the request number of the first 429
and which limit by `quotaId` (`PerMinute`, `PerDay`, a token quota, or
unrecognized); the `retryDelay` and `Retry-After` returned; tokens per
completed tester-day (a day the 429 cut short is left out); tester-days per
quota day as `quotaValue / calls_per_day` when the quota is per day; and the
largest single request's input tokens, to read against the per-minute token
quota.

### 3.2 When to run it

It spends the whole day's free quota on that key, so run it on a day you will
not use that key yourself, just after the quota resets (midnight Pacific, so
3am Eastern), and not on a day teammates on the same project key need it.
Expect it to run for most of an hour at the default pace. Run it once with
pacing for the daily figure, and once more on a later day with `--no-pace`
for the per-minute figure.

### 3.3 What to read from Google AI Studio

I could not open the page from here, so read these yourself:

1. In Google AI Studio, the usage and limits page for the project the key
   belongs to (sidebar "Usage & Billing", or `aistudio.google.com/usage`):
   the project's tier (Free or Tier 1), and for `gemini-3.5-flash` the
   three columns RPM, TPM and RPD, plus today's used count.
2. On `ai.google.dev/gemini-api/docs/rate-limits`: the Free tier row for
   `gemini-3.5-flash` (RPM, TPM, RPD), the sentence on when RPD resets
   (midnight Pacific), the statement that limits are per project, and
   whether the Interactions API is listed as sharing `generateContent`'s
   quotas or carrying its own.
3. In Google Cloud Console for the same project: APIs & Services,
   Generative Language API, Quotas & System Limits. Note the exact quota
   names and values for "Generate requests per minute per project per
   model (free tier)", "Generate requests per day per project per model
   (free tier)" and the input-tokens-per-minute quota, and whether an
   "interactions" quota appears separately.
4. Whether any other project or app uses the same key, since the quota is
   shared across everything that calls with it.

The key guide on Setup already says "about 20 requests a day when we tested
it"; the probe replaces that recollection with a measured figure.

---

## 4. Informative errors, as built

### 4.1 Classification

`ProviderFailure.classify(error)`, pure, read from the error class,
`http_status`, `quota_id` and `retry_after` at the boundary where each
caller already rescues. No prompt or grading changes. The trial classes
arrive with trial mode.

| Class | From |
|---|---|
| `daily_limit` | `RateLimitError` whose `quota_id` contains `PerDay`, or whose `retry_after` is an hour or more |
| `short_rate_limit` | any other `RateLimitError`, including Anthropic's 429 and 529 |
| `bad_key` | `AuthenticationError`: 401 and 403 on every provider, and Gemini's 400 with `details[].reason == "API_KEY_INVALID"`, read from the body without logging it |
| `out_of_credit` | the new `AiService::BillingError`. Anthropic, per platform.claude.com/docs/en/api/errors and /rate-limits (read 2026-10-06): a 402 `billing_error`; a 400 `invalid_request_error` beginning "You have reached your specified ... API usage limits" (a spend limit the account set) or naming the credit balance; a 429 `rate_limit_error` whose `details.error_code` is `enforced_spend_limit_reached` (the tier's monthly cap, sent with no `retry-after`). OpenAI: a 429 whose `error.code` is `insufficient_quota`, or a 402. OpenAI's reference (platform.openai.com/docs/guides/error-codes) could not be fetched from the build environment, so that code string is from memory of the page and should be checked against it once |
| `outage` | `NetworkError` (a refused or reset connection) or an `Error` with a 5xx status |
| `timeout` | `TimeoutError`, or a `Timeout::Error` from the review fan-out |
| `other` | everything else: an unreadable or invalid reply, a 4xx with no narrower class, a refusal |

`BillingError` is raised by the provider before a 429 can become a
`RateLimitError`, so an empty balance is never retried as a limit by
anything downstream and never told to wait.

### 4.2 Text

One locale table, `provider_failures`. Each class has a variant per
credential (`own_key` now; `trial` is added as text alone, falling back to
`own_key` for any entry it leaves out) with `title`, `reset_at`,
`reset_passed` and `next`. The surface supplies what did not happen
(`provider_failures.outcomes.<surface>`) and what is still there
(`provider_failures.saved.<surface>`), so one title serves every surface.
`ProviderFailureText#full` is title, saved, reset, next; `#brief` is title
and the reset or the next step, for a status line. The same table serves the
dashboard's generation panel, the review flash, the JSON endpoints' `error`
and Learn's status line. Every surface stopped passing `e.message`, and
`provider_failure_text_spec` holds every kind on every surface for every
provider and variant to carrying no provider text, status code, socket
detail or key.

Reset times come from `ResetClock.reset_at(kind, provider:, failed_at:,
retry_after:)` and are rendered in the user's `effective_time_zone`:

- `daily_limit`: the provider class's `daily_quota_reset_at`, looked up
  through `AiProvider.find`, so the clock holds no provider branch.
  `GeminiService` answers the next midnight Pacific after the failure, shown
  as "The allowance resets at 3:00 am your time, Wednesday."; the base
  class, and so every other or unknown provider, gives a day from the
  failure.
- `short_rate_limit`: the wait the provider asked for, never under a
  minute: "Try again in about a minute" or "about 3 minutes".
- Once the reset has passed, the sentence says so instead ("The allowance
  has reset since then, so you can try again." / "You can try again now.")
  and drops the next step, which would point at a time behind the reader.
- `trial_allowance_used` and `trial_ended` arrive with trial mode.

The sentences as shipped (the `own_key` variant, Gemini, the review
surface):

- daily limit: "Your Gemini key has used today's free allowance, so the
  review didn't run. Your answers are saved. The allowance resets at 3:00 am
  your time, Wednesday. Try again after that, or add a paid key in Setup."
- short rate limit: "Gemini is limiting requests right now, so the review
  didn't run. Your answers are saved. Try again in about a minute."
- bad key: "Gemini didn't accept your API key, so the review didn't run.
  Your answers are saved. Check the key in Setup."
- out of credit: "Gemini reports that your account is out of credit or over
  its spend limit, so the review didn't run. Your answers are saved. Add
  credit or raise the limit with Gemini, then try again."
- outage: "Gemini isn't answering right now, so the review didn't run. Your
  answers are saved. Nothing was lost. Try again in a few minutes."
- timeout: "Gemini took too long to answer, so the review didn't run. Your
  answers are saved. Try again."
- other: "Gemini sent back something Code Gym couldn't use, so the review
  didn't run. Your answers are saved. Try again. If it keeps happening,
  tell the person who runs Code Gym."

### 4.3 Where it lands

- Generation and regeneration store the class, the provider the call went
  to, the time and the wait it asked for (`AddLastGenerationFailureToUsers`,
  flagged: `users.last_generation_failure` string,
  `last_generation_failure_provider` string, `last_generation_failed_at`
  datetime, `last_generation_retry_after` integer) through
  `User#record_generation_failure!`, and the dashboard panel, the
  regeneration line and `/dashboard/status` render
  `User#generation_failure_message` when read. The provider is stored
  because `AiService::Error#provider`, stamped by `call_and_log` with the
  class whose call raised, is what the sentence names: a user who switches
  keys before reading still sees which provider failed, and a row with no
  provider falls back to the current one. `last_generation_error` keeps
  text that is not a provider failure (`record_generation_message!`: a
  reviewed set kept, an unusable draft, every section rejected) and rows from
  before the columns existed, which render as before.
- The review fan-out's per-section result carries `failure`, `provider`,
  `quota_id` and `retry_after` instead of the message; `review_errors`
  stores `{kind, provider, quota_id, retry_after, at}`; the flash for a wholly failed review
  is the commonest kind's full sentence, a partial review's notice ends with
  that kind's brief one, and the submitted dashboard renders the newest
  stored failure beside the retry button. Old rows with `code` read as the
  nearest kind.
- The five JSON endpoints and `ConceptReferencesController` render
  `{status: "error", error: <brief>, failure: <kind>}` through
  `ProviderFailureRendering`.
- Learn: a departure from the design. The row is shared by every user, so no
  column was added; `ConceptReferenceFailures` keeps the failure in the Rails
  cache by user and concept for `EXPIRY` (one hour, shorter than any quota's
  reset), `/learn/:bucket/:concept/status` returns `failed` and the sentence,
  and the page stops polling on it. Asking again clears the note, and so does
  a write-up landing. Production's cache is Solid Cache in the one Postgres
  database, shared by web and worker; development's memory store is per
  process, where the jobs run in the web process anyway.
- The judge's fallback and the difficulty check are unchanged: a judge
  failure ships the draft and the difficulty note is dropped, as before.

### 4.4 Specs

`provider_failure_characterization_spec` is the target: one example per
failure class per path, with the stubbed bodies, asserting the sentence and
that it carries nothing from the provider. `provider_failure_text_spec` holds
the before-and-after-reset sentences under `travel_to` and the no-leak rule
over every kind, surface, provider and variant. `provider_failure_spec`,
`reset_clock_spec` and `api_usage_spec` cover the pure pieces;
`ai_service_spec` the failure rows and refusal and truncation marks; the
three provider specs the `quota_id`, `retry_after`, `API_KEY_INVALID` and
out-of-credit readings; `learn_write_up_failure_spec` the cache note, its
expiry and its clearing.

---

## 5. Where keys and providers resolve today

- `User#provider` names the provider in use; `User#api_key` reads
  `api_keys[provider]` (`user.rb:286`); `User#api_key_present?` is the
  single gate everything else reads.
- `AiService.for(user)` (`ai_service.rb:1047-1055`) looks the provider class
  up in `AiProvider.all`, refuses an unavailable one, and does
  `provider.new(user.api_key)`. Every call site goes through it: the review
  and the five JSON endpoints in `ResponsesController` and
  `ConceptReferencesController`, and the four jobs.
- `ApplicationController#require_api_key` redirects to Setup unless
  `api_key_present?`, skipping `api_keys` and `sessions`.
- `DashboardController#show` auto-enqueues generation only when
  `api_key_present?`.
- The nightly batch selects `User.active.where.not(api_keys: nil)`
  (`generate_daily_exercises_job.rb:35`), so an account with no stored key is
  never generated by cron.
- `User` validates `provider` against `AiProvider.keys` and requires a stored
  key for the provider in use (`provider_has_a_stored_key`).
- `ApiKeysController#update` detects the provider from the key's prefix and
  stores both; `preferences_update` switches among stored keys.
- `DailyResponse#review_provider_label` and `User#provider_label` name the
  provider on pages; `PreviewSeed` stores a dummy Anthropic key.

### 5.1 What a trial needs, as built

`AiService.for(user)` builds `provider.new(credential.key)` from
`ProviderCredential.for(user)`, which returns the user's own key when they
stored one, no key when they have neither key nor trial (as before trials
existed), and the house key for `user.provider` while the trial is active.
It raises `AiService::TrialEndedError` when the trial has ended, the kill
switch is on, or the provider has no house key set. The key is read from
`ENV` at that moment and never stored. The service carries `house_key?`,
which the per-section review and judge threads inherit (`fresh_service`),
which `log_usage` writes to the row, and which decides whether the trial
gates run. `User#provider_ready?` (own key, or active trial) replaces
`api_key_present?` behind `require_provider` and the dashboard's on-demand
generation; the nightly batch still selects stored keys, so a trial account
is generated only when it opens the dashboard. `provider_has_a_stored_key`
already returns early for a nil `api_keys`, so a trial account's provider,
set from the invite, needs no exception.

Existing accounts: `api_keys` present, `invite_code_id` nil, so every new
branch is false and `ProviderCredential.for` returns the same key
`User#api_key` returns today.

---

## 6. Trial mode

### 6.1 Storage and migrations (flagged), as built

`CreateInviteCodes`:

| Column | Type |
|---|---|
| `code_digest` | string, null false, unique index (SHA-256 of the code; a 26-character base32 code from `SecureRandom` has 130 bits, so a digest lookup is enough and no slow hash is needed) |
| `label` | string (for you; never shown) |
| `provider` | string, null (nil means a plain join code, see section 7) |
| `seats` | integer, null false |
| `redeemed_count` | integer, default 0, null false |
| `expires_at` | datetime, null false (redemption deadline) |
| `trial_days` | integer, null (required for a trial code) |
| `daily_request_cap` | integer, null (no cap when nil) |
| timestamps | |

`AddTrialToUsers`: `invite_code_id` (bigint, fk, null), `trial_started_at`,
`trial_ends_at`, `trial_consented_at` (datetimes, null). `User#trial?` is a
present `trial_ends_at`; `trial_active?` adds that it is in the future, the
kill switch is off and the provider's house key is set; `trial_pending?` is
an account that signed up with a trial code and has not consented yet. No
`is_trial` flag.

Minting: `bin/rails runner script/mint_invite_code.rb --provider gemini
--seats 2 --days 7 --cap 12 --expires 2026-10-31 --label "pilot"` prints the
code once, in groups of four; without `--provider` it mints a join code.
`InviteCode.find_by_code` ignores case, spaces and dashes.

### 6.2 Redemption, as built

`GET /trial` shows the form with the data notice and consent checkbox, or,
for a trial account, the day the trial ends and the notice for its provider;
`POST /trial` redeems. `require_provider` lets `trials` through like
`api_keys`. Rate limited at 10 per IP and 5 per account per hour through
`rate_limit` with `LazyCacheStore`. A missing consent is refused with its own
sentence and saves nothing; a wrong, expired, exhausted, already-used or join
code gets one sentence: "That code didn't work. Check it and try again, or
ask the person who gave it to you."

`User#start_trial!(code:, consented_at:)` runs under the user row lock and
refuses an account that already has a trial or another code. Taking the seat
is one statement, `InviteCode#redeem!`:

```sql
UPDATE invite_codes SET redeemed_count = redeemed_count + 1
WHERE id = ? AND redeemed_count < seats AND expires_at > now()
```

An account that signed up with a trial code already holds its seat, so
consenting there takes none. It sets `provider` from the code,
`trial_started_at` and `trial_consented_at` to the consent time, and
`trial_ends_at` to the end of the trial's last day in the user's zone (a
7-day trial started on a Tuesday ends at the end of the next Monday).
`invite_code` joins `filter_parameters`, since `_key` does not cover it.

### 6.3 House keys and the kill switch, as built

`HOUSE_<PROVIDER>_API_KEY`, one per provider (`HOUSE_GEMINI_API_KEY`,
`HOUSE_ANTHROPIC_API_KEY`), resolved by `HouseKeys.for(provider)` at call
time; `TRIALS_DISABLED=1` is the kill switch, read by `TrialMode.enabled?`
on every call and every page. A trial whose provider has no house key set
behaves as ended. Neither value is written to the database, a log, a page or
a diagnostics line; the key reaches `AiService` the way a user's key does, as
a constructor argument, and `log_usage` writes `house_key: true`, never the
key.

### 6.4 Caps, as built

`TrialAllowance.check!` runs in `AiService#call_and_log` ahead of `call`,
only when the service holds a house key, and raises
`AiService::TrialAllowanceError` with `retry_after` set to the seconds until
the count resets; a refused call writes no usage row and never reaches the
provider:

- Per account: `ApiUsage.requests_on(user, day, provider:)` on the user's
  own day, attempts included, against the invite's `daily_request_cap`;
  resets at the user's next midnight. No cap when the invite sets none.
- Global: `ApiUsage.house_requests_between(provider:, from:, to:)` over the
  provider's quota day (`AiService.quota_day`: Pacific for Gemini, UTC for
  a provider that states no boundary) against
  `HOUSE_<PROVIDER>_DAILY_GUARD` from `ENV`; resets at the end of that day.
  No guard when unset.

A count-then-call gate overshoots by at most the fan-out width (a review on a
two-section day makes three calls at once), which is acceptable and bounded.

`ProviderFailure` gains `trial_allowance_used` and `trial_ended`;
`ProviderFailureText` writes those in the `trial` variant whatever variant
is asked for, and `ProviderFailureText.variant_for(user)` picks `trial` for
a trial account with no key of its own. The `trial` variant also carries its
own words for `daily_limit`, `bad_key` and `out_of_credit` ("The trial's
Gemini key…", "Tell the person who runs Code Gym."), so a house-key spend
limit or daily quota keeps its honest kind and reads as the trial's rather
than being reclassified as `trial_allowance_used`, which the design had
proposed; the other kinds fall back to the `own_key` words.

Numbers, provisional until the probe runs. A judged two-section day costs
one draft, two judge calls, up to two retries with re-judges, two grading
calls, one difficulty check, one or two first-exposure references and
whatever the duck is asked: eight at minimum, about twelve normally, up to
sixteen. If the free tier is around 20 requests a day per model, as the key
guide recalls, one free Gemini key supports one trial seat with no room for
you, so:

- `daily_request_cap`: 12 per account.
- Gemini guard: the probe's daily `quotaValue` minus four, kept for your own
  use; seats per Gemini code: `floor(guard / 12)`, which at 20 a day is one.
- Claude house key: set the Anthropic workspace spend limit as the hard
  stop and the guard at 60 requests a day, about five seats.

The per-minute limit is the other constraint. Judge and review fan-outs are
parallel, so one review on a two-section day makes three requests in the same
second, and `faraday-retry` gives up on a `Retry-After` past 8 seconds. On a
5 RPM tier a trial day will trip it. Serializing the fan-out for house-key
calls is a behavior change outside this work's constraints; the alternative
is to recommend the Claude key for trials and to say in the trial screen that
Gemini trials may see "limiting requests right now" messages. Decision for
you.

### 6.5 Generation and the first-run wait, as built

Trial accounts are never in the batch (section 5). Opening the dashboard on a
weekday enqueues the judged on-demand generation exactly as for a new
own-key user before 8am, and the page polls for `JUDGED_GENERATION_BUDGET`.
Typical wait on Gemini Flash is the draft (20 to 60 seconds) plus the judge
fan-out (5 to 15 seconds) plus any retry; worst case is the budget the
poller already allows. The pause rule: `DashboardController#show` treats an
ended trial like `paused_generation_at`, rendering the trial-ended panel
instead of enqueuing, and `/generate` refuses with the trial-ended sentence
before it touches the day.

### 6.6 Trial screen, as built

`/trial` for a trial account, from `TrialStatus.for(user)`: the day the
trial ends and the days left (today included, in the user's zone), requests
used today against the cap (`ApiUsage.requests_on`, the same query the gate
reads; "unlimited" when the invite sets no cap), what happens at the end
(generation and reviews stop, everything stays, add a key to continue), and
the data notice for the trial's provider. Once ended, it says the day it
ended, or only that it has ended when the kill switch or a missing house key
ended it early, and links to Setup. The dashboard carries one banner line
above the set linking here ("Trial: 7 days left. 2 of 12 requests used
today." or "Your trial has ended."), rendered only for a trial account so
every other page is byte-identical. A first-run account is sent to
`/welcome` before this page, as Setup does.

### 6.7 Data notice, as built

Plain words, provider-specific locale keys under `trials.data_notice`, with
"the person who runs Code Gym" where the design had a placeholder for your
name:

- Both: "On a trial, Code Gym sends your exercises, answers and messages to
  [Gemini / Claude] using a key that belongs to the person who runs Code
  Gym, not to you. Usage counts against that key."
- Gemini free tier: "Google's free tier lets Google use what is sent,
  including your answers, to improve its products, and people at Google may
  read it. Don't paste anything confidential."
- Claude: "Anthropic keeps API data for up to 30 days and does not train on
  it by default."

Before the code is checked the provider is unknown, so the form shows the
shared sentence naming both providers and both paragraphs.

### 6.8 Trial end, as built

At `trial_ends_at`, or at once under the kill switch: the account and every
row stay. `require_provider` still lets a trial account through to every
page; `ProviderCredential.for` raises `TrialEndedError`, so the review, the
five JSON endpoints and the concept reference endpoint answer with the
trial-ended sentence through the rescues they already have, and the
dashboard renders the trial-ended panel in place of a set, or the ended
banner above a set that already exists. `/generate` refuses with the same
sentence. Setup shows the existing key guide (`api_keys/_key_guide`) above
the key field for an ended trial whether or not it is on the learning
track, and pasting a key clears nothing about the trial but makes
`provider_ready?` true through the own-key branch. `trial_ends_at` is kept
so the screen can say when it ended.

### 6.9 Junior track, as built

Unchanged. `first_run?` reads `learning_track` and the exercise count, so a
new trial account is sent to `/welcome` before Setup and before `/trial`;
joining sets the junior preset exactly as for any account. The key guide
shown to on-track accounts is replaced on an active trial by a note linking
to the trial page (`api_keys/_trial_note`), which is the one page
difference, inside a `trial_active?` branch.

### 6.10 Existing accounts stay byte-identical, as built

Every new branch tests `trial?`, `trial_pending?` or `house_key?`, all false
for every existing row, and no prompt reads trial state.
`existing_account_pages_spec` holds the page snapshots, and
`spec/services/trial_isolation_spec.rb`, modelled on
`learning_track_isolation_spec`, pins that `AiService` builds byte-identical
generation and judge requests for a trial account and an own-key account
with equal settings, with only the usage rows' `house_key` differing, and
that nothing under `app/services`, `app/jobs`, `ConceptMastery`, the
verdicts or `KindDifficulty` reads trial state. Grading, mastery, the judge
and the prompts are untouched: the house key changes which credential the
request carries and nothing in the request.

---

## 7. Signup, as built

A new account needs a seat on an invite code. The login form gains an
"Invite code (first time only)" field, read only when the address is
unknown; a known address ignores it. An unknown address with no code or a
bad one gets the same "check your email" notice and pending state, and no
account and no mail. A code with `provider` nil is a join code for a
teammate (no trial, no cap; they add their own key as today), so one table
serves both. The account and the seat are taken in one transaction
(`SessionsController#create_invited_user`), so a lost race for the last seat
creates nothing. A trial code at signup links the code and holds the seat;
the trial itself starts on `/trial` once the person has read the data
notice and consented, and `require_provider` sends such an account there
rather than to Setup. This closes audit item L2 without an allowlist. The
cost is that a teammate who loses their code asks you for one.

---

## 8. Trial-end data options

1. Keep everything (default). The account can add a key and continue with
   its history intact.
2. Self-service delete through the existing Account page: `User#anonymize!`
   strips email, name and keys, destroys push subscriptions, and keeps
   exercises, responses, mastery and `api_usages`. The usage rows should
   stay in any case: with `house_key: true` they are the record of what the
   trial cost you.
3. An operator script, `script/expire_trials.rb`, that anonymizes trial
   accounts whose trial ended more than N days ago and that never stored a
   key, through the same `anonymize!`. Dry run by default, `--run` to write.
4. Hard deletion is not recommended: it would also delete the usage rows and
   the exercises, and anonymization already removes everything that
   identifies the person.

---

## 9. Order of work

1. Done: usage record and informative errors (`AddOutcomeToApiUsages`,
   `AddLastGenerationFailureToUsers`, `ProviderFailure`, `ResetClock`,
   `ProviderFailureText`, `BillingError`, `quota_id` on `RateLimitError`,
   Gemini 400 `API_KEY_INVALID` as `AuthenticationError`, the locale table,
   every surface off `e.message`, the per-user Learn failure note, the
   characterization spec turned into the target).
2. Done: the probe, no behavior change. Still to do once it has run:
   replace the fixtures with its capture and set the cap numbers.
3. Done: invite codes, trial accounts, `ProviderCredential`, `HouseKeys`,
   `TrialAllowance`, the kill switch, the minting script, the signup code
   field, the redemption page with the data notice and consent, and the
   trial words for every failure kind.
4. Done: the trial screen, trial end, the dashboard banner and the Setup
   branch (redemption consent shipped with 3).

## 10. Decisions

1. Decided: a code with a migration (section 4.3).
2. Decided: no column on the shared row; a per-user cache note (section 4.3).
3. Caps: accept the provisional 12 per account and the guard formula, to be
   fixed after the probe.
4. Gemini per-minute limit versus the parallel judge and review fan-out:
   recommend Claude for trials, say so on the trial screen, or allow a
   house-key-only serialization as a separate change.
5. Decided and built: a code for every new account (section 7).
6. Anthropic out-of-credit as its own class and sentence.
7. When to run the probe, and on which key.

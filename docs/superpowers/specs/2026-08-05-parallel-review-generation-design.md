# Parallel review generation, per-section atomicity, and prompt caching

## Problem

A recent real-world failure was very likely caused by the single, monolithic
`AiService#review_response` call whose expected response size has grown
substantially as the review schema grew (five possible third-section kinds,
structured array fields, `improved_code` now spanning three section types,
Parsons mismatch explanations) — likely hitting `max_tokens` mid-generation
and producing truncated/invalid JSON (`InvalidResponseError`).

## Already fixed, independent of this spec

The immediate trigger for that failure — `ClaudeService::MAX_TOKENS` stuck at
2500 since the initial scaffold, despite the schema outgrowing it — was fixed
in two commits already on `main` before this spec was written:

- `dab26c4` — raised `MAX_TOKENS` to 8000 and started reporting
  `stop_reason == "max_tokens"` as data.
- `c92f82a` — moved that detection to a shared `call_and_log` wrapper so a
  truncated response's billed usage is still recorded before
  `TruncatedResponseError` propagates (previously it was raised from inside
  `ClaudeService#call`, before `log_usage` ran, silently under-counting cost
  on exactly the calls that burned a full output budget).

This spec does not depend on or repeat that fix. It exists because raising
the cap only pushed the ceiling out — it didn't remove the structural risk of
one call carrying the entire review, and it did nothing for the UX of an
all-or-nothing failure (today, one bad section fails the whole review with no
partial credit).

## Goals

1. Split review generation into three independent, parallel calls (one per
   section: `code_review`, `pattern`, the day's third section) instead of one
   monolithic call.
2. A failure in one section's call must not prevent the other two from being
   saved. Partial review state must be representable, retryable, and
   correctly reflected everywhere `ai_review` is read.
3. The existing "`ai_review` write + `ConceptMastery` update in one
   transaction" guarantee — tier/streak state can never silently drift out of
   sync with what was actually reviewed — is preserved, scoped down to
   per-section instead of per-response.
4. Offset the cost of sending shared instructions 3x instead of once, via
   Anthropic prompt caching.
5. Preserve grading consistency across a day's three sections despite calls
   being isolated, via shared day-context in each call's prompt.

## Non-goals / constraints

- No change to grading/evaluation criteria per section kind.
- No change to `AiService`'s provider dispatch, retry/backoff, or typed error
  classes (`AuthenticationError`, `RateLimitError`, `InvalidResponseError`,
  `TruncatedResponseError`) — reused exactly as-is, per section call.
- No Gemini-specific rate-limit throttle — the 3x RPM consequence is
  documented, not mitigated (see below).
- No Gemini-specific caching implementation (see below).

## Data model changes

### `daily_responses.review_errors` (new jsonb column, default `{}`)

Keyed by section key, holding a short error code for any section currently
missing from `ai_review`:

```ruby
{ "pattern" => "rate_limit" }
```

Codes: `"authentication"`, `"rate_limit"`, `"invalid_response"`, `"other"`
(anything not in the first three, including `TruncatedResponseError` — a
subclass of `InvalidResponseError` — and network errors). A section's key is
removed from `review_errors` the moment that section succeeds; it's the
mechanism that lets a partial-review view explain *why* a section is still
missing rather than showing a bare gap. Migration: add column, no backfill
needed (existing rows have no missing sections to describe).

### `DailyResponse` predicates

- `reviewed?` — **unchanged**. Still `ai_review.present?` (true once *any*
  section has content). Every render path (`shared/_ai_review.html.erb`,
  `ReviewMailer`, `history/index.html.erb`) already iterates `ai_review.each`
  and is naturally partial-tolerant, so nothing there changes.
- `fully_reviewed?` — **new**. All of
  `daily_exercise.problem_set.keys` present as a `Hash` in `ai_review`.
  Replaces `reviewed?` in the three places that actually meant "nothing left
  to do": the `review` action's "already reviewed" guard, `email_review`'s
  guard, and `_submission.html.erb`'s button-visibility check.
- `section_reviewed?(section)` — **new**.
  `ai_review&.dig(section.to_s).is_a?(Hash)`. Replaces the response-wide
  `reviewed?` check inside `require_reviewed_section!`, so
  `self_explanation` / `explain_differently` / `follow_ups` gate on that
  *specific* section having real review content, not just "something in this
  response was reviewed."

## Parallel call architecture

`AiService#review_response` is replaced by
`AiService#review_sections(user, exercise, daily_response, sections:)`
(no other caller of `review_response` exists, so this is a rename+reshape,
not an addition).

For each key in `sections` (the caller passes only the currently-missing
ones — 1, 2, or 3), a thread is spawned that:

1. Instantiates its own `AiService.for(user)` — a fresh instance, and
   therefore a fresh `@conn` / `build_connection` per thread. No Faraday
   connection is shared across threads; this sidesteps auditing
   `Faraday::Connection`'s thread-safety entirely, at the cost of one extra
   cheap object per parallel call (no I/O in `build_connection` itself).
2. Calls `call_and_log` exactly as today (same retry/backoff, same error
   classes, same usage logging) with a per-section system prompt and prompt
   body (see below).
3. Rescues `AiService::Error` and returns a tagged failure instead of
   propagating, so one section's exception can't unwind the others.

The main thread joins all spawned threads and returns:

```ruby
{
  "code_review" => { ok: true, review: { "rating" => "solid", ... } },
  "pattern"     => { ok: false, error_code: "rate_limit", message: "..." },
  "challenge"   => { ok: true, review: { ... } }
}
```

`override_parsons_rating!` (today applied once to the whole review hash)
moves to apply per-section, only when `"parsons_problem"` is among the
succeeded sections.

## Shared day-context prompt

Each per-section call's prompt includes all three sections' questions, the
user's answers to all three, and all three self-ratings up front — content
that's fully known before any call starts, so it introduces no sequential
dependency. Each call is still asked to grade only its own section. This
exists to prevent grading drift: without a shared reference point, three
fully isolated calls could calibrate "developing" vs. "solid" inconsistently
across a day's sections even though each concept is already evaluated
independently by the mastery-tier system. There is no single "day scenario
theme" field in this app's data — each section already carries its own
independent business-domain scenario — so "shared context" here means the
other sections' actual Q&A content and ratings, not a unifying theme string.

## Prompt caching (Claude)

Anthropic's `cache_control` requires `system` to be sent as a content-block
array, not a plain string — `cache_control` is a property of a content
block. `ClaudeService#call`'s `system:` parameter is extended to accept
either:

- a `String` (existing behavior, unchanged) — every non-review entry point
  (`generate_exercise`, `generate_concept_reference`, `explain_differently`,
  `answer_follow_up`) keeps sending a plain string and sees zero behavior
  change.
- an `Array` of Anthropic content blocks (new) — `review_sections` builds the
  shared system instructions + day-context text once per review action and
  passes it as
  `[{ type: "text", text: shared_text, cache_control: { type: "ephemeral" } }]`
  to all three parallel calls.

The first of the three concurrent calls to reach Anthropic writes the cache
(billed ~1.25x that portion); the other two — fired concurrently within the
same request — read it at a fraction of input price. Net effect: the shared
system/day-context content is billed roughly once per review action instead
of three times, for Claude users.

`GeminiService#call` is unaffected — it continues to accept `system:` as a
plain string; `review_sections` passes the day-context as a plain string
prompt to Gemini calls, same as everywhere else in this app.

## Gemini caching — investigated, not implemented

Gemini's explicit context-caching API (`cachedContents`) requires a separate
create-cache API call ahead of time and, historically, a minimum token count
this app's prompts are unlikely to reliably clear; whether an applicable
automatic/implicit caching tier exists for the model and call pattern this
app uses isn't something this investigation could verify with confidence.
Given the added complexity (extra API round-trip, cache lifecycle
management) for an uncertain benefit at this prompt size, **Gemini-side
caching is out of scope for this change.**

**Documented cost-parity gap:** only Claude users get a cost mitigation from
splitting into three calls. Gemini users bear the full 3x shared-content
cost with no offset. This is a real, known tradeoff, not an oversight.

## Gemini rate-limit impact

Firing three concurrent calls per review action instead of one triples the
per-review-action RPM consumed. This matters specifically for Gemini's free
tier (~15 req/min), which the existing retry/backoff (`GeminiService::RETRY_OPTIONS`)
was built around precisely because that limit is tight. Teammates on that
tier may see review actions collide with their own retries more often than
today. Per explicit direction, this is **documented as an accepted tradeoff
of the parallel design, not mitigated** with a stagger or concurrency cap.

## Per-section atomicity model

This is the core of the redesign. `ConceptMastery.record_review!` today does
two things in one call, both implicitly scoped to "the whole response,
reviewed exactly once":

- **Step A** — decrements every paused concept's cooldown once (a
  once-per-session action).
- **Step B** — evaluates every concept present in `response.concept_tags`.

Calling this once per partial batch (an initial partial success, then a
later retry) would double-fire Step A and could double-evaluate a concept
already evaluated in an earlier batch. The fix splits scope explicitly:

```ruby
def self.record_review!(response, sections:, apply_session_countdown:)
  if apply_session_countdown
    user.concept_masteries.tier_paused.each { |cm| ... } # Step A, unchanged logic
  end

  sections_by_concept = Hash.new { |h, k| h[k] = [] }
  response.concept_tags.slice(*sections).each do |section, concept|
    next if concept.blank? || concept == "other"
    sections_by_concept[concept] << section
  end

  sections_by_concept.each do |concept, secs|
    bucket = ConceptBucket.for(secs, response.daily_exercise.language)
    evaluate_concept!(user, concept, bucket, response, secs)
  end
end
```

- `apply_session_countdown` is `true` only when the controller determines
  `first_batch = @response.ai_review.blank?`, captured **before** merging
  the current request's results in. A retry request only ever fires for
  sections still missing from `ai_review`, which means `ai_review` was
  already non-blank when it started — so Step A never re-runs on a retry.
- `sections:` restricts Step B to concepts belonging to sections that
  succeeded *in this request*. Because a section is only ever selected as
  "missing" until the moment it first succeeds — after which it's
  permanently present in `ai_review` — no concept can be evaluated twice
  across a partial batch and a later retry.

**Write scope**: one transaction per controller request, covering exactly
the sections that succeeded in that request's batch:

```ruby
if successes.any?
  ActiveRecord::Base.transaction do
    @response.ai_review = (@response.ai_review || {}).merge(
      successes.transform_values { |r| r[:review] }
    )
    @response.review_errors = @response.review_errors.except(*successes.keys)
                                                       .merge(failure_error_codes)
    @response.save!
    ConceptMastery.record_review!(@response, sections: successes.keys,
                                   apply_session_countdown: first_batch)
  end
end
```

Failed sections never enter this transaction at all — they only ever touch
`review_errors`, and that write happens alongside the successes' write in
the same statement, not as a competing transaction. A failure can't roll
back or block a success because there is no separate transaction for it to
roll back; the only DB write a failed section causes is recording *why* it
failed. This preserves the original guarantee — tier/streak state can never
silently drift out of sync with what was actually reviewed — at per-section
grain: a concept's mastery only ever moves in the same transaction as the
review content that justified the move.

## Controller flow (`ResponsesController#review`)

```ruby
def review
  return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?

  missing = @response.daily_exercise.problem_set.keys - Array(@response.ai_review&.keys)
  return redirect_to history_anchor, notice: "Already reviewed." if missing.empty?

  unless claim_review!
    return redirect_to root_path, alert: "A review is already being generated for this — check back in a moment."
  end

  first_batch = @response.ai_review.blank?
  results = AiService.for(current_user).review_sections(current_user, @response.daily_exercise, @response, sections: missing)
  successes, failures = results.partition { |_, r| r[:ok] }.map(&:to_h)

  if successes.any?
    ActiveRecord::Base.transaction do
      # merge ai_review + review_errors, save!, ConceptMastery.record_review!
    end
  end
  release_review_claim!

  case
  when failures.empty?
    redirect_to history_anchor, notice: "Review ready!"
  when successes.any?
    redirect_to root_path, notice: "#{successes.size} of #{missing.size} sections reviewed — #{failures.size} couldn't be reviewed, try again."
  else
    # zero successes: same per-error-class alert behavior as today
    # (AuthenticationError / RateLimitError / generic Error), still root_path
  end
end
```

- `claim_review!` drops its `ai_review: nil` clause. It claims purely on
  `reviewing_since` staleness — a partially-reviewed row is a valid claim
  target for a retry, same as a never-reviewed row is for an initial review.
- Zero-success redirects keep today's exact per-error-class alert text
  (`AuthenticationError` → "check it in Settings", `RateLimitError` →
  "try again shortly", generic `Error` → the message). If all failures share
  one error class, that class's message is used; if they're mixed, a generic
  "couldn't generate the review" alert is used, consistent with today's
  single-error-class handling not needing to anticipate mixed causes at the
  top level (per-section reasons remain visible via `review_errors` for
  anyone who then partially retries and later fails again).

## UI

`_submission.html.erb`:
- Button visibility: `unless response.reviewed?` → `unless response.fully_reviewed?`.
- Label: "Finish review" when `response.reviewed?` is true but
  `fully_reviewed?` is false (partial state); today's existing
  `t("review.get_button", ...)` label otherwise.

`shared/_ai_review.html.erb` needs no changes — it already renders whatever
keys are present in `ai_review`, which is exactly a partial-review hash.

**Verification note**: this spec's copy logic (full sections rendering
normally, a missing section showing no content, "Finish review" appearing in
between) needs to actually be looked at in a browser against a real partial
state before being called done — read correctly on paper isn't the same as
reading correctly next to two fully-rendered review sections. This follows
the same practice this app already applies to its inline-JS-driven flows
(rating-gated submit, review loading state): verified by eye, not assumed
correct from spec or passing specs alone.

## Testing considerations

- `AiService#review_sections` service spec: all-succeed, all-fail, and mixed
  outcomes; verify each thread gets its own connection (e.g. by stubbing
  `build_connection` and asserting call count == sections count); verify
  `override_parsons_rating!` only applies when `parsons_problem` succeeded.
- `ConceptMastery.record_review!` spec: `apply_session_countdown: false`
  never touches paused concepts' cooldown; a concept whose section isn't in
  `sections:` isn't evaluated even if `concept_tags` contains it.
- `ResponsesController#review` request specs: full success (unchanged
  behavior), partial success (redirect to root_path with count notice,
  `review_errors` populated for the failed section(s), retry only re-fires
  those), a second partial retry fully completing (no double-counted
  cooldown/streak movement), total failure (existing per-error-class alert
  behavior preserved).
- `ClaudeService#call` spec: `system:` as Array sends `cache_control` in the
  request body; `system:` as String is sent exactly as before (regression
  guard for every non-review caller).
- System spec (`FakeService`): `FakeService` currently returns all section
  kinds from one call — confirm/update it to support a `sections:`-scoped
  response so a system spec can exercise the "Finish review" button
  appearing after a partial state, without needing this to assert which
  specific third section `DailyPlan` picked (still out of scope for system
  specs, per existing convention).
- Manual browser verification of the partial-review UI, per the note above.

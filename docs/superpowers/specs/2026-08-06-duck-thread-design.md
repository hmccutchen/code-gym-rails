# Rubber-Duck Socratic Thinking Partner

**Date:** 2026-08-06
**Status:** Approved (revised 2026-08-06: fully unpersisted — see "Revision" below)

## Problem

Today the only AI-mediated conversation available to a user happens *after*
submission: `ReviewFollowUp` clarifies a completed review, and
`self_explanation` asks the user to restate a fix in their own words after
seeing it. Neither helps while someone is actually stuck, mid-attempt,
before they've written an answer worth reviewing. There's no real-time
thinking support during the moment it would matter most.

## Goal

A Socratic thinking partner available only while a section is unsubmitted —
distinct from `ReviewFollowUp` (post-review clarification) and
`self_explanation` (post-review reflection). It never states an answer or
writes corrected code; it only asks guiding questions, using the section's
own prompt content as context. Purely conversational support — no grading,
no effect on ratings, concept tags, or `ConceptMastery`.

## Revision: fully unpersisted, no table

The original version of this spec mirrored `ReviewFollowUp`'s table-backed
structure (a `duck_threads` table, cap enforcement via row locking). That is
now **out of scope entirely**. There is no migration, no `DuckThread` model,
and no database writes anywhere in this feature:

- The client (one inline script instance per section, matching the existing
  per-partial script pattern) holds the conversation thread **in memory**
  for that browser tab only — a plain JS array of `{ role, content }` turns,
  built up as messages are sent and received.
- Each request to the duck endpoint includes the **full current thread
  array** alongside the new message. The server uses it only transiently, to
  build context for that one `AiService` call — it is never written anywhere
  and never read from any prior stored state.
- Cap enforcement (`MAX_DUCK_TURNS_PER_SECTION = 6`, unchanged) is based on
  the length of the thread array included in the request — reject (422) if
  it's already at or over the cap. **This is a soft, request-level check,
  not a hardened security boundary** — a client could in principle send a
  hand-crafted request with a short thread array to exceed 6 real exchanges.
  That's an acceptable tradeoff given the trust model here: each user
  supplies their own provider API key, so any such cost lands on the user
  who did it, not on anyone else — self-limiting by construction. This is a
  deliberately different posture from `ReviewFollowUp`'s server-enforced cap,
  justified by the fact that nothing here is persisted, evaluative, or
  shared with another user.
- "Clear" is purely client-side: it empties the in-memory thread array and
  the visible turn list. Since nothing is persisted, this naturally and
  fully resets the cap too — a fresh empty array starts back at zero. No
  server call for Clear at all.
- No read-only view after submission — now true **by construction**, not by
  choice: nothing survives a page reload in the first place, since nothing
  was ever stored.
- Draft-answer context (the user's in-progress answer text) is **not** sent
  to the model — only the section's own question/scenario/snippet. This
  narrows what leaves the browser on every keystroke-adjacent request to
  exactly what's needed for a Socratic prompt to work, and keeps the feature
  from quietly becoming a second channel for reviewing an unsubmitted
  answer.

Everything else — the availability gate (unsubmitted only), the Socratic
system prompt and its constraints, the tight `max_tokens` structural
backstop (150 tokens), and the turn cap value — stands as originally
specified below.

## Endpoint: the actual minimal requirement

With no persistence, the natural question is whether the endpoint needs any
`DailyResponse`/`DailyExercise` context at all. It does, but only
**read-only**, for two things:

1. **Section context to build the prompt** — the section's
   question/scenario/snippet live on `DailyExercise#problem_set`, not on the
   client. The endpoint still looks up today's exercise
   (`current_user.daily_exercises.for_date.first`) to read that section's
   fields.
2. **The submission gate** — "available only while unsubmitted" has to be
   enforced somewhere the client can't spoof. The endpoint does a read-only
   `current_user.daily_responses.find_by(daily_exercise:, date: Date.current)`
   and rejects (422) only if a response exists **and** `submitted_at` is
   present. If no response row exists yet, that's unambiguously unsubmitted
   — proceed. Nothing is created, saved, or locked.

That's the full requirement. No `find_or_initialize_by`, no `save!`, no
`with_lock` — every one of those existed in the prior draft solely to attach
rows to a persisted `DailyResponse`, which no longer exists in this feature.

## `AiService#duck_response`

```ruby
def duck_response(user, exercise, section:, message:, thread: [])
```

No `daily_response` parameter — there is no draft-answer context and no
persisted state to read. Returns a plain string (no JSON parsing — same
reasoning as `explain_differently`/`answer_follow_up`: there's no structure
to parse). Logged via `call_and_log` with `purpose: "duck_thread"` (added to
`ApiUsage::PURPOSES`, giving this feature its own line in cost tracking).

**System prompt** — explicit, strongly-worded Socratic constraints:

```
You are a Socratic thinking partner helping an engineer work through a
problem they have NOT yet submitted or been graded on.

Rules, no exceptions:
- Never state the correct answer, the specific fix, or write corrected or
  complete code — not even as an illustrative example.
- Respond ONLY with a guiding question or a brief reflective observation
  that helps them think it through themselves.
- If they explicitly ask you to just tell them the answer, do not comply —
  respond with a further guiding question instead.
- Keep it to 1-3 sentences. No preamble.
```

This is a strong constraint on behavior, not a perfect guarantee — a
sufficiently adversarial user could still try to prompt a model off-script.
The `max_tokens` structural backstop below, not prompt wording, is what
actually bounds worst-case behavior.

**Prompt body**: the section's question/scenario/snippet (whichever fields
that section kind has), the prior thread rendered as `You: .../Them: ...`
(mirroring `#answer_follow_up`'s construction), and the new message.

## Structural backstop: a tight, call-specific `max_tokens`

Neither provider today supports a per-call token ceiling override:
`ClaudeService::MAX_TOKENS` is a fixed 16,000-token constant sized for full
review generation, and `GeminiService#call` sends no cap at all. This
feature needs its own, much tighter ceiling — small enough that a complete
corrected solution genuinely cannot fit, regardless of what the model
attempts — which means threading an optional override through the call
chain:

- `AiService#call_and_log(user, purpose:, system:, prompt:, cache_system: false, max_tokens: nil)`
  passes `max_tokens:` through to `#call`.
- `ClaudeService#call(system:, prompt:, cache_system: false, max_tokens: nil)`
  sends `max_tokens: max_tokens || MAX_TOKENS` in the request body — existing
  callers (which never pass `max_tokens:`) are unaffected.
- `GeminiService#call(system:, prompt:, cache_system: false, max_tokens: nil)`
  includes an output-token cap field in the request body only when
  `max_tokens` is given; existing callers still send none.
- `FakeService#call` gains the same keyword (ignored, like its handling of
  `cache_system` details it doesn't need).

`#duck_response` defines its own constant, `AiService::DUCK_RESPONSE_MAX_TOKENS
= 150`, and passes it explicitly — 150 tokens comfortably fits 1-3 sentences
of prose while remaining far too small for a full corrected solution. This
constant is deliberately distinct from `ClaudeService::MAX_TOKENS` and
doubles as this feature's primary cost control.

## Cap on exchanges

`MAX_DUCK_TURNS_PER_SECTION = 6` (a plain `AiService` or controller-level
constant now — there is no `DailyResponse`-owned cap to share with a view
partial the way `MAX_FOLLOW_UPS_PER_SECTION` is). Double the follow-up cap:
a follow-up is one clarifying question about an already-finished review; a
duck thread supports an actual back-and-forth while actively stuck, so it
warrants more room than a single-shot clarification.

Enforced as a single advisory check against the **incoming thread array's**
user-turn count: reject (422) if `thread.count { |t| t[:role] == "user" } >=
MAX_DUCK_TURNS_PER_SECTION`. As stated above, this is a soft, request-level
check appropriate to the trust model here (per-user API key, self-limiting
cost), not a hardened boundary — there is no server-side state to make it
one. At the cap, the endpoint returns 422 with a clear message; the UI
disables the input and shows that message. Since the thread lives only in
the browser, hitting Clear always resets the count to zero.

## Endpoint & controller

New collection route (no `:id` needed — nothing to look up by id):

```ruby
resources :responses, only: [:create] do
  member do
    # ...existing member routes...
  end
  post :duck_thread, on: :collection
end
```

`ResponsesController#duck_thread`:

1. Look up today's exercise (`current_user.daily_exercises.for_date.first`);
   404 if none.
2. Validate `section` against `exercise.problem_set.keys` (same guard as
   `require_reviewed_section!` uses for `ReviewFollowUp`, to block a crafted
   param from requesting context for an arbitrary section key).
3. Read-only lookup: `current_user.daily_responses.find_by(daily_exercise:,
   date: Date.current)`; reject (422) if present and `submitted?`.
4. Cap check against the incoming `thread` param's user-turn count (422 if
   at/over cap, without calling the provider).
5. Call `AiService#duck_response` with the message, the section's
   question/scenario/snippet pulled from the exercise, and the thread.
6. Render `{ status: "ok", answer: }`. No `remaining` count from the server
   — the client already holds the full thread and computes it locally.

No database writes occur anywhere in this action. Ownership is inherited
from `current_user.daily_exercises`/`current_user.daily_responses` scoping
— there is no id param to leak another user's row through.

## UI

In `app/views/dashboard/_exercise.html.erb`, under each section's answer
textarea (code_review, pattern, and whichever third section is present), a
"🦆 Stuck? Talk it through" box: a turn list, a text input, a send button,
and a Clear button — collapsed/lightweight by default so it doesn't compete
visually with the primary answer flow. Wired by the same
inline-script-per-partial pattern the follow-ups box already uses (see
`shared/_ai_review.html.erb`), with state now living entirely in the script
instance rather than round-tripping through the DOM/server:

- An in-memory array of `{ role, content }` per section instance.
- Send: appends the user's message locally, POSTs `{ section, message,
  thread }` (the array *before* appending the new message), appends the
  returned answer as an assistant turn on success, and disables the input
  once the local array's user-turn count reaches the cap.
- Clear: empties the array and the rendered turn list, and re-enables the
  input if it had been capped.

## Non-goals / explicit exclusions

- No AI grading of any kind — conversational support only.
- No changes to `ReviewFollowUp`, `self_explanation`, or any other
  post-review feature.
- No changes to submission gating, rating requirements, or
  `ConceptMastery`/concept-tagging.
- No read-only view of a duck thread after submission — true by
  construction (nothing persisted survives a reload).
- No migration, no new table, no new model.

## Testing

- **Service spec**: the Socratic system prompt string contains the
  never-give-the-answer constraints; `DUCK_RESPONSE_MAX_TOKENS` (150) is
  passed for this call specifically, asserted distinct from other
  `AiService` calls' token ceilings.
- **Request spec** (`spec/requests/responses_duck_thread_spec.rb`):
  - Available pre-submission (no response row yet, and a response row that
    exists but isn't submitted); returns 422 once a response with
    `submitted_at` present exists for today.
  - Cap enforcement returns 422 without calling the provider when the
    submitted thread array's user-turn count is already at
    `MAX_DUCK_TURNS_PER_SECTION`.
  - 422 for a section key not present in today's `problem_set`.
  - Scoped to `current_user` — no id param exists to probe another user's
    data through.
  - Confirms no database writes occur anywhere in the flow (e.g. asserting
    row counts are unchanged across the request for every table this
    feature could plausibly have touched).

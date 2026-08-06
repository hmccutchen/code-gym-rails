# Rubber-Duck Socratic Thinking Partner

**Date:** 2026-08-06
**Status:** Approved

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
prompt and the user's current in-progress answer as context. Purely
conversational support — no grading, no effect on ratings, concept tags, or
`ConceptMastery`.

This mirrors `ReviewFollowUp`'s proven structural pattern (table shape, cap
enforcement, synchronous fetch + inline-script append) but is a **separate,
distinct table and context**, not a reuse — confirmed explicitly, since the
two features have different availability windows and different content.

## Data model: `duck_threads`, a new table

```ruby
create_table :duck_threads do |t|
  t.references :daily_response, null: false, foreign_key: true
  t.string  :section, null: false
  t.integer :role,    null: false
  t.text    :content, null: false
  t.timestamps
end
add_index :duck_threads, [:daily_response_id, :section, :created_at],
          name: "index_duck_threads_on_response_section_created"
```

`app/models/duck_thread.rb` mirrors `ReviewFollowUp` exactly:

```ruby
class DuckThread < ApplicationRecord
  belongs_to :daily_response

  enum :role, { user: 0, assistant: 1 }, prefix: true

  validates :section, :content, presence: true

  scope :for_section, ->(section) { where(section: section).order(:created_at, :id) }
end
```

The `:id` tiebreaker exists for the same reason as `ReviewFollowUp`: a
question/answer pair is written in one transaction, microseconds apart, and
Postgres timestamp precision can collide — `created_at` alone could then
render the answer above its question.

`DailyResponse` gains `has_many :duck_threads, dependent: :destroy`. Rows are
preserved through `User#anonymize!` (which never destroys `DailyResponse` or
its associations) and are destroyed along with the response by
`ResponsesController#start_over`, matching how in-progress answers and
ratings are already treated by that action — scrapping today's attempt
scraps its duck conversation too.

`User` and `DailyResponse` need no other changes; ownership scoping is
inherited transitively through `daily_response.user`, same as
`ReviewFollowUp`.

## Availability

**Gate:** available only while `daily_response.submitted_at` is blank.
Submission is still whole-response — one `ResponsesController#create` call
with `submit: "1"` sets `submitted_at` for every section at once (confirmed
against current code; unchanged by this feature).

**Response record timing:** the pre-submission dashboard can render an
*unpersisted* `DailyResponse` — `DashboardController#show` falls back to
`DailyResponse.new(...)` when no row exists yet, and the first real row is
normally created by the answer textarea's debounced autosave (800ms after
the first keystroke). A user could open the duck-thread box and send a
message before that autosave has ever fired. Rather than requiring a
persisted response up front, the duck-thread endpoint takes no `:id` and
performs the same `find_or_initialize_by(daily_exercise:, date:)` +
`save!` that `ResponsesController#create` already does — so the very first
duck message can create today's response row on the spot, with no
dependency on answer-textarea state.

**After submission:** the duck thread simply stops rendering — no read-only
view is added anywhere. It is scratch, in-the-moment thinking, not a record
worth preserving in the UI (unlike a completed review, which is the whole
point of `/history`). Concretely: the duck-thread box lives only inside
`_exercise.html.erb`'s unsubmitted branch; once a response is submitted,
that whole branch is replaced by `_answered_sections`/`_submission`, which
never queries `DuckThread`. Rows stay in the database untouched (nothing
destroys them on submit) but nothing surfaces them again. The controller
action also rejects (422) if `@response.submitted?`, as defense in depth
against a stale tab posting after another tab or device has already
submitted.

## Context passed to the AI

- The section's own question/scenario/snippet fields (whichever the section
  kind has — `ExerciseSection` already knows this shape).
- The user's **current in-progress answer text** for that section, sent by
  the client as the live DOM value of that section's textarea at send-time
  (not `daily_response.answers[section]`, which only reflects the last
  debounced autosave — see "Endpoint & controller" below — and not a
  completed review, since none exists pre-submission).
- The prior duck-thread turns for that section, in order, for multi-turn
  continuity — same `{ role:, content: }` shape `#answer_follow_up` already
  uses for `ReviewFollowUp` threads.

## `AiService#duck_response`

Same shape as `#answer_follow_up`:

```ruby
def duck_response(user, exercise, daily_response, section:, message:, thread: [])
```

Returns a plain string (no JSON parsing — same reasoning as
`explain_differently`/`answer_follow_up`: there's no structure to parse).
Logged via `call_and_log` with `purpose: "duck_thread"` (added to
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
The structural backstop below, not prompt wording, is what actually bounds
worst-case behavior.

**Prompt body** mirrors `#answer_follow_up`'s construction: the section's
question, the user's current answer, the prior thread rendered as
`You: .../Them: ...`, and the new message.

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

`#duck_response` defines its own constant, `DUCK_RESPONSE_MAX_TOKENS = 150`,
and passes it explicitly — 150 tokens comfortably fits 1-3 sentences of
prose while remaining far too small for a full corrected solution. This
constant is deliberately distinct from `ClaudeService::MAX_TOKENS` and
doubles as this feature's primary cost control.

## Cap on exchanges

`DailyResponse::MAX_DUCK_TURNS_PER_SECTION = 6` — double
`MAX_FOLLOW_UPS_PER_SECTION` (3). A follow-up is one clarifying question
about an already-finished review; a duck thread is meant to support an
actual back-and-forth while actively stuck, so it warrants more room than a
single-shot clarification.

Enforced the same way as `#follow_ups`: an advisory pre-check before the
(slow) provider call, then a re-check inside `@response.with_lock` before
writing — closing the race where two concurrent requests both read under
the cap and both reach the write. The provider call itself stays outside the
lock. At the cap, the endpoint returns 422 with a clear message; the UI
disables the input and shows that message rather than hiding the box
silently.

## Endpoint & controller

New collection route (no `:id` — see "Response record timing" above):

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
2. `find_or_initialize_by(daily_exercise:, date: Date.current)` on
   `current_user.daily_responses`, matching `#create`'s idempotent pattern.
3. Reject (422) if `@response.submitted?`.
4. Validate `section` against `exercise.problem_set.keys` (same guard as
   `require_reviewed_section!` uses for `ReviewFollowUp`, to block a crafted
   param from writing an arbitrary section key).
5. Advisory cap check (`asked >= MAX_DUCK_TURNS_PER_SECTION`).
6. `@response.save!` if new, then call `AiService#duck_response` with the
   message, the section's current answer text, and the prior thread. The
   answer text comes from a request param (`current_answer`) carrying the
   textarea's live DOM value at send-time — not `@response.answers[section]`,
   which reflects only the last debounced autosave and can lag behind what
   the user has actually typed by up to 800ms.
7. `@response.with_lock` re-check + `duck_threads.create!` for both the
   user and assistant turns, same shape as `#follow_ups`.
8. Render `{ status: "ok", answer:, remaining: }` or the capped/error JSON.

Ownership is inherited from `current_user.daily_exercises`/
`current_user.daily_responses` scoping — there is no id param to leak
another user's row through.

## UI

In `app/views/dashboard/_exercise.html.erb`, under each section's answer
textarea (code_review, pattern, and whichever third section is present), a
"🦆 Stuck? Talk it through" box: a turn list, a text input, and a send
button — collapsed/lightweight by default so it doesn't compete visually
with the primary answer flow. Wired by the same inline-script-per-partial
pattern the follow-ups box already uses (see `shared/_ai_review.html.erb`):
fetch on click/Enter, append the returned turn pair, disable input at the
cap and show the capped message. The request body carries `section` and the
**live current value of that section's textarea**, read from the DOM at
send-time (not a previously-saved value), since the point of the feature is
reacting to what the user is thinking right now.

## Non-goals / explicit exclusions

- No AI grading of any kind — conversational support only.
- No changes to `ReviewFollowUp`, `self_explanation`, or any other
  post-review feature.
- No changes to submission gating, rating requirements, or
  `ConceptMastery`/concept-tagging.
- No read-only view of a duck thread after submission (see Availability).

## Testing

- **Model spec** (`spec/models/duck_thread_spec.rb`): cap-adjacent
  validations, `for_section` ordering tiebreaker, ownership via
  `daily_response.user`.
- **Service spec**: the Socratic system prompt string contains the
  never-give-the-answer constraints; `DUCK_RESPONSE_MAX_TOKENS` (150) is
  passed for this call specifically, asserted distinct from other
  `AiService` calls' token ceilings.
- **Request spec** (`spec/requests/responses_duck_thread_spec.rb`):
  - Creates today's `DailyResponse` on the first message when none exists
    yet.
  - Available pre-submission; returns 422 once `submitted_at` is set.
  - Cap enforcement returns 422 without calling the provider once
    `MAX_DUCK_TURNS_PER_SECTION` is reached.
  - 422 for a section key not present in today's `problem_set`.
  - Scoped to `current_user` — no id param exists to probe another user's
    response through.

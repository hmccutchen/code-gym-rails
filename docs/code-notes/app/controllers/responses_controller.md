# app/controllers/responses_controller.rb

## Finding the set

`#create`, `#load_duck_section` (the duck send and Clear) and `#load_pseudocode_context` find their set through `CurrentSetLookup#current_set`, and answer `#render_set_not_current` when it finds none: `errors.set_not_current` with a 404, never a bare `head :not_found`. `#start_over` calls `#carry_held_set_forward_if_named` before `DailyExercise#start_over!`. Under `HELD_SET_LOOKUP` it moves the held set to today only when that set is the response's own (`User#carry_held_set_forward!(only:)`), so a held set's response is dated today before the model's not-today check. Start over on an older stray set moves nothing, and the not-today check still refuses it. The `A held set stays current` entry in `.claude/rules/answers.md` states the rule.

## `MAX_DUCK_TURNS_PER_SECTION`

Double `DailyResponse::MAX_FOLLOW_UPS_PER_SECTION`, because a duck thread is a
real back-and-forth. The view partial reads the value from this constant.

## `MAX_DUCK_MESSAGE_LENGTH`

Bounds every new turn. Earlier turns come from the stored thread, never the
request, so nothing else a page posts needs a size limit.

## `MAX_DUCK_THREAD_BYTES`

Derived from the caps rather than set as a flat number. A flat byte limit
rejected honest threads written in multi-byte characters, and it fell behind
when the reply token cap was raised.

## `#explain_differently`

Synchronous: the caller uses the shared request module and appends the reply
in place.

## `#explain_differently` and `#follow_ups`

The check before the provider call only saves a paid call that would be
refused anyway. `DailyResponse#append_alternate!` and `#append_follow_up!`
check the cap again under the row lock, and the action only maps what they
return (`#capped_outcome`).

## `#follow_ups`

The reply returns the cleaned question, so the transcript never claims an
answer to text the provider never saw.

## `#duck_thread`

A missing exercise still gets a JSON body, because the client calls
`res.json()` before it checks `res.ok`.

The provider is called with the stored thread, and the exchange is stored
only after the reply, under `DuckThread.append!`'s checks.

## `DuckAnswer` and the trial logs

`#duck_thread` hands the call to `DuckAnswer.ask`, which reads the switch
itself, and stores `#text` and `#point` through `DuckThread.append!`. It
calls `#log_stored` only when `DuckThread.stored?` says the write landed, so
a reply dropped
as `:stale`, `:deleted` or `:submitted` writes no trial log line. The gate,
the history and the log lines are described in
`docs/code-notes/app/services/duck_answer.md`.

## `#stale_page_scope?`

A page names the set it shows by its draft scope. A tab loaded before a
regeneration, or left open since yesterday, still reads version 0 for a
section, which would match the current set's empty thread: the duck would be
asked about one problem and answer against another, and its Clear would erase
the current set's thread. So both duck actions refuse a scope that isn't today's
set before the provider call or any write, with the same 409 text a stale
autosave gets. A page loaded before threads were stored sends no scope at
all, so it gets the same refusal, and its reload loads the new script.

The pseudocode critique uses the same check, through `#stale_page_refusal`,
which answers the way a stale autosave does: 409, `status: "stale"`, and
under `STALE_SET_BANNER` the `banner:` from `#stale_set_banner`. Under
`HELD_SET_LOOKUP` a paused user can have generated a newer set after opening
an older one, and `#current_set` then carries the newer one forward; without
this check the older page's plan would be sent to the provider and would use
up the newer set's single critique.

## `#stored_thread_refusal`

The byte check runs on the stored thread, because assistant turns in it are
provider output. A page whose version is behind is refused before this, with
the refresh text, since its reply would only be refused after it was paid
for.

## `#duck_outcome`

Maps `DuckThread`'s named outcomes to replies. `:submitted` gets the
after-submit text; a moved version, a regenerated set and a deleted account
all get the 409 refresh text, because reloading is what brings the page level
with the server.

## `#clear_duck_thread`

Refused once the day is submitted, so a kept thread can't be erased from a
stale page.

## `#load_duck_section` and `#load_duck_turn`

Each renders its own refusal and returns nil, so the actions guard on the
result. `#duck_refusal` returns nil explicitly, because a render returns a
truthy value and would let the action carry on.

## `#pseudocode_critique`

Round 1: one text-only critique of the engineer's plan. The claim, the write
and the release are `DailyResponse`'s (`#claim_pseudocode_critique!`), and
the action keeps only the token. The posted scope is checked twice: before the
response is created (`#stale_page_scope?`), and again under the locks where
the claim is taken, since a regeneration or a start over can land between the
two; a `:stale` refusal from the claim gets the same 409. A critique whose claim went stale and was
taken over is still shown to the engineer, since it was paid for, but it is
not stored: the newer call's result is the one the round keeps, so a reload
can show a different critique from the one first shown. If the newer call
fails instead, its release leaves the round open and a new check is allowed.

## `#stale_answer_sections`

Parsons tokens that can't be read mean the set was replaced. The whole post is
refused with a 409 rather than saved in part.

## `#stale_draft_scope?`

Under `STALE_SET_BANNER` the 409 also carries `banner:`, the sentence the
freshness reply would give (`CurrentSetLookup#stale_set_banner`:
`dashboard.stale_set.replaced` when the posted scope names an earlier write
of this row, `dashboard.stale_set.newer` otherwise), so the page's banner
shows the server's words. Its `status` stays `stale`, so `code_gym/request`
raises no not-current event for it. With the switch off the reply is
unchanged.


Runs under the exercise lock, after `lock!` has re-read the row, so a
regeneration cannot land between the check and the save. A partial autosave that names no
scope retains its legacy behavior. A new submission must carry the exact
current scope and manifest revision; this compatibility path cannot submit
an unseen addition.

## `#save_answers_under_lock`

Takes both locks through `DailyExercise#with_response_locked`, which yields
the exercise's one response, or nil when there is none yet, in which case
it is found or created, then locked.

When the account was deleted between sign-in and the lock, the exercise is
gone and the lock raises `RecordNotFound`. The method returns `:deleted` for
that, only when the user row is gone too, and `#create` answers it the way
`require_login` answers a signed-out request: a redirect to the login page.

A refused submit raises `ActiveRecord::Rollback` instead of returning
`:failed` early. `#persisted_response_for` has already created the row by
then, and returning early would commit it. The rollback makes the transaction
return `nil`, which the trailing `|| :failed` turns into the failure outcome
`#create` renders as a 422.

## `#load_pseudocode_context`

The section key comes from the registry, never from params. On failure the
method renders its own error and returns nil, so callers guard on its result.

## `#open_response_for`

Uses a persisted row, because the round's row lock needs a real row. It runs
only after the request has passed validation.

## `#persisted_response_for`

Rescues both `RecordInvalid` and `RecordNotUnique`, since the model validation
and the unique index both guard uniqueness. The create runs inside a
SAVEPOINT because `#create` already wraps it in a transaction.

## `#pseudocode_error`

Returns nil because callers read a falsy value as "already handled", and
`render_section_error` returns a truthy one.

## `#require_reviewed_section!`

The section is checked against the problem set. Without that, a crafted param
could write arbitrary keys into the jsonb columns.

## `#review_failure_text`

A fan-out usually fails every section the same way. When it doesn't, the most
common failure kind is the one worth explaining.

## `#exercise_concept_tags`

Reads `active_section_keys`, never `ExerciseSection.keys`, so a section the
engineer never saw neither enters concept history nor bills a reference.

## `#enqueue_concept_references`

The `exists?` check only skips obvious no-ops. The job checks again, so a
duplicate enqueue from a race is harmless.

## Submission and Add coordination

A new submit tries expired-addition recovery before taking row locks, then
checks scope, `DailyExercise#addition_pending?` and manifest revision under
`with_response_locked` before assigning any request data. Busy or unseen-card
refusals write nothing and return distinct conflict outcomes. The browser
refreshes missing cards while retaining drafts. Already-submitted retries
remain idempotent and do not reapply the new payload.

Partial autosaves merge the submitted keys into the current locked response.
An old tab that lacks an added section therefore cannot erase its saved answer
or rating. Start over also attempts recovery before its model operation;
`DailyExercise#start_over!` rechecks pending additions under the destructive
operation's locks. Recovery never substitutes for the locked refusal checks.

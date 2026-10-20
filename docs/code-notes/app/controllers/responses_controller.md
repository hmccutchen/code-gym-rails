# app/controllers/responses_controller.rb

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

Synchronous: the caller posts through `fetch` and appends the reply in place.

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

## `#stale_duck_page?`

A page names the set it shows by its draft scope. A tab loaded before a
regeneration, or left open since yesterday, still reads version 0 for a
section, which would match the current set's empty thread: the duck would be
asked about one problem and answer against another, and its Clear would erase
the current set's thread. So both actions refuse a scope that isn't today's
set before the provider call or any write, with the same 409 text a stale
autosave gets. A page loaded before threads were stored sends no scope at
all, so it gets the same refusal, and its reload loads the new script.

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

Round 1: one text-only critique of the engineer's plan.

## `#stale_answer_sections`

Parsons tokens that can't be read mean the set was replaced. The whole post is
refused with a 409 rather than saved in part.

## `#stale_draft_scope?`

Runs under the exercise lock, after `lock!` has re-read the row, so a
regeneration cannot land between the check and the save. A post that names no
scope still saves, so a page loaded before the scope existed keeps working.

## `#save_answers_under_lock`

Takes both locks through `DailyExercise#with_response_locked`, which yields
the exercise's one response, or nil when there is none yet, in which case
it is found or created, then locked.

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

## `#claim_pseudocode_round!`

Claims the round before the provider call, so a cap on a paid call also bounds
the spend. The claim expires the way `#review`'s claim does.

## `#write_pseudocode_round!`

Writing the result also releases the claim, so the two can never disagree.

## `#release_pseudocode_claim!`

After a handled provider failure, the round is handed back so the engineer can
retry without waiting out the stale window.

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

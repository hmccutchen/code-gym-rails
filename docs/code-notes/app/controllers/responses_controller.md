# app/controllers/responses_controller.rb

## Routes

Two member routes have no path comment in the source, because the file's five
comments go to the less derivable routes:

- `POST /responses/:id/email_review` → `#email_review`
- `POST /responses/:id/follow_ups` → `#follow_ups`

## `MAX_DUCK_TURNS_PER_SECTION`

Double `DailyResponse::MAX_FOLLOW_UPS_PER_SECTION`, because a duck thread is a
real back-and-forth. The view partial reads the value from this constant.

## `MAX_DUCK_MESSAGE_LENGTH` and `MAX_DUCK_THREAD_ENTRIES`

The client holds the thread, so an attacker can make it any size, and the turn
cap counts only user turns. These two limits bound what is forwarded to the
provider.

## `MAX_DUCK_THREAD_BYTES`

Derived from the caps rather than set as a flat number. A flat byte limit
rejected honest threads written in multi-byte characters, and it fell behind
when the reply token cap was raised.

## `#review`

The missing sections are counted again after the claim reloads the row:
another request may have finished the last section between the first check
and the claim.

The response is locked before the results are written, because `#start_over`
or `RegenerateExerciseJob` can destroy the row during the provider call.

## `#explain_differently`

Synchronous: the caller posts through `fetch` and appends the reply in place.

## `#explain_differently` and `#follow_ups`

The count check before the provider call is advisory. The re-check under the
row lock is what keeps concurrent requests under the cap.

## `#follow_ups`

Both turns, the question and the answer, are written under the same lock, so
no question is stored without its answer.

The reply returns the cleaned question, so the transcript never claims an
answer to text the provider never saw.

## `#duck_thread`

A missing exercise still gets a JSON body, because the client calls
`res.json()` before it checks `res.ok`.

## `#pseudocode_critique`

Round 1: one text-only critique of the engineer's plan.

## `#stale_answer_sections`

Parsons tokens that can't be read mean the set was replaced. The whole post is
refused with a 409 rather than saved in part.

## `#save_answers_under_lock`

Locks the exercise, then the response: the order `RegenerateExerciseJob`
takes, so the two serialize instead of deadlocking.

## `#duck_thread_param`

Roles are normalized and limited to `user` and `assistant`; the turn cap
matches `"user"` exactly. Blank turns are dropped, because the provider would
answer them with a 400.

It maps at most one entry past `MAX_DUCK_THREAD_ENTRIES`. That bounds the work
while still leaving an over-limit thread detectably over the limit.

## `#well_formed_thread?`

Turns must alternate and end on an assistant reply. The page script always
sends that shape, so any other shape was written by hand.

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

## `#claim_review!`

One `UPDATE ... WHERE` claims the row atomically, so a second click backs off
instead of making a second provider call.

## `#clear_stale_generation_error!`

A reviewed day can't be regenerated, so an earlier regeneration error would
otherwise ask for a retry that is impossible.

## `#log_review_diagnostics`

Pairs the AI and self ratings per section, to read beside
`AiService#log_difficulty_diagnostics`. Remove it once that question is
settled.

It logs `daily_exercise.date` rather than `response.date`, because the
response's date can fall a day after the generation event it correlates with.

## `#log_pseudocode_review_diagnostics`

The counterpart to `AiService#log_pseudocode_critique`. It logs counts and
flags only, never pseudocode or critique text.

## `#graded_missed`

The prose judge may have merged the stored missed points, so this reads the
grader's originals under `graded_prose` when they exist.

## `#review_failure_text`

A fan-out usually fails every section the same way. When it doesn't, the most
common failure kind is the one worth explaining.

## `#stored_review_failure`

Uses the section's own failure time, since the review as a whole waits for its
slowest section.

## `#exercise_concept_tags`

Reads `active_section_keys`, never `ExerciseSection.keys`, so a section the
engineer never saw neither enters concept history nor bills a reference.

## `#enqueue_concept_references`

The `exists?` check only skips obvious no-ops. The job checks again, so a
duplicate enqueue from a race is harmless.

# app/controllers/learn_controller.rb

## Prepare actions

The prepare actions have no hourly limit (`docs/decisions/per-user-request-limits.md`
says why it was removed in #792). A press is paid for with the account's own
key; a trial account is refused before anything is queued
(`User#writes_learn_content?`).

## `#writes_learn_content?`

The private `#writes_learn_content?` asks `User#writes_learn_content?` the
first time a request needs it and keeps the answer, so one page never asks
the trial question twice (#790). The actions call it, and the `learn/index`
and `learn/show` views reach it through `helper_method`. It guards the memo
with `defined?`, because a trial account's answer is `false` and `||=` would
ask again. `#status` never calls it, since a poll never needs it.

It replaced a `before_action` that set an instance variable for every
action but `#status`. An action added later and left out of that hook would
have read `nil`, which looks like a trial account, so it would have refused
the user without any error. Asking on demand has no list of actions to keep
in step.

## `#bulk`

One press of `#prepare` or `#prepare_ladders` can queue about 90 jobs on
`provider_calls`, the queue the day's sets run on. At the default priority 0
they ran ahead of a dashboard click made after the press and ahead of every
scheduled set. The bulk enqueues run at `JobPriority::BACKGROUND`: the
press's write-ups through `GenerateConceptReferenceJob.queue_missing`, the
way a saved set queues its own, its ladders through
`GenerateConceptReferenceJob.queue_rewrites`, and its guides through
`#bulk`, so a click (`JobPriority::CLICK`) and every
scheduled set (`JobPriority::SCHEDULED`) run first, even a set enqueued
after the press. Nobody is waiting on any one job of a press.
`#prepare_concept` sets no priority, because its page polls for that one
write-up, and neither does the write-up
`ResponsesController#enqueue_concept_references` queues for a concept just
submitted. A click for a concept a press already queued still gets its own
job; `GenerateConceptReferenceJob`'s claim, and the version each rewrite
was asked against, keep the two to one call.
`job_priority_spec` holds the ordering, whatever the numbers are.

## `AWAITING`

The page tells the status endpoint which check it is waiting on, because the
row alone can't say: once a guide lands, a row looks like a ladder candidate.
When the page sends nothing, the endpoint waits on the guide.

## `#status`

The page polls instead of waiting on a fixed timeout, because no timeout can
guess how long a provider call with thinking on will take.

## `#prepare_concept`

Answers JSON for the page's script. It queues the job through
`GenerateConceptReferenceJob.queue_rewrites`, with `refresh: true` and the
version of the row the user sees. The guide and lesson presses ask for a
rewrite of the whole row. The ladder press also passes `part: "ladder"`
(`#ladder_part`), so the job writes only the ladder and keeps the text above
it.

It clears any earlier failure note before queueing. Otherwise that old note
would answer this attempt's first poll before the job had run.

## `#prepare`

Pressing it twice is safe: each job re-checks whether its row exists, so a
second press enqueues only what is still missing.

## `#ladder_part`

Passes the ladder part on only when the request names it exactly. Any other
value queues the whole-row rewrite, as a press with no part does.

## `#ladder_targets_for`

An empty list means the page offers no ladder, either because a ladder would
ground nothing for this user or because the row is not
`ConceptReference#ladder_addable?`. That is the predicate the job's
ladder-only write checks, so an offered press never turns into a whole-row
rewrite.

## `#references_by_key`

Loads every renderable reference in one query. Calling the per-concept finder
instead would run one query per concept.

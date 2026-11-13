# app/controllers/learn_controller.rb

## `PREPARE_PER_HOUR`

The limit counts presses, not jobs. Each press queues one billed job per
missing concept, so a single press can cost many provider calls. It skips
an account with a key of its own (`unless: :own_key?`), and since L2 of
`docs/decisions/learn-content-per-user.md` the accounts left, trials on the
house key, are refused before anything is queued. So it holds back no queued
work today.

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
`GenerateConceptReferenceJob.queue_rewrites`, with `refresh: true`, which
permits a rewrite of the whole row, and the version of the row the user sees.

It clears any earlier failure note before queueing. Otherwise that old note
would answer this attempt's first poll before the job had run.

## `#prepare`

Pressing it twice is safe: each job re-checks whether its row exists, so a
second press enqueues only what is still missing.

## `#ladder_targets_for`

An empty list means the page offers no rewrite, because a ladder would ground
nothing for this user.

## `#references_by_key`

Loads every renderable reference in one query. Calling the per-concept finder
instead would run one query per concept.

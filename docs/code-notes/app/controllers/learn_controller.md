# app/controllers/learn_controller.rb

## `PREPARE_PER_HOUR`

The limit counts presses, not jobs. Each press queues one billed job per
missing concept, so a single press can cost many provider calls.

## `AWAITING`

The page tells the status endpoint which check it is waiting on, because the
row alone can't say: once a guide lands, a row looks like a ladder candidate.
When the page sends nothing, the endpoint waits on the guide.

## `#status`

The page polls instead of waiting on a fixed timeout, because no timeout can
guess how long a provider call with thinking on will take.

## `#prepare_concept`

Answers JSON for the page's script. It queues the job with `refresh: true`,
which permits a rewrite of the whole row.

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

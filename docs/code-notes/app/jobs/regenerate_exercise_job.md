# app/jobs/regenerate_exercise_job.rb

## `#regenerate`

`PracticeGeneration` checks mode/settings and the original token under
user, exercise and response locks before anything is written. A
superseded or blocked set writes nothing, so the transaction ends without a
rollback.

## `#generate`

Every regeneration is judged, as first generation is; a weekend one makes a
`bug_hunt`, which never ships unjudged. It runs under the deadline measured from the claim,
so a slow queue pickup comes out of the same budget instead of extending how
long the claim must stay fresh.

## `KEPT_SET_MESSAGES`

A review still running can fail, so the `reviewing` case has its own message
rather than claiming that a review landed.

## `#keep_superseded_set`

It records no error banner: the dashboard's set is intact. The caller
releases only its original token; a retaken claim is untouched. Supersession
can also mean a relevant setting changed during generation.
That settings check applies to inactive users too, so it can discard an
already-billed draft. The old content, draft response, notes and
`regenerated_at` remain unchanged. No automatic paid retry or cadence turn
follows.

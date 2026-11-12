# app/jobs/regenerate_exercise_job.rb

## `#regenerate`

`PracticeGeneration` checks mode/settings and the original token under
user, exercise and response locks before anything is written. A
superseded or blocked set writes nothing, so the transaction ends without a
rollback.

## `#record_provider_failure`

A regeneration notes `User#key_in_use` before the call. A provider or setup
failure is written through `User#report_call_failure` under the user row
lock, which reloads the account, so a failure from a key removed, replaced
or switched during the call is not recorded
(`docs/decisions/per-user-api-keys.md`, "A call that outlives its key").
`#release` has already released the exercise's claim by then, so the user
lock is taken alone. The "set was kept" messages do not go through it.

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

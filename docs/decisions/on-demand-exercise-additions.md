# On-demand exercise additions

Today offers Add exercise before submission. The learner chooses a registered
kind from the same allowed pool used by planning. Existing keys, including
unrendered historical keys, cannot be requested again. Existing fourth-kind
conflicts and the four-active-section limit apply. Add never changes stored
preferences. Submission closes the whole set, and unanswered sections can
be skipped. Today places Add before the single Submit action in normal flow.
See [One finish action](one-finish-action.md) for submission readiness.

## Storage and generation

An accepted request creates one ExerciseAddition with its exercise, UUID,
kind, scope, local date, status and claim timestamp. The PR0 schema already
contains these fields and the unique UUID/exercise and one-active-operation
indexes. No migration or failure-code column is needed: terminal failures
have one safe retry message.

Sections remain in DailyExercise.problem_set. Append seeds a historical
manifest from active_section_keys and appends one key. It preserves earlier
JSON, generated_at, draft_scope, answers, ratings, ducks and learner notes.
Manifest length is the additive revision; reset/replacement change scope.

PracticeGeneration captures the requested kind, scheduling predecessor,
settings, difficulty, manifest, scope, operation token and provider-key
identity. The ordinary one-kind draft, judge, retry, ingest and solve pipeline
runs outside row transactions. A key fingerprint stays in memory and is not
logged or stored in plan notes. Commit validates the capture again before
merging one accepted section and its metadata atomically with success status.
A stale result is discarded without another provider call.

The strict initial schedule-note envelope and automatic sequence remain.
Only the added kind's committed service enters the target's continuation.
Append never rewrites a different exercise that supplied scheduling context.
A target without a note receives the generated continuation, preserving
captured prior service while recording its original active keys and no
reconstructed initial assignments. Historical continuation translation uses
the current planner's reader rules. No separate additions ledger is written:
the continuation is the service record, and no reader needs duplicate
assignment metadata. Existing unknown plan metadata is preserved.
No new schedule format, mastery update or retention-interval change is added.
Existing Bug Hunt trap exclusions apply in both addition directions. Prior
exposure to other practice content is not a semantic spoiler guarantee.

## Lifecycle and locks

The request service, worker and abandoned-operation recovery use the same
exercise-scoped PostgreSQL advisory lock. It is acquired before row locks:
user, exercise, response, addition. The worker retains advisory ownership
through provider work while releasing row transactions, allowing autosave.
Use a direct PostgreSQL connection, as required by the existing advisory-lock
adapter; a transaction-mode connection pooler cannot preserve this guarantee.

Only a queued, never-claimed, unexpired operation can claim execution. Claimable
supplies the token, but stale running claims are never taken over for another
provider attempt. Redelivered jobs cannot repeat that attempt. Writes and
failure cleanup match the token. The partial unique index backs up acceptance
locking, and UUID replay returns the existing operation without changing kind.

Enqueue occurs after commit through a callable supplied by the controller;
services do not reference job classes. Enqueue failure conditionally fails
only the still-unclaimed queued operation. Queued work expires after the
existing pickup margin. Running work uses the existing generation deadline
and write margin. Status reads expose expiry without changing records.

Recovery requires advisory ownership before marking an expired operation
failed. A live worker cannot be overlapped merely because time elapsed.
Explicit Add retry uses a new UUID after recovery; transport retransmission
retains its UUID. Submit, Start over and regeneration also recover abandoned
operations before taking their own row locks and recheck active status under
the exercise lock. There is no automatic job-level provider retry.

One successful append per operation is guaranteed. Exactly-once external
billing is not: after a worker dies following an accepted provider request,
an explicit learner retry may buy another attempt. Existing provider/judge
budgets and deadlines bound each accepted attempt.

## Current sets and browser state

The worker targets an exact addition and captured local date. Rollover, held
movement, changed scope/manifest/settings/key/predecessor, submission or account
deletion prevent stale append. Already committed additions travel with held
sets. Account deletion removes addition rows through existing PR0 associations
and AccountData coverage.

A new submit must include exact draft scope and manifest revision. Existing
submitted retries remain idempotent. Old-tab autosaves remain partial merges
under the same scope, preserving answers to added sections absent from the
request. An active addition blocks submit, reset and regeneration under lock.

The picker reuses Swap presentation with separate actions. It makes one
acceptance request, polls read-only state, and offers explicit recovery. Status
replies render missing cards through existing section helpers. The browser
inserts only absent cards, rescans new controls, and keeps existing inputs,
focus, ratings, folds and duck drafts. A manifest conflict refreshes structure
without clearing drafts or automatically submitting. Submit stays disabled
during an active addition or stale-manifest reconciliation. Readiness uses
the latest applicable server state and any outstanding answer edits. Scope
replacement retains existing stale-page handling. At capacity or after
submission, Add is absent.

## Rollout and verification

PR2 is stacked on PR1 and PR3 is stacked on PR2 by owner approval. Merge and
compatible deployment of PR0/PR1 remain prerequisites for production release. PR0 supplies the manifest
and operation table; PR1 supplies single generation and strict note readers.
Deploy compatible web and worker together after draining older writers as
specified in daily-practice-compatibility.md. An old web process does not know
the addition/submission guard and must not coexist with active Add writers.
No temporary switches or experimental infrastructure are introduced.

Tests use fake providers and isolated PostgreSQL databases. Coverage includes
UUID replay, concurrent acceptance, worker redelivery, expiry under a held
advisory lock, partial autosave during provider work, stale capture rejection,
historical sets, submit/reset/regenerate races, provider call counts, account
deletion, browser reconciliation and mobile keyboard/focus behavior. Independent
critical and layered reviews and full final-commit CI remain merge gates.

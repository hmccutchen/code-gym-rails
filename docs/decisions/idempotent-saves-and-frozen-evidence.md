# Idempotent saves and frozen evidence

`ResponsesController#create`
shares `persisted_response_for` with pseudocode rounds, recovering an
initial-create race through the existing unique date constraint. Every
answer save reloads under the response row lock. Once submitted, answers,
section ratings, concept tags and the submission timestamp are immutable
through this endpoint, including while a review is running or retrying.
Ratings freeze too because they decide mastery alongside the AI grade.
Draft answer merging and submit-only rating pruning both run inside that
lock, before the first submission freezes the record.
Stale autosaves receive a successful acknowledgement with `submitted: true`,
without changing evidence, and the stale form reloads to the submitted
page. Repeated submits return the existing review URL, preserving automatic
review retries. The form's inert state suppresses that reload during submit,
so a late autosave cannot interrupt its review request. Start over and
regeneration retain their existing reviewed/reviewing guards.

**A save names the set it was written for.** The dashboard sends
`DailyExercise#draft_scope` (the exercise id, `generated_at` and any reset revision) with every
save and submit, and `#create` refuses a different one under the exercise
lock with the same `409 "stale"` the Parsons token check gives, writing
nothing. Without it, `#create` writes to whatever set is today's, so a tab
left open overnight, or a save sent after a regenerate in another tab, put
one set's text into the next set: plain text decodes anywhere, and only
structured answers tripped the old check. A carry-forward keeps the scope,
since the set itself does not change. A post with no scope still saves.

**Start over retires the old scope.** `DailyExercise#start_over!` advances
`plan_notes["draft_revision"]` in the same user → exercise → response
transaction that deletes the response and empties the duck thread. It
rechecks the target response id, date and review blocker under those locks.
The existing save-scope check runs after acquiring them too, so an old tab
or an in-flight save cannot recreate the cleared answers. A reloaded page
gets the new scope and saves normally. Generation timestamps and problem
content remain unchanged.

**Malformed reset metadata is not repaired by reset.** A non-Hash
`plan_notes`, including a stored JSON null, makes the scope reader use the
original revision-zero format and log a warning without the notes' contents.
Start over rejects that metadata under the locks before clearing anything.
Its validation error returns the existing redirect-style refusal and leaves
the response, duck thread and notes unchanged. Canonical plan writers produce
Hashes; this narrow scope fallback does not make every historical metadata
shape usable by other readers.

**Upgrade and rollback limitation.** Reset protection requires reset-aware
web writers. Old binaries ignore `draft_revision`, so an old writer during
a mixed-version deployment, or after rollback, can still accept a pre-reset
scope and recreate answers. A local PostgreSQL probe returned 409 with the
upgraded scope reader and 200 with the exact old reader, recreating answers
in the latter case. This was not exercised in production. Existing clients
that omit scope also retain their documented compatibility behavior.

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
`DailyExercise#draft_scope` (the exercise id and `generated_at`) with every
save and submit, and `#create` refuses a different one under the exercise
lock with the same `409 "stale"` the Parsons token check gives, writing
nothing. Without it, `#create` writes to whatever set is today's, so a tab
left open overnight, or a save sent after a regenerate in another tab, put
one set's text into the next set: plain text decodes anywhere, and only
structured answers tripped the old check. A carry-forward keeps the scope,
since the set itself does not change. A post with no scope still saves.

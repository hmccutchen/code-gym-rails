# app/models/learner_extraction.rb

The full decision is `docs/decisions/learner-notes.md`.

## Why the counts live on the set

Whether a set has been read by the extraction call, how many extraction
attempts it has had and how many reply attempts its explanation has had are
kept in `plan_notes["learner_extraction"]` on the day's `DailyExercise`, as
text-free counts and one time. They used to live on the `learner_notes` row,
which kept an emptied row behind as a marker after the engineer deleted a
note, so a later run could not read the set a second time. The owner chose
on 2026-11-18 to delete the row outright, so the counts moved to the set,
which outlives the note.

## Lock order and what it writes

Every change takes the user row share lock, then the exercise row lock, the
order `DailyExercise#with_response_locked` uses, and reads the ledger from
the freshly locked row. It writes back only its own key, merged into the
locked row's `plan_notes`, so generation's notes are never overwritten. A
set deleted before the write answers `:gone`.

## When it starts fresh

Regeneration replaces `plan_notes` wholesale, so a replaced set starts with
no counts, as it starts with no note. Start over keeps the set's other
notes, so `DailyExercise#forget_learner_note!` drops the key with `.clear!`,
which removes it in one statement.

## The reply count

`.count_reply_attempt!` yields under the lock; the block takes the note's
`reply_requested_at` claim and returns its token, or a symbol naming why it
did not. Only a token counts an attempt, so a refused request spends
nothing.

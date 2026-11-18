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

`.count_attempt!` and `.close!` take the response the run was queued for.
Under the same locks they check it is still the set's submitted response,
and answer `:replaced` with nothing written when it is not. Start over drops
the key and takes the user row lock to do it, so without that check a run
that read the old ledger first would recreate the key for the replacement:
counting its attempt, or closing it, before the replacement's own run.

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

## The forgotten time

Delete all cannot tell which set an extraction call is reading, and an
item that cites only a duck turn or an answer would survive the note
checks. So `.forget_all!`, called under the user row lock Delete all
holds, stamps `forgotten_at` on every set the account has, creating the
ledger key on a set that has none yet. A run may read a set before any
ledger exists and only create the key when it counts its attempt; stamping
only existing ledgers would miss that set, and its run would find no stamp
moved and write its items after Delete all. The job
keeps the ledger it read before the call, and its `still_there:` check,
run under the same lock, answers nil when the stamp moved since. The stamp
is written to the microsecond (`iso8601(6)`), since the job only compares
it for equality: a stamp to the second let a second Delete all in the same
second leave it unchanged, and a run that read the first stamp then wrote
its duck-only items. The stamp is a time, with no text, so keeping it keeps nothing the engineer asked to
have deleted (owner's decision, 2026-11-18).

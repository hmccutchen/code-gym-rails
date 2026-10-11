# app/models/concerns/claimable.rb

A claim is a timestamp column used as a lease on a paid provider call: a
review on `DailyResponse#reviewing_since`, a regeneration on
`DailyExercise#regenerating_since`. Each model states its column and how long
a claim stays fresh, and this concern defines `#claim_<name>!`,
`#release_<name>!` and `#<name>?` from that one statement, so the predicate
and the claim query can't disagree about when a claim has gone stale.

## `#take_claim`

One `UPDATE ... WHERE` takes the claim, so two clicks or a click and a worker
can't both win. Extra conditions narrow it further: regeneration passes
`regenerated_at: nil`, the once-a-day gate.

The token is the timestamp written, rounded to microseconds, the precision
Postgres stores. SQL comparisons would match either way, but a token compared
in Ruby with a value read back from the database, such as a worker's claim
against the row it reloads, only equals it once both are rounded the same.

## `#release_claim`

Clears the claim only while it still holds the caller's token. A call that
overran the window may find its claim taken over, and clearing that would
let a third call start while the second is still running.

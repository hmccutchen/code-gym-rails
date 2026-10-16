# app/models/duck_thread.rb

The decision behind this model is `docs/decisions/the-duck-thread-is-stored.md`.

## `.for`

Returns the day's row, or an unsaved one when there is none, so a read never
writes. The dashboard reads through `DailyExercise#duck_thread`, which caches
the row across the sections it renders.

## `.append!`

Called after the provider replies, never around it, so no lock is held during
the call. It takes `DailyExercise#with_response_locked` and then the row lock,
in that order, the order every other writer to an exercise and its response
uses. Under them it refuses the reply when the day was submitted, when the set
was regenerated (the committed scope differs from the one the turn was read
under), or when the section's version moved. The caller passes the version of
the thread it sent the provider, not the page's number, so a stored reply
always continues the history the duck actually saw.

## `.clear!`

Always moves the version, so a reply on its way is refused even when the
section held nothing yet, which is the usual state while a first reply is
slow. It creates the row if there is none for the same reason. It counts a
clear only when there were turns to clear.

## `.row_for`

Creates the row on the first write. Both writers hold the exercise lock, so
two first writes don't race; the unique index and the rescue are there for
any writer that doesn't, and the loser reads the winner's row, as
`ResponsesController#persisted_response_for` does.

## `.write`

`with_lock` reloads the row, so the scope check and the version check read
what is committed. A row stamped with another draft scope belongs to a set
that has since been regenerated, and starts over empty.

## `#turns_for`

Builds each turn from `role` and `content` only. The page's turns value and
the duck's history both come from here, so anything else stored in an entry,
such as `cleared`, can't reach either.

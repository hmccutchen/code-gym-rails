# app/models/level_change.rb

## One transaction, explicit order

`ProfileUpdate` captures this object under the user lock before assignment.
It holds the stored levels, baseline and cutoffs. The form then assigns and
validates the posted fields, records cutoffs, saves, and writes events in
one transaction. A failed event insert rolls back both settings and cutoffs.
There are no level callbacks on `User`.

Track changes preserve every target and lock. The old target-clearing step
and its special event-source override have been removed.

## Cutoffs and events describe actual movement

`record_cutoffs` compares each kind's effective rung through `KindDifficulty`
before and after assignment. Only a rung moving onto
`LevelSuggestion::LADDER` gets a new cutoff through the user's own today.
A target set, edited or removed can move a rung; a baseline change moves
only untargeted kinds. A preserved target produces no false cutoff. Moving
to principal engineer records no cutoff; returning to the ladder does.
The first-run track choice records no cutoff or event.

`write_events` passes `LevelSuggestionEvent.applied_rows` the before/after
state, cutoffs from before the change, and validated shown moves. Actual
baseline-driven moves are `skill_level_edit`; ordinary target and suggestion
sources remain unchanged. An all-targeted baseline change writes no events.

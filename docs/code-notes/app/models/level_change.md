# app/models/level_change.rb

## Why a separate object, called in order

These steps were `User` callbacks (`apply_track_change`,
`record_level_changes`, `record_level_suggestion_events`), and their order
was held only by declaration order and a comment (#434). `ProfileUpdate`,
the one flow that changes levels, now calls them by name inside one
transaction:

1. `#clear_track_targets`, after the posted fields are assigned. It must run
   before the save, because `User`'s `before_save` bumps
   `section_kind_preferences_version` only when `section_kind_levels`
   changed; a skill-level-only save that clears targets then bumps the
   version, and another tab's Exercise mix gets a 409 instead of writing the
   cleared levels back.
2. `#record_cutoffs`, after the track change, so a kind whose target the
   change cleared is compared at its new rung.
3. The save itself.
4. `#write_events`, after the save. The insert runs in the same transaction,
   so a failed insert raises and rolls back the level change and its cutoff
   together.

The object captures the stored levels, skill level and cutoffs when it is
built, before any assignment, so all three steps compare against the row as
it was read under the lock.

## `#clear_track_targets`

`TrackChange` is the rule; this applies it to a save that moves
`skill_level` after the first choice. The first track choice is not a track
change, so a first-run account keeps any target it already has.

## `#record_cutoffs`

It compares each kind's rung before the save with its rung after, and
records a cutoff at the new rung through the user's own today for each kind
that moved onto `LevelSuggestion::LADDER` (junior, mid_level, senior). A
target set, edited or cleared counts, and so does a skill-level change, which
moves every kind without a target and every kind whose target the track
change cleared. Results from an earlier stay at that rung then never count
again, even after a detour through principal_engineer. A rung that did not
move records nothing, and a move to principal_engineer records nothing,
because no suggestion reaches it. The first track choice records nothing:
there are no results yet to cut off.

## `#write_events`

It passes `LevelSuggestionEvent.applied_rows` the levels and skill level from
before and after the save, the cutoffs as they stood before, the moves the
page posted (`shown`, already checked by `ProfileUpdate` under the row lock)
and the kinds the track change cleared, which are labelled
`skill_level_edit`. It returns true so the form can chain it after `save`.

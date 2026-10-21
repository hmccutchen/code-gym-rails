# app/controllers/profile_controller.rb

The checks and the save live in `ProfileUpdate` (see
`docs/code-notes/app/forms/profile_update.md`). The controller maps the
form's outcome to a status and renders the reply bodies below.

## `#saved_body` and `#track_body`

The response includes `section_kind_preferences_version`, `kind_rungs` and the
ladder preparation only when the request touched a preference or the track,
so the body every other caller receives is unchanged. A track change can clear
targets (`TrackChange`), so its reply also carries the saved levels and locks
and `kept_own_level`: Setup hands them to the Exercise mix so its radios and
version match the server without a reload, and names the sections that kept
their own level.

## The 409 and track replies send only exclusions Setup shows

`preference_state` returns the exclusions for rotatable kinds only. A kind
excluded before it became daily keeps its stored exclusion, so swapping it
back restores the setting, but its difficulty controls have no exclude box;
syncing the dormant exclusion would disable them with nothing left to
re-enable them. The stored list stays whole, and the next save merges the
dormant entry back in.

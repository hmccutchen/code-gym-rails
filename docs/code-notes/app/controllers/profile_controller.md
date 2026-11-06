# app/controllers/profile_controller.rb

The checks and the save live in `ProfileUpdate` (see
`docs/code-notes/app/forms/profile_update.md`). The controller maps the
form's outcome to a status and renders the reply bodies below.

## `#saved_body` and `#track_body`

The response includes `section_kind_preferences_version`, `kind_rungs` and the
ladder preparation only when the request touched a preference or the track,
so the body every other caller receives is unchanged. A track reply carries
the actual saved `skill_level`, preference state and `kept_own_level`.
Setup hands them to the Exercise mix without discarding newer local edits.
The conflict response also includes the current baseline because a baseline
change alone does not increment the preference version.

## Read-only preview

`POST /profile/track_preview` accepts a user object containing only a valid
`skill_level`. It uses the authenticated `current_user` snapshot, never a
posted user ID, and builds `TrackChange` without assignment or persistence.
The response contains the rendered `api_keys/_track_preview` partial and
the from/to/version confirmation. It also supplies the saved baseline and
preferences for recovery when an earlier successful reply was lost.
An already-saved preview explicitly says so and performs no second write.

Both the inline consequences and `kept_own_level` use `TrackChange#retained`,
whose targets and effective locks come from `KindDifficulty`. Unsupported
historical targets, their ineffective locks and retired-kind entries are not
described as retained. The raw stored columns remain untouched by preview or
Apply; this is read normalization, not a cleanup.

## The 409 and track replies send only exclusions Setup shows

`preference_state` returns the exclusions for rotatable kinds only. A kind
excluded before it became daily keeps its stored exclusion, so swapping it
back restores the setting, but its difficulty controls have no exclude box;
syncing the dormant exclusion would disable them with nothing left to
re-enable them. The stored list stays whole, and the next save merges the
dormant entry back in.

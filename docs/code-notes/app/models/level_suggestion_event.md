# app/models/level_suggestion_event.rb

One row per answer to a level suggestion: an applied target change, a Not now
(`dismissed`), or a kind taken out of a bundle (`removed`). Nothing reads the
table yet. It exists so a later question, such as whether a dismissed kind
stayed stuck, can be answered by joining a row to the kind's level and
results afterwards. Design: `docs/superpowers/specs/2026-10-14-level-suggestions.md`,
report (d).

## Counts come from the server

`window_size`, `favourable`, `too_hard_latest3` and `newest_result_on` are
`TrackGraduation.summary` at `from_level`, computed from stored results with
the cutoffs as they stood before the change. Nothing the browser sends is
used. A kind with no previous target keeps the column defaults.

## `source` on applied rows

`User` detects every saved target change, whichever page sent it, so `source`
is decided here rather than by the page. A change is `suggestion` when
suggestions are switched on and the proposal computed from the levels in the
database offers this kind this destination; otherwise it is `setup_edit`. A
Setup edit that happens to match a pending proposal is therefore labelled
`suggestion`, since the suggestion is what it answers. With suggestions off no
offer was on screen, so every change is `setup_edit`.

Applied rows read `*_in_database` values because the save has already
assigned the new levels by the time the callback runs. Dismissal rows read
the reloaded row under the controller's lock, before its cutoffs change.

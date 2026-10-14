# app/models/level_suggestion_event.rb

One row per answer to a level suggestion: an applied rung change, a Not now
(`dismissed`), or a kind taken out of a bundle (`removed`). Nothing reads the
table yet. It exists so a later question, such as whether a dismissed kind
stayed stuck, can be answered by joining a row to the kind's level and
results afterwards. Design: `docs/superpowers/specs/2026-10-14-level-suggestions.md`,
report (d).

## Counts come from the server

`window_size`, `favourable`, `too_hard_latest3` and `newest_result_on` are
`LevelSuggestion.summary` at `from_level`, computed from stored results with
the cutoffs as they stood before the change. Nothing the browser sends is
used. The levels are rungs, so an untargeted kind is counted at the skill
level it was pitched at.

## Which kinds get an applied row

Only kinds whose target the save changed. A skill-level change moves every untargeted kind's rung, and `User` records a cutoff for each, but nobody chose those kinds one by one, so a row for each would bury the per-kind decisions this table exists to measure. A target change that leaves the rung where it was, such as a reset to Default at the skill level's own rung, writes nothing either.

## `source` on applied rows

`User` detects every saved rung change, whichever page sent it, so `source`
is decided here rather than by the page. A change is `suggestion` when
suggestions are switched on and the proposal computed from the rungs before
the save offers this kind this destination; otherwise it is `setup_edit`. A
Setup edit that happens to match a pending proposal is therefore labelled
`suggestion`, since the suggestion is what it answers. With suggestions off no
offer was on screen, so every change is `setup_edit`. A reset to Default reads
as a move to the skill level's rung, and records nothing when that rung is the
one the target named.

`applied_rows` is a plain builder: it reads no dirty tracking. `User` calls
it from one `after_save`, which runs when the save changed
`section_kind_levels`, and passes the changed kinds, the rungs,
locks, cutoffs and suggestion switch from `*_before_last_save`, since the
save has already written the new values by then. The insert runs in the
save's transaction, so a failed insert raises and rolls back the level change
and its cutoff together. An account's first insert and the join save write
nothing, a Leave that changes no level writes nothing, and the save that ends
the track by moving the last kind to senior still writes its rows.

## Dismissal rows

Dismissal rows read the reloaded row under the controller's lock, before its
cutoffs change. The endpoint writes a row only for a kind whose cutoff at its
current level moves forward: one with no cutoff at that level, or one dated
before the newest reviewed result (or today, with no results). A repeated Not
now, from a double click or a retry with no newer results, leaves the cutoff
where it was, writes no row and still answers with success.

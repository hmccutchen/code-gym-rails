# app/models/level_suggestion_event.rb

One row per answer to a level suggestion: an applied target change, a Not now
(`dismissed`), or a kind set aside from a card after Apply (`removed`). Nothing reads the
table yet. It exists so a later question, such as whether a dismissed kind
stayed stuck, can be answered by joining a row to the kind's level and
results afterwards.

## Counts come from the server

`window_size`, `favourable`, `too_hard_latest3` and `newest_result_on` are
`LevelSuggestion.summary` at `from_level`, computed from stored results with
the cutoffs as they stood before the change, at write time. Nothing the
browser sends is used for them, so they can differ from the card's numbers
when a review lands in between. A move from principal_engineer keeps the
column defaults, since no summary is kept at that rung.

## Rows are per rung, and `source` says what moved it

`applied_rows` compares each kind's rung before and after the save, so
`from_level` and `to_level` are rungs. A reset to Default therefore records
the skill level's rung as `to_level` (#390 recorded nil), and a target set to
the rung the skill level already gave writes nothing.

- `suggestion`: the kind's target changed and the move matches a step the
  dashboard card or Setup posted, which `ProfileController` checked against
  the stored rung under the row lock.
- `setup_edit`: any other target change.
- `skill_level_edit`: the target did not change, and the rung moved because
  `skill_level` did. A skill-level change writes one such row per kind
  without a target, so a bulk move can be found by `source` and grouped by
  `created_at`, apart from per-kind edits.

Before steps were posted, `source` came from recomputing the proposal at save
time. That mislabelled three cases: a review landing between render and
Apply, a kind set aside after Apply, and a Setup edit on an unsubmitted day
that happened to match a pending proposal. Labels now come only from what a
page showed.

`applied_rows` is a plain builder: it reads no dirty tracking. `User` calls it
from one `after_save` and passes the state from before the save.

## Dismissal rows

Dismissal rows read the reloaded row under the controller's lock, before its
cutoffs change. The endpoint writes a row only for a kind whose cutoff at its
current level moves forward: one with no cutoff at that level, or one dated
before the newest reviewed result (or today, with no results). A repeated Not
now, from a double click or a retry with no newer results, leaves the cutoff
where it was, writes no row and still answers with success. A row's
`to_level` is the move the card posted for that kind; a dismissal from a tab
opened before cards posted their steps falls back to the proposal recomputed
at write time.

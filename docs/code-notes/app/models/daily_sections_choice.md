# app/models/daily_sections_choice.rb

`DailySectionsChoice` is what Setup's Daily sections chooser shows for one
user. It reads the stored place list and answers every question the
chooser's markup asks, so the page script holds no copy of a pair rule.

- `counts` are the settings that open a chooser: every count except the
  pair's own size. Automatic opens none either, since it holds the pair.
- `keeping(kind)` is the place list a count of 1 stores when that kind is
  kept: the kind first, then every other stored place in its order. The
  other pair kind and any extras stay stored, so a later count brings them
  back.
- `options` are the kinds an extra section can take: every kind
  `DailyKinds.conflict` lets sit beside the pair, so the pair's own kinds and,
  beside a fourth, the other fourths are never offered.
- `extras_for(count)` preselects a kind per extra place: the stored extra
  when it still fits, otherwise the first option that fits beside the pair
  and the extras already chosen. Two selects can still be set to the same
  kind by hand; the server refuses that save with a sentence the chooser
  shows.

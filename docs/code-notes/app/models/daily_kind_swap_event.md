# app/models/daily_kind_swap_event.rb

One row per saved swap, written in the same user-row lock as the pair.
Nothing reads the table yet; it exists to answer how often an in-place swap
would have replaced something (`today_section` of `unanswered`) and whether
people swap while on two sections (`planned_size`, `size_setting`). Design:
`docs/superpowers/specs/2026-10-16-daily-kind-swap-design.md`, section 8.

## The name

The table is `daily_kind_swaps`, from #407. The model is `DailyKindSwapEvent`
because `DailyKindSwap` is the swap itself, the way `LevelSuggestionEvent`
sits beside `LevelSuggestion`.

## Values are copied, not linked

`planned_size` and `size_setting` copy what the user was on at the swap. A
link to the exercise would read a later regeneration's size, and there is no
row to link for `no_set`.

## Why `planned_size` may be null on a set

The spec required it unless `today_section` is `no_set`. A held set carried
forward from before `plan_notes` recorded a size has none, and requiring one
would roll back a valid swap. It is null there instead of inferred.

## `not_in_set`

Added to the spec's four values. After one swap, a second swap of the same
place names an outgoing kind that today's set never held; a judge-dropped
daily section does the same. Recording `unanswered` there would count it as a
section an in-place swap would have replaced.

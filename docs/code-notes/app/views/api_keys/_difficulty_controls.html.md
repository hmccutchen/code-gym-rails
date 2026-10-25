# app/views/api_keys/_difficulty_controls.html.erb

## Styles once per page

Setup renders this partial once for every section kind, so its `<style>`
would otherwise repeat for each one. The first render sets
`content_for :difficulty_controls_styles` and emits the block; later renders
see the flag and skip it. The layout never yields that key, so the flag only
marks the block as written, as `content_for :display_controls` does in
`api_keys/_display_preferences`. The first render comes after the page's own
`<style>`, so these rules still win the same-specificity ties they won when
they lived there (`docs/code-notes/app/views/api_keys/edit.html.md`).

The suggestion outline (`.mix-difficulty.mix-suggested`) renders only when
`suggested_kinds.any?`, the condition it had on the page, so a visit with no
suggested kind carries no outline rule. `spec/requests/api_keys_spec.rb` pins
both: one block however many kinds render, and the outline only with a
suggestion.

Beyond `kind` and `excluded`, the partial reads the controller's
`suggested_kinds` helper for the outline and its `mix-suggested` class.

## The radio row

Each difficulty option is a `label.mix-level` that wraps its radio and its
text, so the whole 48px-tall row is the tap target. The options stack, one per
row, because a kind's labels are too long to share a line at 320px. The
checked row gets a 2px accent border and loses 1px of padding to keep its
size, so choosing a level does not move the rows below it. In forced-colors
mode the border becomes `Highlight`, since an accent colour is dropped. A
disabled row goes muted and shows `not-allowed`, which is how a skipped kind
reads.

## The lock switch

The lock is a `.switch-row` with a `.switch` checkbox, the same switch the
rest of the page uses. It is disabled while the kind is skipped or follows the
default (`level.nil?`), because there is nothing to hold in either case.
`phone_cards.css` dims the row (`.switch-row:has(.switch:disabled)`), so the
partial adds only a margin above it.

## Accessible names

A radio inside a label already has the label's text as its name. The two
groups need more. The fieldset's `aria-labelledby` pairs the kind's name
(`mix-name-<kind>`, set in `api_keys/edit` on the weight label, or on a
name span for a kind with nothing to weigh) with the legend's id, so a screen reader announces "Code
review, Difficulty target" instead of the bare legend repeated for every kind. The
lock switch pairs the same name id with its own text id
(`lock-text-<kind>`), and so reads "Code review, Lock at this level".

## The controller does not change

`exercise_mix_controller` finds the radios by `data-action` and the lock by
`exercise-mix#toggleLock`, and it reads their values and `checked` state. The
restyle moved the inputs inside new wrappers but kept the same inputs, names
and actions, so the controller and its payload
(`spec/system/exercise_mix_payload_spec.rb`) are untouched.

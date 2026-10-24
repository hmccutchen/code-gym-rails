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

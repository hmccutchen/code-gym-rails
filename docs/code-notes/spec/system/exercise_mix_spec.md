# spec/system/exercise_mix_spec.rb

## `Exercise mix`

These examples run in a real browser because only a real round trip covers the listener that PATCHes `/profile`. A request spec stays green with that listener deleted.

## "keeps each difficulty radio beside its text"

A radio caught by the full-width input rule, or a stray label margin, only shows up in real layout, so this check needs the browser.

## "refuses a save from a page whose controls predate another save"

`user.update!` makes the same preference-version bump that a save in another tab would, without depending on a second window's timing.

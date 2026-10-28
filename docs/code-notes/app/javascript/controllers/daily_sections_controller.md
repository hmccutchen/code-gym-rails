# app/javascript/controllers/daily_sections_controller.js

## Which taps save at once

Automatic and 2 hold the pair, so a tap on either saves the count straight
away, as the radios always did. Any other count renders a hidden chooser
(`api_keys/_daily_sections`), and the tap opens it instead. The count saves
only from the chooser's Save, together with the kinds it holds, so a set is
never planned for a count whose places nobody chose. Cancel closes the
chooser and checks the saved count again, using `defaultChecked`, which the
controller moves on every successful save. A tap on the saved count fires no
`change`, so a `click` on a radio that is already the saved one reopens its
chooser; that is how a person changes the kept kind or the extras without
picking another count first.

## What a choice posts

The chooser posts the count, the whole place list, the `layout` the page
was rendered for and the stored `places` it was rendered from. `places`
covers what `layout` can't: under a count of 1 another tab can swap the
hidden second place without moving the layout, and the server answers a
moved `places` with the same 409. A count of 1 posts the list its kept option carries, as
rendered by `DailySectionsChoice#keeping`. A larger count posts the pair
from the chooser's `data-pair` followed by each select's kind. The script
builds no list of its own beyond joining those two.

## Waiting for the Exercise mix first

Before it sends, a save waits for `saveStatus.settled`, which covers the
Exercise mix's debounced edit through the probe that controller registers.
An edit still waiting to send would otherwise post the old layout after this
save, get a 409, and be lost to the reload.

## Reloading for the Exercise mix

The Exercise mix below is rendered for the daily kinds the old setting
held. When the reply's `daily_kinds` differ from the rendered layout, its
`rotates` differs from the rendered one (the Exercise mix labels its groups
by it), or the server answers 409 with `layout_changed`, the page reloads through
`saveStatus.reloadWhenSaved`, so a save still in flight elsewhere on the
page lands first. If one fails, the banner says the daily sections are
saved and asks for a reload once the other change saves.

## An edit made before the modules load

A radio tapped before `connect()` fires no event this controller hears.
`connect()` compares the checked radio with the rendered one and handles it
as a tap.

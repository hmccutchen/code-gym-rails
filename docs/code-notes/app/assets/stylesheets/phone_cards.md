# phone_cards.css

The card, full-width button, switch, value row, segmented control and card heading styles, and the two card page wrappers. The Account and Settings pages use them, and History, Progress and Learn use `.card-page`.

## What each class is for

- `.phone-page`: the page wrapper. Cards stack with a 16px gap, and the page adds 16px of bottom padding on top of the tab-bar clearance `body` already has. From 600px it is a centered 480px column.
- `.card-page`: the same wrapper without the 480px column, for a page that takes the container's full width from 600px (History, Progress, Learn). Each page's own sheet lays it out differently at 900px and wider.
- `.card`: one section of the page. 16px padding, the shared radius, surface background and border, no shadow. `.card h2` is `1rem`.
- `.card-note`: muted `.85rem` text inside a card. It is the one place that style lives, so a status line, a field label or a usage line that should look muted takes this class, and its page sets only spacing.
- `.btn-block`: a modifier on `.btn` that makes the button full width and at least 48px tall. `.btn` itself does not change. The rule is written `.btn.btn-block` so it outranks `.btn`'s `inline-block` on its own, rather than by loading after the layout's styles.
- `.switch-row`: a `<label>` holding text and a checkbox. The whole row, at least 48px tall, is the tap target.
- `.switch`: the checkbox inside a switch row, drawn as a 44px track and a thumb. It has a disabled state and its own focus ring, because the layout's focus rule skips checkboxes. The off track uses `--muted` and the thumb uses `--surface`. With reduced motion the thumb stops sliding, and in forced-colors mode the switch falls back to a native checkbox.
- `.switch-row:has(.switch:disabled)`: a switch row whose switch is disabled goes muted and shows `not-allowed`, so the row reads as unavailable and not only the track. The Exercise mix lock uses it while a kind is skipped.
- `.card input[type="range"]`: a slider drawn at 44px tall, with a 6px track in the muted text colour (3:1 or better against both surfaces, where the border colour is about 1.2:1) and a 28px round thumb in the button colour with a 2px edge in the surface colour, since the thumb and the track are nearly the same shade in the light palette. A disabled slider drops to 40% opacity, and the layout's rule rings its thumb on focus, not the whole 44px track, which is why this file adds no focus rule of its own. It sets `font-size` to the input size, so every focusable control on the page stays at the input font size, in step with the others. In forced-colors mode it falls back to the browser's own slider, because custom track and thumb colours are dropped there.
- `.card-heading` and `.card-tag`: a heading row with a short muted tag beside it, such as "Tap Save to apply" on Settings' Connection card. The row wraps, so the tag drops under the heading on a narrow screen.
- `.value-row`: a label on the left and the chosen value on the right, with a chevron. The real `<select>` is laid over the whole row with zero opacity, so a tap opens the phone's own picker, and the visible text comes from `.value-row-value`, which the server fills with the selected option's text and `value_row_controller` updates on change. The row's bottom line is a 1px border, because forced-colors mode removes box-shadows; the select reaches 1px past the padding box (`inset: 0 0 -1px`) so a tap on the line still opens the picker. The right padding leaves room for the chevron and is not the container's gutter, so it stays a different value (`container_gutter_spec` fails if `phone_cards.css` holds that gutter's number). Focus shows as a ring on the row, through `:has(select:focus-visible)`.
- `.field-group`: a bare `fieldset` with a muted legend, for a group of choices on a card.
- `.segmented` and `.segment`: a pill of radio choices. Each radio is stretched over its segment with zero opacity, so the whole segment is the 44px tap target, and `:has(:checked)` fills the chosen one. In forced-colors mode the chosen segment gets a `Highlight` outline, since background fills are dropped.
- `details.card > summary`: a collapsible card's summary, at least 48px tall, so a disclosure is as easy to tap as a switch row.
- `.card :is(.value-row, .segmented, input:not([type="hidden"])) + .card-note`: a note right under a value row, a segmented control or a text input sits `.4rem` below it, so a hint never touches the control it explains. A hidden input, such as a form's token, takes no space, so a note after one keeps its normal spacing.
- `.card .card-note:empty`: an empty note takes no margin, so a status line that has nothing to say leaves no gap.
- `.switch-status:not(:empty)`: the "Saved" line under a switch gets a small top margin only while it holds text.

## Side margins and the safe area

A card's outer edge sits `max(16px, inset)` from the screen edge on each side, where `inset` is that side's `env(safe-area-inset-*)`. `.container` pads each side by `--container-pad-left` and `--container-pad-right`, which are `max(1.5rem, inset)` under 1024px. Under 600px `.phone-page` and `.card-page` set each side's margin, in one rule, to the difference, reading those properties, so it never restates `.container`'s padding. `spec/views/container_gutter_spec.rb` fails if it does.

| Inset | `.container` pads | Margin | Card edge from screen |
|---|---|---|---|
| 0 | 24px | -8px | 16px |
| 20px | 24px | -4px | 20px |
| 44px | 44px | 0 | 44px |

A single `calc(16px - 1.5rem)` would put the card 36px from the edge under a 44px inset, which is under the notch. If `.container`'s padding changes, this margin follows it through the properties.

At 600px and wider the page is `max-width: 480px`, centered, inside `.container`'s content box. That box is already padded by at least the inset, so no negative margin is needed.

## The `[hidden]` rule

Any `display` an author rule sets beats the browser's own `[hidden]` rule, and the layout has no global one. So `:is(.phone-page, .card-page) [hidden] { display: none }` restores it for every element on a card page. At 0,2,0 it outranks every one-class `display` rule here and in the page styles, so a new flex class needs nothing added. `#push-repair` is rendered hidden until it is needed and carries `.btn-block`, so it depends on this.

## Why it loads on every page

The layout links it for every user, before the display stylesheets. A search for these class names in the layout and the views found no other use, so nothing else changes. Keep any new rule here scoped to its own class.

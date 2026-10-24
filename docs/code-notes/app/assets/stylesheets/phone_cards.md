# phone_cards.css

The card, full-width button and switch styles for the settings pages. The Account page uses them first. Settings moves onto them in a later PR.

## What each class is for

- `.phone-page`: the page wrapper. Cards stack with a 16px gap, and the page adds 16px of bottom padding on top of the tab-bar clearance `body` already has.
- `.card`: one section of the page. 16px padding, the shared radius, surface background and border, no shadow. `.card h2` is `1rem`.
- `.card-note`: muted `.85rem` text inside a card.
- `.btn-block`: a modifier on `.btn` that makes the button full width and at least 48px tall. `.btn` itself does not change.
- `.switch-row`: a `<label>` holding text and a checkbox. The whole row, at least 48px tall, is the tap target.
- `.switch`: the checkbox inside a switch row, drawn as a 44px track and a thumb. It has a disabled state and its own focus ring, because the layout's focus rule skips checkboxes.

## Side margins and the safe area

A card's outer edge sits `max(16px, inset)` from the screen edge on each side, where `inset` is that side's `env(safe-area-inset-*)`. `.container` already pads each side by `max(1.5rem, inset)`, so under 600px `.phone-page` sets each side's margin to the difference.

| Inset | `.container` pads | Margin | Card edge from screen |
|---|---|---|---|
| 0 | 24px | -8px | 16px |
| 20px | 24px | -4px | 20px |
| 44px | 44px | 0 | 44px |

A single `calc(16px - 1.5rem)` would put the card 36px from the edge under a 44px inset, which is under the notch. If `.container`'s padding changes, this margin changes with it.

At 600px and wider the page is `max-width: 480px`, centered, inside `.container`'s content box. That box is already padded by at least the inset, so no negative margin is needed.

## The `[hidden]` rule

A `display` set in this file beats the browser's own `[hidden]` rule, and the layout has no global one. So `.btn-block`, `.switch-row` and `.card` each restore `display: none` for `[hidden]`. `#push-repair` is rendered hidden until it is needed and carries `.btn-block`, so it depends on this.

## Why it loads on every page

The layout links it for every user, before the display stylesheets. A search for these class names in the layout and the views found no other use, so nothing else changes. Keep any new rule here scoped to its own class.

# pages/settings.css

Settings's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on Settings only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

The rules' order and the ties it settles are in
`docs/code-notes/app/views/api_keys/edit.html.md` ("Partials' styles"). Each
partial renders on Settings only.

## At 900px and wider

- The page takes the 1040px column and becomes a two-column grid:
  Connection beside Your day, then Exercise mix and Display spanning the row.
  `max-width: none` undoes `.phone-page`'s 480px cap.
- The cards don't stretch (`align-items: start`): Connection is about twice
  Your day's height, and a stretched Your day would be half empty.
- Each Exercise mix group's kinds sit two across in `.mix-kinds`. A kind gets
  a 1px border, a 12px radius and 12px padding here, so two kinds side by side
  read as two. A single-kind group's one kind takes half the row, like each
  kind in a pair.
- The card notes in both disclosures hold to `65ch`.
- Below 900px nothing changes: a centered 480px column from 600px.

## `.saved-keys`

The list of stored keys under Save. Each row is a wrapping flex line: the
provider's name, the "In use" tag, and the Remove form pushed to the right
with `margin-left: auto`. At a narrow width or with large text the form
wraps under the name instead of running past the card. The button is 44px
tall, the touch target the Learn page's small buttons use.

## `.form-field .card-note a`

The key hint links to each provider's console, and each link text is one
unbreakable word. At a 320px width with large text it ran past the screen in
every font, so the links may break inside the word when nothing else fits.
The reasoning is in `docs/decisions/display-preferences.md` ("Long words").

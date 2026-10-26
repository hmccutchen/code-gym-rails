# Desktop layout

The app is laid out for a phone first. At 900px and wider, a page that asks
for it gets a desktop layout: a centered column up to 1040px wide, with the
page's own arrangement inside it (History puts its title in a left rail beside
the entries). Pages move onto it one at a time, History first.

## The breakpoints

- **Under 600px:** the phone layout. Card pages put each card `max(16px, inset)`
  from the screen edge (`phone_cards.css`).
- **600 to 899px:** one column. Account and Settings stay a centered 480px
  column (`.phone-page`). History, and later Today, Learn and Progress, take
  the container's full width (`.card-page`), because code and reviews are
  cramped at 480px. An iPad in portrait and a phone in landscape land here.
- **900px and wider:** the desktop layout, from `desktop.css`.

900px, not 1024px, so an iPad Pro in portrait (1024px) and an iPhone Pro Max
in landscape (932px) both get the desktop layout. That makes the desktop
layout a touch layout too, and so is the next rule.

## Touch targets stay 44px at every width

Every target on a page is at least 44px tall on a desktop too, and nothing
relaxes that under `(pointer: fine)`. An iPad in standalone mode is a
desktop-width touch device, and a pointer query can't be trusted to tell it
apart from a laptop with a touch screen. The top nav's links follow it too:
above the width where the nav collapses they are 44px tall
(`nav_link_targets_spec`), where they were 34px before #550. The name field
beside them is the one exception left: it is about 27px tall, and #555 gives
it a 44px target.

## The desktop column is per page

`.container` itself doesn't change: a page widens by calling `wide_page`,
which gives its container a second class, `container-wide`. Widening
`.container` for every page would reach the sign-in, welcome, admin and
concept pages, none of which have a desktop layout. The column is 1040px of
content plus the container's own gutters, so it keeps clear of a notch in
landscape. It is built from `--container-pad-left` and `--container-pad-right`
rather than a copy of their values, and `container_gutter_spec` holds that.
`container_class` gives the plain class unless a view calls `wide_page`, and
that default is the guard; `wide_pages_spec` also checks that the main pages
not yet moved stay plain. The nav keeps its own 1200px cap, so it does not
line up with the 1040px column yet (#551).

The `100vw` break-out was rejected: `100vw` includes a classic scrollbar's
width, so it scrolls the page sideways on Windows and Linux.

## `desktop.css` holds only 900px rules

Everything in `desktop.css` sits inside one `@media (min-width: 900px)` block,
so it can't change the phone layout, and `desktop_stylesheet_spec` fails on
anything outside it, an at-rule like `@font-face` included. Its rules are
scoped to a page class (`.history-page`) or the wide container. The file loads
after `phone_cards.css`, so it wins a tie with a phone card rule. A view's own
`<style>` block renders in the body, after it, so a desktop rule that overrides
a view's rule needs a more specific selector. History, Progress and Learn have
no such block or a small one; Account, Settings and Today have several, so
their PRs either prefix each desktop rule with the page class or move their
900px rules into the view itself. That choice is open and gets made on the
Account and Settings PR.

## What the boards had that the app doesn't

The design boards drew the desktop layout. Where they disagreed with the app,
the app wins: its nav, its Progress legend copy, no month list in History's
rail, no "5 of 10" counts, and 44px controls where the boards drew 40px.

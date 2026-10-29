# Desktop layout

The app is laid out for a phone first. At 900px and wider, a page that asks
for it gets a desktop layout: a centered column up to 1040px wide, with the
page's own arrangement inside it (History puts its title in a left rail beside
the entries). Pages move onto it one at a time: History first, then
Progress, Learn, Account and Settings, and Today.

## The breakpoints

- **Under 600px:** the phone layout. Card pages and Today put each card
  `max(16px, inset)` from the screen edge (`phone_cards.css`); Today's
  Submit and regenerate controls end the page
  (`docs/code-notes/app/assets/stylesheets/pages/today.md`).
- **600 to 899px:** one column. Account and Settings stay a centered 480px
  column (`.phone-page`). History, Progress, Learn and Today take the
  container's full width, because code and reviews are cramped at 480px. An iPad in portrait and a phone in landscape land here.
- **900px and wider:** the desktop layout: the shared column and nav from
  `desktop.css`, and each page's arrangement from the 900px block at the end
  of its own sheet (`docs/decisions/page-stylesheets.md`).

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

A link inside a sentence is exempt, as WCAG 2.5.8 allows and
`docs/accessibility-audit-2026-09-30.md` records: Progress' "Change the mix"
link, in its note about kinds left out of the mix, is 15px tall.

## The desktop column is per page

`.container`'s width doesn't change (it only exposes its cap as
`--container-max`, which the nav reads below 900px, #612): a page widens by calling `wide_page`,
which gives its container a second class, `container-wide`. Widening
`.container` for every page would reach the sign-in, welcome, admin and
concept pages, none of which have a desktop layout. The column is 1040px of
content plus the container's own gutters, so it keeps clear of a notch in
landscape. It is built from `--container-pad-left` and `--container-pad-right`
rather than a copy of their values, and `container_gutter_spec` holds that.
`container_class` gives the plain class unless a view calls `wide_page`, and
that default is the guard; `wide_pages_spec` also checks that the main pages
not yet moved stay plain.

## The nav uses the same column on every page

At 900px and wider, the nav's `.inner` takes the same 1040px cap as a wide
page, from the same rule in `desktop.css`, so the formula lives in one place.
Before #551 it kept the layout's own 1200px cap, and once the window was wider
than the cap (1040px plus the gutters) the brand sat left of a wide page's
content: at 1280px and the default text size it was at x=72 and History's
content at x=120. Below that width nothing changes, since the cap is wider
than the window: 1104px at the default text size, 1129.6px at 140%, where
the 2rem gutters are larger. Below 900px the nav takes the page column's
800px cap less the side insets (#612), so it lines up with every page there,
plain or wide.

The nav doesn't follow the page. It uses the 1040px cap on every page, wide
or not, because a nav that matched the page would jump 48px each time someone
moved between a wide page and a plain one. Waiting until every page is wide
was ruled out too: the sign-in, welcome, admin and concept pages stay plain
by decision, so that day never comes. A plain page's content sits 92px inside
the brand at 1280px, where it sat 140px inside before, and lines up once
that page moves to `wide_page`. The collapse into the menu button is an
`@container` query on `.inner`'s content box at 42em (#612). From 900px the
1040px cap is wider than 42em at every text size (940.8px at 140%), so the
cap doesn't move it there; below 900px the page column's cap does, on
purpose, so the row folds before the cap pinches its links.

The `100vw` break-out was rejected: `100vw` includes a classic scrollbar's
width, so it scrolls the page sideways on Windows and Linux.

## `desktop.css` holds only 900px rules

Everything in `desktop.css` sits inside one `@media (min-width: 900px)` block,
so it can't change the phone layout, and `desktop_stylesheet_spec` fails on
anything outside it, an at-rule like `@font-face` included. It holds only the
shared rule: the wide container and the nav. A page's own desktop rules live
in the 900px block at the end of that page's sheet, which the History PR left
as an open question (a page class prefix in `desktop.css`, or the view's own
`<style>`). Page stylesheets answered it (`docs/decisions/page-stylesheets.md`).

## What the boards had that the app doesn't

The design boards drew the desktop layout. Where they disagreed with the app,
the app wins: its nav, its Progress legend copy, no month list in History's
rail, no "5 of 10" counts, and 44px controls where the boards drew 40px.
Today's side column holds Submit and the regenerate controls but not this
week's concept, which stays below the day.

# desktop.css

The rules for 900px and wider. The reasoning behind the breakpoint, the column
width and the per-page modifier is in `docs/decisions/desktop-layout.md`.

## Why everything sits in one media block

Nothing in this file may reach a phone, so every rule is inside
`@media (min-width: 900px)`. `desktop_stylesheet_spec` reads the file with
`ViewStyles` and fails on a rule under any other condition, and it also fails
on any text outside the block, since `ViewStyles` skips an at-rule such as
`@font-face` or `@property` at the top level. The link tag
carries no `media` attribute, since a spec can't check one, and the file's own
block is enough.

## Which rule wins

The file loads after `phone_cards.css`, so on a tie a desktop rule beats a
phone card rule (`.history-page`'s grid replaces `.card-page`'s flex column).
A view's own `<style>` block renders in the body, after this file, so on a tie
the view's rule wins. A desktop rule that overrides a rule in a view uses a
more specific selector: `.history-rail .history-rail-page` beats the History
view's `.history-rail-page { display: none }`.

## The wide container

`.container.container-wide` caps the container at
`1040px + --container-pad-left + --container-pad-right`. Every element is
`border-box`, so `max-width` includes the padding, and the content box comes
out at 1040px at any safe-area inset. Below that width the container's
gutters are unchanged.

The same rule caps `nav .inner`, the nav's own `.container`, so the brand and
links line up with a wide page's content, and the formula stays in one place.
With a side safe-area inset they line up only once the window is wider than
1040px plus four times the inset, because the nav counts the inset twice
(#553).
It applies on every page, wide or not, so the nav doesn't move between pages.
The layout's `nav .inner` rule sets `max-width: 1200px` with the same
specificity, and this file loads after the layout's `<style>`, so the 1040px
cap wins. `desktop_stylesheet_spec` holds that order. `container_gutter_spec` holds both selectors to the one rule.

## History

- `.history-page` is a grid: a 240px rail, a 24px gap, then the entries. The
  entries column is `minmax(0, 1fr)`, not `1fr`. A grid track defaults to
  its content's minimum width, so a long path in a review or a wide code
  block would otherwise widen the column and scroll the page sideways.
- `.history-rail` is sticky 24px from the top. It holds three short lines,
  about 200px at the largest text, which is under the shortest window that
  reaches this layout (430px, an iPhone Pro Max in landscape). So it needs no
  minimum-height guard.
- The rail's "Page X of Y" shows only here. On a phone the pager already says
  it.
- An entry's padding is 20px here and 16px on a phone.
- The open review is held to `65ch`, a comfortable reading width. Answers and
  code keep the entry's full width.

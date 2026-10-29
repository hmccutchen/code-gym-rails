# desktop.css

The shared rules for 900px and wider: the wide container and the nav. Each
page's own desktop rules live at the end of its sheet under
`app/assets/stylesheets/pages` (`docs/decisions/page-stylesheets.md`). The
reasoning behind the breakpoint, the column width and the per-page modifier
is in `docs/decisions/desktop-layout.md`.

## Why everything sits in one media block

Nothing in this file may reach a phone, so every rule is inside
`@media (min-width: 900px)`. `desktop_stylesheet_spec` reads the file with
`ViewStyles` and fails on a rule under any other condition, and it also fails
on any text outside the block, since `ViewStyles` skips an at-rule such as
`@font-face` or `@property` at the top level. The link tag
carries no `media` attribute, since a spec can't check one, and the file's own
block is enough.

## Which rule wins

The file loads after `phone_cards.css` and before a page's own sheet. Every
selector here is the wide container or the nav, and `desktop_stylesheet_spec`
holds that.

## The wide container

`.container.container-wide` caps the container at
`1040px + --container-pad-left + --container-pad-right`. Every element is
`border-box`, so `max-width` includes the padding, and the content box comes
out at 1040px at any safe-area inset. Below that width the container's
gutters are unchanged.

The same rule caps `nav .inner`, the nav's own `.container`, so the brand and
links line up with a wide page's content, and the formula stays in one place.
With a side safe-area inset, `nav .inner` pads by its gutter less the inset
the nav already padded (#553), so the two line up until the page's cap binds
at 1040px plus both gutters. Past that the nav's row is still wider, and
from 1040px plus both gutters and both insets its content is 1040px plus both
insets, so the brand sits one inset left of the page's content. No phone in
landscape is that wide; a window that wide with side insets would need the
cap to subtract them too.
It applies on every page, wide or not, so the nav doesn't move between
pages. The layout's `nav .inner` rule sets its own `max-width`, the page
column less the side insets, with the same specificity, and this file loads
after the layout's `<style>`, so the 1040px cap wins.
`desktop_stylesheet_spec` holds that order. `container_gutter_spec` holds
both selectors to the one rule.

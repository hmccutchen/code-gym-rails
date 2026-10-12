# app/javascript/controllers/nav_menu_controller.js

## What it owns

The narrow-viewport nav disclosure: the hamburger toggle, the outside click
that closes it, and Escape.

## Open state lives in the DOM

`data-open` on the links element is the one record of whether the menu is
open, and `aria-expanded` on the toggle mirrors it. Holding it in a controller
field as well would give two answers that can disagree after a back/forward
restore, where the attribute survives and a field does not.

## stopPropagation on the toggle

The document-level outside-click action and the toggle both see the same
click. Without `stopPropagation` the toggle would open the menu and the
document handler would immediately close it again.

## Escape returns focus

Closing with Escape moves focus back to the toggle. A keyboard user who
dismisses the menu would otherwise be left on an element that is now hidden,
and focus would fall to the body.

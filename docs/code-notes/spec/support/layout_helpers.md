# spec/support/layout_helpers.rb

## `#cdp_session`

`#set_safe_area` and `#set_default_font_size` share one Chrome DevTools
session per example. An emulation override lasts only as long as the
session that set it, so a second session opened for the font size dropped
the notch the first had set (#612).

## `#set_default_font_size`

It sets the browser's own default font size, which the app's text sizes are
percentages of (`display.css`). A larger browser default moves the nav's
fold, which is in em, against caps that are in px, so the nav specs sweep
18px and 19px defaults as well as the app's own text sizes.

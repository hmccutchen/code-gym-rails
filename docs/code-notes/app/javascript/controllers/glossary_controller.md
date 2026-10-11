# app/javascript/controllers/glossary_controller.js

## What it owns

Every glossary term on the page: opening one panel at a time, the keyboard
path, and keeping an open panel the width of its surrounding box.

## Mounted on <body>

Terms are rendered in many partials, so the controller mounts once on the body
and finds terms by class. Mounting per term would be one controller instance
per word, and the "only one open at a time" rule would then need cross-instance
state for no gain.

## Enter and Space are handled here

`GlossaryHelper` renders terms as `role="button"` spans, which do not activate
on Enter or Space the way a real button does. The key handler supplies that and
calls `preventDefault`, so Space scrolls the page only when no term has focus.

## Why the panel is positioned in script

The panel is as wide as the section or container the term sits in, which is a
rendered width no stylesheet can name. `--gloss-width` and `--gloss-shift` are
recomputed on open, on resize, and when a disclosure containing the term
toggles, since each changes that box.

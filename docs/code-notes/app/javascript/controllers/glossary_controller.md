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
recomputed on open and on resize, since each changes that box.

## Learn has no `.section`

The panel sizes to the nearest `.section` or `.container`. The dashboard's
concept dropdown sits inside a `.section`, but the Learn pages and the lesson
page do not. They sit directly in `.container`, so the panel there is as wide
as the container. The fallback is what makes a term on Learn measure at all,
so removing `.container` from that selector would leave Learn panels unsized.
A term inside a closed `details` (such as "Code examples") has no panel box
until the reader opens it, and the panel is re-measured on `focusin` and
`pointerover`, so opening the disclosure and then touching the term works.

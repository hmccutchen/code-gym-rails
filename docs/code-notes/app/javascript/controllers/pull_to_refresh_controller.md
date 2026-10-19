# app/javascript/controllers/pull_to_refresh_controller.js

## What it owns

The installed app's pull-to-refresh gesture. The design decision behind it —
why the content moves and the nav does not, why the transform is cleared at
rest, and why standalone mode is read from the indicator's own visibility —
is in `docs/code-notes/app/views/shared/_pull_to_refresh.html.md`.

## It gives up in connect

A browser tab keeps its native pull, so the controller attaches nothing when
the indicator is not displayed. `listening` records that, and `disconnect()`
returns early rather than removing listeners it never added.

## Document listeners come off in disconnect

The four touch listeners are on `document`, not on the controller's element,
so Stimulus cannot remove them. `disconnect()` removes all four and clears the
two pending timers, which is what keeps a reload-in-progress gesture from
outliving the page that started it.

## It stops under a modal dialog

A touch that starts while a modal dialog is open, such as a daily card's
swap sheet, starts no pull, since dragging the sheet's list down at the top
of the page would otherwise refresh behind it. `modalOpen` checks each open
`<dialog>` with `matches(":modal")` rather than querying `dialog:modal`.
Safari 15.4 and 15.5 support `:has` but not `:modal`, and a selector it
can't parse throws, which would break every touch there. When `:modal`
throws, an open dialog counts as modal, which is true of every dialog this
app opens. An open dialog that isn't modal doesn't stop a pull.

## It imports the save status module

`reloadWhenSaved` asks `code_gym/save_status` whether anything is still on the
wire. The inline version read `window.CodeGymSaveStatus?.pending()` with a
fallback, because the global might not have been assigned yet; an import
cannot be missing.

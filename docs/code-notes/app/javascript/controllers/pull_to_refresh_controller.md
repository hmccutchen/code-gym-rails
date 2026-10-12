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

## It imports the save status module

`reloadWhenSaved` asks `code_gym/save_status` whether anything is still on the
wire. The inline version read `window.CodeGymSaveStatus?.pending()` with a
fallback, because the global might not have been assigned yet; an import
cannot be missing.

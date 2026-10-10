# app/views/shared/_pull_to_refresh.html.erb

CLAUDE.md's "Pull-to-refresh in the installed app" paragraph covers the gesture's design: why it exists alongside `overscroll-behavior-y: none`, the iOS-style sliding content, how standalone mode is detected, waiting for pending saves, and the sessionStorage note that keeps the spinner turning across the reload. The notes below cover details it leaves out.

## The indicator

The spinner sits at `z-index: -1`, beneath both the nav and the page content, so it only shows in the gap the content opens as it moves down.

## `insideScrolledArea`

A pull that starts inside an inner area scrolled away from its top scrolls that area, not the page, so it never counts as a refresh.

## `savesPending`

`window.CodeGymSaveStatus` is absent on signed-out pages. Those pages have nothing to save, so a missing helper reads as no pending save.

## `reloadWhenSaved`

A save still pending at `SAVE_WAIT_LIMIT_MS` is treated as hung. The pull is cancelled rather than reloading over the save, and the person can pull again.

## The `touchstart` listener

A second finger, or any touch that cannot start a pull, resets a pull already in progress, so the content is never left pulled down.

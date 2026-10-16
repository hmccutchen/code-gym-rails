# app/views/shared/_pull_to_refresh.html.erb

The "Pull-to-refresh in the installed app" paragraph of `docs/decisions/home-screen-app.md` covers the gesture's design: why it exists alongside `overscroll-behavior-y: none`, the iOS-style sliding content, how standalone mode is detected, waiting for pending saves, and the sessionStorage note that keeps the spinner turning across the reload. The notes below cover details it leaves out.

## The indicator

The spinner sits at `z-index: -1`, beneath both the nav and the page content, so it only shows in the gap the content opens as it moves down.

## The controller

`data-controller="pull-to-refresh"` on the indicator drives the gesture;
`docs/code-notes/app/javascript/controllers/pull_to_refresh_controller.md`
covers the document-level listeners and their teardown, the inner-scroll and
editable-field guards, the hung-save limit, and why a second finger resets a
pull already in progress.

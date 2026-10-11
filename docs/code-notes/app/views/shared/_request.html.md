# app/views/shared/_request.html.erb

## Purpose

Every page script sends its requests through `window.CodeGymRequest.send`, so
three things are decided once: how the CSRF token is read, how an expired
session is recognised, and what a failed request may show a person. Before this
module, twelve scripts built their own requests, and two helpers showed
different text for the same failure.

## What `send` returns

`send` never throws. It resolves with `{ ok, status, data, message, signedOut }`
for every outcome, a dropped connection included (`status` 0), so a caller
writes one branch for success and one for failure instead of a try, a catch and
a status check.

## `message`

- The reply's `error`, when the reply is the app's own: every app error goes
  through `JsonErrors#render_json_error`, whose `status` is a string. Rails'
  reply to an unhandled exception also has an `error`, but its `status` is a
  number, so its status phrase is never shown.
- The signed-out sentence, when fetch followed a redirect. A JSON endpoint only
  redirects to the login page after the session expires, so a 200 that arrived
  through a redirect stored nothing. A caller can pass its own sentence
  (`signedOut`), as the save banner does.
- Otherwise the caller's `fallback`: an HTML error page, an unreadable body or
  a dropped connection all show the page's own wording.

## `csrf()`

The lookup is optional-chained: with forgery protection off, as in the test
environment, Rails renders no csrf meta tag at all, and a throw would stop the
request silently.

## Load order

The layout renders this in `<head>`, ahead of `shared/_save_status`, so every
page script and every other shared script can call it as it runs.

# app/javascript/code_gym/request.js

## Purpose

Every page script sends its requests through `CodeGymRequest.send`, so
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
  through a redirect stored nothing. Every caller shows the same sentence for
  this, the save banner included, so one expired session never reads two ways
  on one page.
- Otherwise the caller's `fallback`: an HTML error page, an unreadable body or
  a dropped connection all show the page's own wording.

## `csrf()`

The lookup is optional-chained: with forgery protection off, as in the test
environment, Rails renders no csrf meta tag at all, and a throw would stop the
request silently.

## Load order

The layout loads this through `javascript_importmap_tags`, so it is a deferred
module: it evaluates after the document is parsed and before
`DOMContentLoaded`. Every page script now imports it. `app/javascript/application.js`
still puts it on `window.CodeGymRequest`, for two reasons: system specs drive
the module through that name inside `execute_script`, which runs in a classic
context that cannot import a module, and the bootstrap
(`app/assets/javascripts/code_gym_bootstrap.js`) publishes the name at parse
time, so the module has to take it over when it loads. The bootstrap's note
covers the parse-time stubs.

## Where the text comes from

A module cannot read a translation, so the layout renders the signed-out
sentence onto `<body>` as a data attribute and `text()` reads it when a request
actually fails. `<body>` because it is there whenever a deferred module runs,
and the sentence is the page's, not one control's.

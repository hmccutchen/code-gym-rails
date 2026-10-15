# config/routes.rb

## `service-worker.js`

The service worker route sets `format: false` for the same reason the manifest route does: without it, `/service-worker.js.html` would reach the controller as HTML and fail with `MissingTemplate`.

## `resource :push_subscription`

The subscription resource is not nested under `account`. A user makes one reminder choice, however many browser endpoints back it.

## `responses#pseudocode_critique`

This collection route takes no `:id` because it runs before submission, when today's response may not exist yet.

## The old `learning_track/dismissal` and `learning_track/answer` paths

The level suggestion endpoints moved from `learning_track/…` to
`level_suggestion/…` when suggestions stopped belonging to the junior track.
A dashboard tab opened before that deploy still posts to the old paths, so
for one release they route straight to the new controllers. They are not
redirects: `code_gym/request.js` treats any followed redirect as an expired
session, so a redirect would show "your session expired" and save nothing.
Remove both lines in the same change that drops the ignored track
columns (#394).

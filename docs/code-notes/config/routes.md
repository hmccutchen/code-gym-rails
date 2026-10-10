# config/routes.rb

## `service-worker.js`

The service worker route sets `format: false` for the same reason the manifest route does: without it, `/service-worker.js.html` would reach the controller as HTML and fail with `MissingTemplate`.

## `resource :push_subscription`

The subscription resource is not nested under `account`. A user makes one reminder choice, however many browser endpoints back it.

## `responses#pseudocode_critique`

This collection route takes no `:id` because it runs before submission, when today's response may not exist yet.

# app/views/shared/_push_script.html.erb

## The partial as a whole

This is the shared push plumbing: the capability test, subscribing, and registering with the server. The layout renders it ahead of `yield :page_scripts`, so the Account page's enable button can rely on `window.CodeGymPush` existing by the time its own script runs.

It never requests notification permission. That call has to happen synchronously inside a real click handler (see `accounts/_push_reminders`), and nothing here runs from one.

## Re-subscribing on launch

The self-starting block at the end waits for `DOMContentLoaded` before calling `subscribeAndRegister`. Nothing it reads on its first line is a module global, so the wait reads as unnecessary — but the chain reaches `CodeGymRequest.send` once the service worker is ready, and `code_gym/request` is a deferred module that may still be loading. Losing that race would fail the enrolment, and the `.catch` here is deliberately silent, so the user would see a reminder toggle that is on and an endpoint the server never stored. The permission rule above is unaffected: that constraint belongs to the Account page's click handler, not to this gesture-less path.

## register

A resolved fetch is not a saved subscription. Fetch settles normally for a 4xx, and an expired session answers this POST with a redirect to /login that fetch would otherwise follow to a 200. `CodeGymRequest.send` reports both as not `ok`, the redirect through `response.redirected`, and `register` rejects on either with the module's `message`: the shared session-expired sentence after a redirect, the server's own sentence when it wrote one, and `push.register_failed` otherwise. Without them the enable flow reloads after a failed enrolment and leaves the user looking at an unchanged toggle with nothing explaining why.

## Launch re-subscribe

Re-subscribing needs no user gesture, because permission is already granted by the time it runs.

## Re-subscribe catch

The catch covers permission revoked in OS settings or an unreachable push service. There is nothing useful to tell the user mid-page.

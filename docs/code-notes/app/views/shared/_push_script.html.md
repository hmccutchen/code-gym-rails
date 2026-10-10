# app/views/shared/_push_script.html.erb

## The partial as a whole

This is the shared push plumbing: the capability test, subscribing, and registering with the server. The layout renders it ahead of `yield :page_scripts`, so the Account page's enable button can rely on `window.CodeGymPush` existing by the time its own script runs.

It never requests notification permission. That call has to happen synchronously inside a real click handler (see `accounts/_push_reminders`), and nothing here runs from one.

## register

A resolved fetch is not a saved subscription. Fetch settles normally for a 4xx, and an expired session answers this POST with a redirect to /login that fetch would otherwise follow to a 200. `redirect: "error"` and the `response.ok` check make both reject. Without them the enable flow reloads after a failed enrolment and leaves the user looking at an unchanged toggle with nothing explaining why.

## Launch re-subscribe

Re-subscribing needs no user gesture, because permission is already granted by the time it runs.

## Re-subscribe catch

The catch covers permission revoked in OS settings or an unreachable push service. There is nothing useful to tell the user mid-page.

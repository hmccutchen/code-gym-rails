# app/javascript/code_gym/draft_store.js

## Purpose

Keeps one copy of the dashboard's unsent answers on the device, so text typed
while the connection was down survives the page being closed or killed. The
answer form writes it on every edit, restores it on the next load, and clears
it once the server has the same answers. Design and tradeoffs:
`docs/offline-answer-saving-2026-10-12.md`.

## localStorage, one key

localStorage, because iOS drops a home-screen app's sessionStorage when the
app is killed, and a killed app is the case this exists for. One key, because
only one day's form is ever open: a copy from any other day or set fails the
restore check and is deleted on the next dashboard load. Within the same set,
the answer form also restores a copy whose save landed without a reply; its
code note says when.

## Cleared on every signed-out page

The app runs on shared devices. Logging out lands on the login page, and the
layout marks every signed-out page with `data-signed-out-page` on `<body>`, so this
module deletes the copy there. That also covers a session that expired: the
copy is gone, and with it any text that never reached the server.

## Cleared on a submitted dashboard

A submitted day takes no more saves, so a copy left behind by another tab, or
by a tab that never heard its own submit's reply, can never be sent. The
submitted dashboard has no answer form to clear it, so it renders a
`data-submitted-day` marker and this module deletes the copy when it finds one.

## Every access is wrapped

Private browsing, a full quota or blocked site data can make localStorage
throw. The page then works as it did before this module existed. `write`
returns whether it stored the copy, so the answer form promises the answers
are kept on this device only when they are.

## `clearIf`

Every dashboard tab shares the one key, so a tab clears the copy only when the
stored copy is the one it owns or sent; the test is the caller's, since only
the answer form knows what it sent.

# app/javascript/code_gym/push.js

## What it owns

Everything both push controllers share: the capability test, the VAPID key
conversion, the subscribe call, and the enrolment request.

## Why a module rather than a base controller

The two callers do different jobs — one runs on launch and stays silent, one
runs in a click and reports every outcome — and share only the mechanics. A
module keeps the shared half in one place without tying the two controllers'
lifecycles together.

## subscribeAndRegister returns null for a known endpoint

The server renders the endpoints it already holds. A launch that produces one
of them needs no write, so the function returns `null` and the caller sends
nothing. That is what keeps the every-launch re-subscribe from being a write on
every page load.

## Only the Turn on click changes account intent

`subscribeAndRegister` defaults `enroll` to false. The launch controller and
the device-permission repair path register transport only; `push-enable`
sends true only for Turn on. The server checks the current reminder level
under the user lock, so a delayed repair cannot undo Turn off. A refused
repair stays silent on launch and uses the server's message on the Account
page.

## A subscription made with another key is replaced

A browser subscription keeps the VAPID public key it was made with, and `subscribe()` rejects a different key while that subscription exists (`InvalidStateError`). After a key rotation, every device that had reminders on would fail to resubscribe, on launch and from the Account page, until its site data was cleared. `subscribeReplacingAnotherKey` catches that one error, unsubscribes the existing subscription and subscribes once more. It reacts to the browser's refusal rather than comparing keys, so it works where a subscription does not expose `options.applicationServerKey`, and a same-key subscribe never unsubscribes.

## failure marks a sentence meant for a person

`failure(text)` stamps `readable` on the error it builds. Anything thrown
without that mark is a browser or network error whose text must never reach the
page, so a caller shows its own generic sentence instead.

## It sends through the request module

Enrolment goes through `code_gym/request`, so the CSRF read, the signed-out
case and the error rule are the ones every other request on the page uses. A
4xx and a redirect to a signed-out page both count as failure, which a bare
`fetch` would not.

# app/javascript/controllers/push_enable_controller.js

## What it owns

The Account page's "Turn on daily reminders" button: the permission request,
enrolment, and every sentence shown beside it.

## requestPermission must stay the first statement

iOS grants a prompt only to a permission request made synchronously inside the
user gesture, and fails silently otherwise — no prompt and no error. So
`enable` calls `Notification.requestPermission()` before it touches the button
or the status line, and the VAPID key arrives as a value on the element rather
than through a fetch that would have to precede the call.

## The button renders disabled

The controller arrives with the rest of the page's JavaScript, so a click
landing before it connected reached no action and did nothing. That first
click is the one that matters: the permission request has to run inside the
gesture, so it cannot be replayed once the controller arrives. The partial
renders the button `disabled`, and `connect()` enables it only when
`push.supported()` passes. On a browser without push it stays disabled beside
the sentence saying why.

## Capability is tested, not sniffed

`push.supported()` asks for `PushManager`, which on iOS is simply absent
outside a Home Screen app. That is the fact worth knowing and it stays true
however a given release reports itself. The user-agent test is used only to
choose between two sentences, never to decide what to attempt.

## readable marks a sentence meant for a person

`push.failure` stamps `readable` on the errors this controller raised itself.
Anything without it is a browser or network error whose text must never reach
the page, so it shows the generic failure sentence.

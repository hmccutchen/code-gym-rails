# app/javascript/controllers/push_launch_controller.js

## What it owns

The re-subscribe on launch: an enrolled user's browser hands back a fresh
endpoint, which is how an iOS subscription dropped by the OS repairs itself
without asking for permission again.

## It renders only for an enrolled user

`shared/_push_script` mounts it only when `push_reminders_enabled?`, so a
signed-out or un-enrolled visitor runs nothing. The server also renders the
endpoints it already holds, and `code_gym/push` skips the write when the
browser returns one of them.

An open page outlives that check, so its registration never enrolls
(`enroll` stays false) and the server refuses it once reminders are off.

## Failures are silent on purpose

Nothing on this page asked for a subscription, so there is nowhere honest to
report a failure to. The Account page is where push state is shown and
repaired, and the next launch tries again.

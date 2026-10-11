# app/javascript/controllers/name_editor_controller.js

## What it owns

The name field in the global navigation bar, on every signed-in page: the
save on blur, the confirmation or error line, and reverting the field when a
save is refused.

## It saves through the queue, not a bare request

`saveStatus.queue("name", …, { latest: true })` collapses overlapping saves to
the latest, so a fast second edit cannot land behind the first and resurrect
an older name. `quiet: true` keeps the field's own status line as the only
report; the shared banner would say the same thing twice.

## The synchronous queued() check

After a save returns, `saveStatus.queued("name")` decides whether this reply is
still the last word. A later save already waiting means this reply's value is
stale, so the field is left alone for that save to settle. The check has to be
synchronous, which is why the save-status module is a plain object rather than
something that answers asynchronously.

## connect() reads defaultValue, not value

A name typed and blurred before the controller connects reaches no action, so
the edit lives only in the field. Reading `value` on connect recorded it as the
last saved name, and every later save then matched `lastSaved` and returned
early — the name was silently dropped. `defaultValue` is the server-rendered
name, so a difference means the user typed, and connect saves it.

## An empty name is a revert, not a save

Clearing the field and leaving it restores the last saved name without a
request. The server refuses a blank name anyway; reverting locally keeps the
page from showing an error for something the user can only have meant as a
clear.

## A save never writes over text typed after it

The field stays editable while a save is out, and a save that lands replaces
the field with the name the server returned. Someone who typed `Alice`,
blurred, and kept typing saw the field snap back to `Alice` when the first
save answered. So `save()` records the text it posted and writes the server's
answer back only while the field still holds it.

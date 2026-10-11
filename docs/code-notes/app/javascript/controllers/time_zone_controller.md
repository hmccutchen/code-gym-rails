# app/javascript/controllers/time_zone_controller.js

## What it owns

One job: on a page load for a user with no stored time zone, send the zone the
browser reports.

## It renders only when the zone is blank

The layout mounts this controller only for a user whose `time_zone` is blank,
so a detected zone never overwrites one the user chose on Setup. The condition
lives in the view rather than here because the controller cannot see the stored
value.

## It is quiet

The save goes through `saveStatus.queue` with `quiet: true`: nothing on the
page asked for it, so a failure has nothing to report to and the next page load
tries again.

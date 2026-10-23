# app/javascript/controllers/generating_controller.js

## What it owns

A poll that reloads the page once the server says the work it is waiting on
has finished, and shows a slower-than-expected hint once the attempts run out.
Two views mount it. The dashboard's "generating" panel polls
`GET /dashboard/status` until the day's set lands or the attempt fails.
`responses/_review_in_progress` polls `GET /responses/:id/review_status` until
the review claim is released or goes stale. Each view supplies its own URL,
interval, attempt budget and hint; the controller knows neither.

## The IIFE is gone

The inline version wrapped itself in an IIFE because a retry could render the
same script again and top-level `const` would redeclare. A controller has no
such problem: each element gets its own instance, and Stimulus tears the old
one down. The `DOMContentLoaded` wrapper is gone for the same reason —
`connect()` already runs with the element in the document.

## stopped

`poll` awaits a request, so a reply can land after the element has left the
page. `disconnect()` sets `stopped`, and `poll` checks it after the await, so
a late reply cannot reload the page or schedule another attempt.

## The budget stays in Ruby

`maxAttempts` is computed in the view from `CallProfiles::JUDGED_GENERATION_BUDGET`
and `DailyExercise::REGENERATION_STALE_AFTER`. Those are the authorities for
how long a generation may take, and the controller reads the answer rather
than deriving one.

## The reload waits for other saves

On the submitted dashboard the review poll shares the page with the daily
cards' swaps. Its reload goes through `saveStatus.leaveWhenSaved`. While
another save is pending or has failed, the leave is held and stays armed, so
the page reloads once that save lands.

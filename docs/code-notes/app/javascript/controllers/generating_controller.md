# app/javascript/controllers/generating_controller.js

## What it owns

The dashboard's "generating" panel: the poll against `GET /dashboard/status`
that reloads once the day's set lands or the attempt fails, and the slower-
than-expected hint once the attempts run out.

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

`maxAttempts` is computed in the view from `AiService::JUDGED_GENERATION_BUDGET`
and `DailyExercise::REGENERATION_STALE_AFTER`. Those are the authorities for
how long a generation may take, and the controller reads the answer rather
than deriving one.

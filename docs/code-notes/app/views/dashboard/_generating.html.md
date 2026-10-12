# app/views/dashboard/_generating.html.erb

## The controller

`data-controller="generating"` drives this panel;
`docs/code-notes/app/javascript/controllers/generating_controller.md` covers
the poll, the teardown flag and why the IIFE and the `DOMContentLoaded` wrapper
are gone.

## Attempt cap

`maxAttempts` derives from the poll interval and the larger of
`AiService::JUDGED_GENERATION_BUDGET` and
`DailyExercise::REGENERATION_STALE_AFTER`, so a slower judged day never times
the panel out before the job it is waiting on can finish. The view computes it
because those constants are Ruby's.

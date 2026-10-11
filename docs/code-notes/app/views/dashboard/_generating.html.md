# app/views/dashboard/_generating.html.erb

## Starting the poll

The first `setTimeout(poll, …)` waits for `DOMContentLoaded`. `poll` reads
`CodeGymRequest`, which `application.js` puts on `window` from a deferred
module, and a deferred module runs after the document is parsed — later than
this inline classic script. The poll interval is seconds, so the module has
almost always loaded by the first tick, but "almost always" is the shape of
bug that shows up on a cold cache on a slow connection, which is exactly the
load this panel is rendered on.

The wait costs nothing here: the panel is a spinner, and the user has nothing
to do until the set arrives.

## Attempt cap

`MAX_ATTEMPTS` derives from the poll interval and the larger of
`AiService::JUDGED_GENERATION_BUDGET` and
`DailyExercise::REGENERATION_STALE_AFTER`, so a slower judged day never times
the panel out before the job it is waiting on can finish.

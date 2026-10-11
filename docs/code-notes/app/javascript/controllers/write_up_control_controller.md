# app/javascript/controllers/write_up_control_controller.js

## What it owns

Learn's "write this up" controls: the request that queues the job, the poll
that waits for it, and the three endings — reload, redirect, or a failure
sentence.

## It polls because the write is a job

The generation runs in Solid Queue, so nothing comes back on the request that
starts it. The attempt ceiling is computed in Ruby from the poll interval and
`AiService::CONCEPT_REFERENCE_READ_TIMEOUT`, so the page gives up when the call
behind it can no longer be running rather than after a number chosen here.

## rewritten is a separate ending from ready

A rewrite that completed without producing the field being waited on sends the
page to `rewrittenUrl`, which carries `<awaiting>=missing`, and the page then
says the field did not come back. Reloading in place would show the same
control again with nothing explaining why.

## A failed poll retries; a failed job does not

A poll that cannot reach the server tries again until the attempt ceiling. A
poll that comes back saying the job failed shows the server's sentence and
re-enables the button, since the next attempt has to be the user's.

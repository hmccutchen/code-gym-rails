# app/views/learn/_write_up_control.html.erb

## Inline script

The script is inline because the layout emits no importmap tags, so nothing
else would run. It polls for the result rather than holding the request open,
because this generation runs with extended thinking on.

## Poll interval and attempt cap

The 2-second interval is the one place that number lives. `MAX_ATTEMPTS`
derives from it and from
`AiService.call_budget_seconds(CONCEPT_REFERENCE_READ_TIMEOUT)`, the worst-case
time a concept-reference call can take across every retry it is allowed. This
follows `dashboard/_generating.html.erb`: a hardcoded attempt count had no
relationship to how long the job could actually run.

## `poll`

The bulk actions and this per-concept job share the default queue against
three worker threads, so a slow batch can leave this job still queued when the
budget runs out. That is the likeliest state when the cap is reached, rather
than a dead job. A rewrite that landed without its ladder is different: the job
has finished, so the page reloads to show the new text and says what happened.

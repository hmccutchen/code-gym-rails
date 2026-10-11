# app/views/learn/_write_up_control.html.erb

## Behavior lives in the controller

The request, the poll and its endings belong to `write-up-control`; see
`docs/code-notes/app/javascript/controllers/write_up_control_controller.md`.
This partial only renders the control and the values the controller reads.

## Poll interval and attempt cap

The 2-second interval is the one place that number lives. The attempt cap
derives from it and from
`AiService.call_budget_seconds(CONCEPT_REFERENCE_READ_TIMEOUT)`, the worst-case
time a concept-reference call can take across every retry it is allowed. This
follows `dashboard/_generating.html.erb`: a hardcoded attempt count had no
relationship to how long the job could actually run.

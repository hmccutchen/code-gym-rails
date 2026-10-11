# app/services/response_review.rb

Applies a review to a submitted response: takes the review claim, asks the
provider for the sections still missing, stores the results and failures,
records mastery, and reports what happened as an `Outcome`. It knows nothing
about HTTP; `ResponsesController#review` turns each outcome into a redirect
and a message.

## `#reviewer`

Built inside `#call` rather than in the constructor, because `AiService.for`
can raise for an ended trial, and that has to come back as a
`:provider_error` outcome like any other provider failure.

## `#call`

The claim makes a second click back off instead of making a second provider
call. It is released with its own token on every exit that still owns it, an
unexpected error included, so a review that overran its window can't clear
the claim of the one that took over.

The missing sections are counted again after the row is reloaded under the claim:
another request may have finished the last section between the first check
and the claim.

The response is locked before the results are written. Start over and
regeneration refuse while the claim is fresh, but once it goes stale either can
destroy the row during the provider call, which comes back as `:set_cleared`.

## `#store`

Re-checks the claim under the response lock before writing anything. A review
that overran its window may find another review has taken the claim over; it
then writes neither grades nor mastery, leaves the claim alone and reports
`:busy`, because the review that now holds the claim will grade the same
sections. Without the check both would record mastery for the same answers.

## `#after_review`

A reviewed day can't be regenerated, so an earlier regeneration error would
otherwise ask for a retry that is impossible.

## `#log_diagnostics`

Pairs the AI and self ratings per section, to read beside
`AiService#log_difficulty_diagnostics`. Remove it once that question is
settled.

It logs `daily_exercise.date` rather than `response.date`, because the
response's date can fall a day after the generation event it correlates with.

## `#log_pseudocode_diagnostics`

The counterpart to `AiService#log_pseudocode_critique`. It logs counts and
flags only, never pseudocode or critique text.

## `#graded_missed`

The prose judge may have merged the stored missed points, so this reads the
grader's originals under `graded_prose` when they exist.

## `#stored_failure`

Uses the section's own failure time, since the review as a whole waits for its
slowest section.

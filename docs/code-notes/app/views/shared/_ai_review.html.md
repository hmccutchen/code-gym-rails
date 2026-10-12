# app/views/shared/_ai_review.html.erb

## Difficulty note

The difficulty note sits directly under the grade badge because it is context
for reading that grade and nothing else. It is never a badge of its own: a
second pill beside the first would read as a second score about the engineer,
which is the one thing it must not be. It is read through
`DailyResponse#difficulty_for`, which drops a level this app has no
vocabulary for.

## Controllers mounted per reviewed section

This partial loops over a response's reviewed sections, and it can render once
per history entry, so a page holds one pair of controls for every reviewed
section of every entry shown. The alternates and follow-ups controls are
Stimulus controllers (`review-alternates`, `follow-ups`), so each section's
markup mounts its own instance and no shared script has to be emitted once or
guarded against wiring a control twice. Several instances in one entry are
expected; deduplicating them would leave sections without their controls.
`spec/requests/history_spec.rb` counts three follow-ups mounts because its
fixture has three entries with one reviewed section each.

## Alternate status line

The status line is set after an alternate lands and never cleared, because the
explanation itself is inserted outside the live region; the rule lives in
`review_alternates_controller.js`. The concept
reference's alternates use the same pattern.

# app/views/shared/_ai_review.html.erb

## Difficulty note

The difficulty note sits directly under the grade badge because it is context
for reading that grade and nothing else. It is never a badge of its own: a
second pill beside the first would read as a second score about the engineer,
which is the one thing it must not be. It is read through
`DailyResponse#difficulty_for`, which drops a level this app has no
vocabulary for.

## Controllers mounted per entry

This partial can render once per history entry, up to one per reviewed session
on the page. The alternates and follow-ups controls are Stimulus controllers
(`review-alternates`, `follow-ups`), so each entry's markup mounts its own
instance and no shared script has to be emitted once or guarded against wiring
a control twice. `spec/requests/history_spec.rb` counts one follow-ups mount
per reviewed entry.

## Alternate status line

The status line is set after an alternate lands and never cleared, because the
explanation itself is inserted outside the live region; the rule lives in
`review_alternates_controller.js`. The concept
reference's alternates use the same pattern.

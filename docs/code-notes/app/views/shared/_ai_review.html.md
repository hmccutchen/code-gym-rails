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

## Glossary terms in the review

The review's prose renders through `glossary_wrap`: every field and point,
the difficulty note's reason, and the saved alternate explanations. The
improved code stays out, since the wrapper never touches code, and so do the
follow-up turns, which are the engineer's own questions and the answers to
them. A review is only shown after submission, so a definition here can't
hint at an answer the way one on the unsubmitted form could (#564). Each
field wraps on its own, so a term is underlined once per field.

## Caps and the follow-up thread

Whether the "explain differently" button and the follow-up form still show,
and the order of the thread, come from `DailyResponse#alternates_left`,
`#follow_ups_left` and `#follow_up_turns`, the same methods the controller
checks before and after the provider call. The partial keeps no count of its
own. The "used up" message still names `MAX_FOLLOW_UPS_PER_SECTION`, since it
states the cap's number to the reader.

## Alternate status line

The status line is set after an alternate lands and never cleared, because the
explanation itself is inserted outside the live region; the rule lives in
`review_alternates_controller.js`. The concept
reference's alternates use the same pattern.

## Heading color

Each review block carries the slot number of the section it grades, read from
`DailyExercise#active_section_keys`, so its heading takes the same accent as
that section's label above it. The blocks follow the stored review's key
order, which is not page order, so the slot is looked up per section rather
than counted. A review for a section the day no longer shows gets no slot and
keeps the plain accent.

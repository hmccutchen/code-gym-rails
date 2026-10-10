# app/views/shared/_ai_review.html.erb

## Difficulty note

The difficulty note sits directly under the grade badge because it is context
for reading that grade and nothing else. It is never a badge of its own: a
second pill beside the first would read as a second score about the engineer,
which is the one thing it must not be. It is read through
`DailyResponse#difficulty_for`, which drops a level this app has no
vocabulary for.

## Script emitted once per request

This partial can render once per history entry, up to one per reviewed session
on the page. The script is therefore emitted into the layout's shared
`:page_scripts` region, and only on the first render of the partial in a
request, rather than inline, where it would ship one identical copy per entry.

The `:not([data-alt-wired])` and `:not([data-fu-wired])` guards inside the
script still matter. They let the single copy wire the controls that appear in
every entry's markup without wiring a control twice and duplicating its
listener.

## Alternate status line

The status line is set after an alternate lands and never cleared, because the
explanation itself is inserted outside the live region. The concept
reference's alternates use the same pattern.

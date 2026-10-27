# app/models/exercise_section/design_comparison.rb

## `MAX_PIECE_LINES`

Blank lines are not counted. The bound exists to stop a runaway reply; pieces of unequal length are left to the judge's surface-parity check.

## `.answered?`

A pick and any written reason count, however short. There was once a 40-character minimum, meant to keep a bare pick from counting as reasoning, but the page never said so: a short reason saved, then read as skipped after submission. How good the reason is belongs to the grader, whose note already caps a matching pick with a vague reason at developing.

## `.hosted_concepts`

The list is an allowlist, so a concept added to a vocabulary later is not offered for this kind until someone decides it fits.

## `.code_review_overlap_line`

The line keeps a design comparison from restating the code review's defect when both take the same concept. It renders only when `code_review` is requested alongside this kind, so a pair without it leaves the line out. A retry of this kind alone also leaves it out, even on a day with a code review, because `alongside:` holds the kinds requested together, not the day's kinds.

## `.partial_answer`

A pick with no reason returns the pick, and a reason with no valid pick returns the reason, so the review can say what was written even though the section does not count as answered.

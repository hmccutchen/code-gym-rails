# app/models/exercise_section/design_comparison.rb

## `MAX_PIECE_LINES`

Blank lines are not counted. The bound exists to stop a runaway reply; pieces of unequal length are left to the judge's surface-parity check.

## `.answered?`

A pick and any written reason count, however short. There was once a 40-character minimum, meant to keep a bare pick from counting as reasoning, but the page never said so: a short reason saved, then read as skipped after submission. How good the reason is belongs to the grader, whose note already caps a matching pick with a vague reason at developing.

## `.hosted_concepts`

The list is an allowlist, so a concept added to a vocabulary later is not offered for this kind until someone decides it fits.

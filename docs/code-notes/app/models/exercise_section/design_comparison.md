# app/models/exercise_section/design_comparison.rb

## `MAX_PIECE_LINES`

Blank lines are not counted. The bound exists to stop a runaway reply; pieces of unequal length are left to the judge's surface-parity check.

## `MIN_REASON_LENGTH`

Forty characters is about one sentence naming a fact. A pick and a single word is not an answer.

## `.hosted_concepts`

The list is an allowlist, so a concept added to a vocabulary later is not offered for this kind until someone decides it fits.

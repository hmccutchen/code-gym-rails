# app/models/exercise_section/parsons_problem.rb

## `ExerciseSection::ParsonsProblem`

Blocks are stored in their correct order, so a correct answer is the identity permutation and grading never has to ask the AI whether an order is right.

## `TOKEN_LENGTH`

Sixteen characters is long enough that guessing a token isn't worth trying, and short enough to read in a DOM inspector.

## `.arrange!`

The scramble is rolled once at ingest and persisted as `display_order`, so every view shows the same scramble. It is never the identity order, which would be pre-solved.

## `.fixed_rating`

The computed rating replaces whatever the grader returned. It is nil when the section has no blocks, because an empty block list would otherwise read as a perfect score.

## `.block_token`

Tokens are opaque so that sorting the blocks by token cannot solve the puzzle. The HMAC also signs a digest of the problem, because regeneration reuses the exercise row and a token must not carry over to a different puzzle.

## `.token_answer`

The page renders the answer as tokens. Rendering the stored positional order beside the tokens would reveal which token maps to which block id.

## `.excluded_vocabulary_keys`

A positional diff cannot grade concepts that have no right or wrong order, so those groups are excluded here. They have other hosts (see `annotate_retention_concept`).

## `.parse_order`

Returns `[]` for a malformed answer, so grading reads it as every block misplaced instead of raising.

## `.normalize_order`

Saved orders arrive as free-form params. A partial order would drop blocks, and the next autosave would persist that loss, so anything that is not a full permutation normalizes to `[]`.

## `.review_context`

The review context has no answer line: Ruby has already graded the order, and a value like `order:2,1` means nothing to the reviewer as prose.

## `.grading_note`

A section can resolve with no blocks. The note then tells the grader to skip grading instead of claiming a verified "0 out of place".

## `.describe_mismatches`

Normalizes and pads the submitted order the same way `.grade` does, so the description the reviewer gets cannot contradict the score.

# app/models/exercise_section/pseudocode_to_code.rb

## `ExerciseSection::PseudocodeToCode`

The kind has no answer scaffold on purpose (`.default_scaffold` returns nil). A labelled scaffold would hand over the decomposition, and producing the decomposition is the exercise.

## `MAX_CRITIQUE_POINTS` and `MAX_CRITIQUE_POINT_LENGTH`

Critique points are provider text rendered into the page, so their number and length are bounded.

## `MAX_PROBLEM_STATEMENT_LENGTH`

`.reject_unusable!` applies this bound on ingest, because the problem statement is rendered and also interpolated into both round prompts.

## `MAX_PSEUDOCODE_LENGTH`

This lives on the kind because both provider calls check it. `ResponsesController` bounds answers only by the wider `MAX_ANSWER_LENGTH`.

## `.translated_before_grading?`

The grade is about the translated code, so translation must finish before the review's day context is built.

## `.diagrammable?`

A diagram would hand over the decomposition this section asks the engineer to produce.

## `.answer_class`

The `code-answer` class is what applies the monospace treatment, as in `Challenge`.

## `.normalize_critique`

The critique is provider text going into the page, so it is bounded the same way `.normalize_scaffold` bounds scaffold labels.

## `.translation_lines`

The second branch covers rows translated from an earlier draft than the final pseudocode. The code stays fenced in both branches, because it carries the plan's text intact.

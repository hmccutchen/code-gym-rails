# app/models/exercise_section.rb

## `.all`

This list sets the enumeration order. Anything that derives a Hash or an Array from it keeps the order it already had, so append new kinds rather than reordering.

## `.thirds` and `.fourths`

These lists are in precedence order, which differs from enumeration order. When a `problem_set` holds more than one third key, or more than one fourth key, the first kind in the list wins.

## `.present?`

A provider can emit a key holding null or a bare string beside the real section, so a key counts as present only when its value is a Hash.

## `.slots`

In a day's plan, every slot except a fixed kind's may be empty, meaning the day does not include it.

## `.rotatable`

A slot holding only one candidate is left out, because a weight there could change nothing.

## `.for_plan`

This works from `DailyPlan`'s rolled symbols, before the provider is contacted.

## `.slot_kinds`

The result is keyed by slot. `.for_plan` drops omitted slots, so reading its result by position names the wrong kind.

## `.slot_kind`

An ineligible rolled symbol raises an `ArgumentError`, because a silently missing section is worse than a failed generation.

## `.find`

`.find` never raises, since a provider can put arbitrary keys in a jsonb payload.

## `.for`

The base class carries every facet's default, so `.for` returns it for an unknown key and callers need no `find(key)&.facet || default` fallback.

## `.excluded_vocabulary_keys`

The exclusion applies at generation time only. Ingest still accepts an excluded concept, since rewriting a real tag would destroy history.

## `.narrow_vocabulary`

A nil rung means the caller does not know the rung. A kind that narrows by level then returns its strictest list.

## `.review_context`

The base class raises because a kind that returned nothing would produce a review missing its context, with no signal that anything went wrong.

## Judge facets

`.judge_task`, `.discovery?`, `.prose_fields`, `.judge_retries`, `.judge_guidance`, `.rejudge_edits?`, `.judge_solve_options` and `.solve_matches_key?` are read only by the judge (`AiService#judge_section`), never by the draft prompt or by grading.

## `.improved_code_label` and `.improved_code_prose?`

The defaults describe corrected source code. A kind whose improvement is prose overrides both.

## `.titled_label?`

This is false for kinds whose `problem_set` entry carries no title of its own.

## `.diagrammable?`

This is false by default, because a diagram is safe to show before an answer only where it restates what is already on screen.

## `.default_scaffold`

A nil default marks a kind that is never pre-filled and never has labels stripped from its answer.

## `.scaffold_template`

The labels are joined with blank lines between them so the scaffold reads as a form to fill in.

## `.decode_answer`

Returning nil drops the section from the payload, rather than storing something unreadable over the draft.

## `.substantive_answer`

Scaffold labels are matched against whole stripped lines, so a label the user edited becomes their own text and counts toward the answer.

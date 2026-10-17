# app/services/generation_prompt.rb

## `#initialize`

The plan, history, difficulty and ladders arrive as whole values, so a new
plan field is read here and nowhere else. No default queries the database:
`DailyPlan.for`, `User#recent_performance`, `KindDifficulty.for` and
`AiService#ladders_for` own those reads, and `generation_prompt_spec` holds
that constructing, rendering and building the schema issue no SQL and mutate
no input.

## `#render`

Renders an already-made decision; nothing here reads the clock or rolls
anything, so a retry renders the same from the same inputs. The kinds are
resolved once per render and handed to the embedded schema, so guidance,
hosting and the schema agree,
and `only` narrows them to the one retried kind. The fixed concept line is
folded onto the drilled-concepts bullet, because an empty interpolation on its
own line would break the prompt snapshots.

## `#schema`

Resolves kinds through the same `#kinds_for` as `#render`, so the schema
cannot ask for a section the guidance did not describe.

## `#retention_block`

The annotation is `AiService#annotate_retention_concept`, bound at
construction, because that method is a curated `RealSource` excerpt and cannot
move here without changing exercise content. It returns nil when no section
today can host the concept, and `filter_map` drops it, so a day with no host
renders no block.

## `#established_block`

Unlike `#retention_block`, never forces a selection: the text shapes a section
only if the model picks one of these concepts.

## `#fourth_retention_block` and `#fourth_established_block`

The same shape as the main blocks with different wording, and the fourth
blocks list plain concept names where the main retention block annotates each
with its hosts. Four rules share one syntax here; they are not one rule stated
four times, so each keeps its own method and heredoc.

## `#annotate_reinforcement`

Shows the tier and `drilled` side by side, so the model can tell the system's
reading apart from the engineer's request.

## `#shared_concept_guidance`

Lists the plan's daily kinds (`DailyPlan::Result#daily_kinds`) and states no count, so a
day without a shared concept renders byte for byte as before. `#render` skips
it on a retry, which asks for one section.

## `#scenario_flavor_guidance`

Uses `AiService::SCENARIO_POOLS.fetch`, so an unknown flavor fails here
instead of rendering an empty list.

## `#scaffolded_kinds_clause`

Built from the registry, since a scaffolding kind left out of a written list
had its labels truncated mid-word (issue #164).

## `#generation_guidance_for`

Forwards the code-review mode to every kind. Only `CodeReview` reads it, which
`generation_prompt_spec` pins at every language, mode and rung, so no kind
branch is needed here.

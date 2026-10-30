# app/models/exercise_section.rb

## `.all`

This list sets the enumeration order. Anything that derives a Hash or an Array from it keeps the order it already had, so append new kinds rather than reordering.

## `.thirds` and `.fourths`

These lists are in precedence order, which differs from enumeration order. When a `problem_set` holds more than one third key, or more than one fourth key, the first kind in the list wins.

## `.present?`

A provider can emit a key holding null or a bare string beside the real section, so a key counts as present only when its value is a Hash.

## `.layout`

The layout's order is the generation prompt's section order and the page's section order. The default pair must therefore come out as `code_review`, `design_comparison`, `pattern`, `third`, `fourth`, exactly the order of the old `.slots`; the prompt and page snapshots hold it, and a change there shows up as a snapshot diff. `docs/decisions/daily-kinds.md` has the full rule.

In a day's plan, every slot except a daily kind's may be empty, meaning the day does not include it.

## `.optional_slots`

A daily fourth-slot kind takes the whole `fourth` slot out, so its siblings never rotate in beside it and a day never holds two fourths.

## `.default_daily`

The registry states which kinds form the default pair, and `DailyKinds::DEFAULT` reads it from here. The dependency runs one way: the registry never reads `DailyKinds`.

## `.pickable`

The kinds a plan can ever hold for a pair: the pair plus every kind in its optional slots, in registry order. A daily fourth's siblings are in no slot, so they are left out. For the default pair it is every kind. `KindPreferences#offered` takes it and removes excluded optional kinds, and keeps only the daily kinds when the Daily sections setting leaves nothing to rotate; `LadderCoverage`, the Progress page and the level-suggestion card read that answer through `KindPreferences.offered_to`.

## `.rotatable`

A slot holding only one candidate is left out, because a weight there could change nothing. It reads the pair's optional slots, so a daily kind is never rotatable.

## `.for_plan`

This works from the plan's daily kinds and `DailyPlan`'s rolled symbols, before the provider is contacted.

## `.slot_kinds`

A rotation naming a slot the pair leaves no room for raises, rather than dropping that kind silently. The result is keyed by slot. `.for_plan` drops omitted slots, so reading its result by position names the wrong kind.

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

`.judge_task`, `.discovery?`, `.prose_fields`, `.judge_guidance`, `.judge_hidden_fields`, `.rejudge_edits?`, `.judge_solve_options` and `.solve_matches_key?` are read only by the judge (`AiService#judge_section`), never by the draft prompt or by grading. How many retries a rejection buys is a plan fact (`DailyPlan::Result#judge_retries`), not a kind facet.

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

## `.refusal_codes` and `.refuse!`

A kind's `.reject_unusable!` refuses through `.refuse!(code, message)`, which raises `ProviderError::UnusableSectionError` with the code `<kind>.<code>`. `.refuse!` raises `ArgumentError` for a code the kind's `.refusal_codes` doesn't list, so the list is every way the kind can refuse. Ingest keeps the code on its `Unusable` entry, and a retry's prompt maps it to a fixed line (`GenerationPrompt::RetryReasons`, #610). A new check needs a code in the list and a line in that table. `refusal_codes_spec` reads each kind's source and fails on a `refuse!` code the list doesn't hold, a listed code no `refuse!` uses, or a plain `InvalidResponseError` raise, which would reach a retry with no code; `generation_prompt_retry_reasons_spec` then fails until the table has the line.

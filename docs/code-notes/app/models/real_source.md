# app/models/real_source.rb

## `WEIGHTS`

One weight covers both grounded modes, `application_code` and `schema_review`. To space excerpts further apart, grow the pool rather than lowering this weight.

## `Excerpt`

An excerpt reads its text off local disk when the prompt is built, so the text is exactly the code that is deployed.

`#current_schema` returns nil on the base class. Only a kind whose snippet is written against a table, `Migration`, overrides it.

## `.pick`

The pick takes never-seen excerpts first, in list order, then the one seen longest ago. That order bounds the longest wait before any excerpt comes round again by the size of the pool.

The retired `SectionCount.capped_window` excerpt was removed with #719's
absence-to-zero inference; the remaining `SectionCount.for` excerpt retired
with the unified workload fold. Remaining entries keep their relative order and
ids; no replacement was inserted into its position. Historical source ids
remain readable and no longer participate in picking.

`GenerateDailyExercisesJob#generate_if_due` retired when the hourly batch
stopped generating sets itself. `#generate_under_claim`, which takes the
user's generation claim around the part that still generates, was appended at
the end of the list as a new entry.

## `.last_seen_for`

A stored id is matched to the current excerpt by file name and method, ignoring the folder, so moving a source file between `app/` folders keeps its rotation history. That only works while file name plus method is unique across the pool, which a spec checks. An id that matches nothing comes back unchanged, and `pick` never asks about it. The reason is in `docs/decisions/folders-by-layer.md`.

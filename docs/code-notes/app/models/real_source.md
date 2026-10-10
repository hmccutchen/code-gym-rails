# app/models/real_source.rb

## `WEIGHTS`

One weight covers both grounded modes, `application_code` and `schema_review`. To space excerpts further apart, grow the pool rather than lowering this weight.

## `Excerpt`

An excerpt reads its text off local disk when the prompt is built, so the text is exactly the code that is deployed.

`#current_schema` returns nil on the base class. Only a kind whose snippet is written against a table, `Migration`, overrides it.

## `.pick`

The pick takes never-seen excerpts first, in list order, then the one seen longest ago. That order bounds the longest wait before any excerpt comes round again by the size of the pool.

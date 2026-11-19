# `DuckAnswer`

One duck reply, and the `DUCK_NARROWING` trial around it, in one object. It
lives in `app/services` because it makes the provider call through
`AiService` and writes the trial's log lines, which are side effects. The
controller hands it the switch value (`DuckNarrowing.enabled?`) and the
section's stored thread, and still stores the reply itself through
`DuckThread.append!`.

## `.ask`

With the switch off it makes today's `AiService#duck_response` call with
`#turns_for` as history and keeps no point, so the request and the stored
turns are byte for byte what they were. With it on, it reads the gate from
the stored thread (`#narrowing_due?`), never from the new message or a posted
`thread`, sends `#turns_for_duck` as history, so the duck sees its own
earlier labels, and calls `AiService#labelled_duck_response` with `narrow:`.
The gate and the last point are read before the reply is stored, from the
same thread the duck is sent, so they describe the history the duck saw.

## `#log_stored`

The controller calls it only after the reply is stored. It writes the
trial's log lines, none with any text. `[duck_point]` goes out for every reply
while the switch is on: `question=` says whether the shown text ends in `?`,
`labelled=` whether a point was parsed, and `matched=` whether it equals the
last stored point. Logging every reply, and not only questions, lets a
cut-off question, which ends in `…`, still count as a dropped label.

`[duck_narrowing]` goes out only for a reply written with `narrow: true`. A
reply that ends in a question gets `quote=found|missing|none` from
`DuckReply.quote_outcome`, against the same `SectionContext.render` text the
duck was shown. A reply that explains directly, a kind 1 answer, gets
`narrowing=skipped` and no quote result, so it doesn't count against the
trial's "In the text" check.

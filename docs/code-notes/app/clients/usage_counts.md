# app/clients/usage_counts.rb

Each provider's `read_usage` builds one `UsageCounts` for the reply it reads
and reads every token count through it (#770). A count that is present but
not an integer from 0 to `ApiUsage.max_token_count` reads as 0, as before,
and so does the whole `usage` block when it is present and is not an object.
Before, the row that followed looked like a real call with fewer tokens, and a
Claude row priced those tokens. Now `#mark` adds `tokens_unknown: true` to the
result, which `AiService.cost_usd` turns into a null `cost_usd`, the same
mark a timeout leaves. The Account page already counts a null cost as
unpriced (`ApiUsage.own_key_totals`, `MonthlySpend`). Gemini and OpenAI rows
are never priced, so on those providers the mark changes only the log.

A count or object is either required or optional, and the provider's
`read_usage` says which with `required: true`. A required one is a field the
provider sends on every finished reply: the `usage` object itself, Claude's
`input_tokens` and `output_tokens`, Gemini's `total_input_tokens` and
`total_output_tokens`, and OpenAI's `input_tokens` and `output_tokens`. When
one of those is absent or JSON null, it still reads as 0, and the counts are
marked unknown, since a row of zeros would look like a free call. An optional
one that is absent or null reads as 0 (or `{}`) and marks nothing: Gemini
leaves out `total_cached_tokens` and `total_thought_tokens` when a call used
none, Claude leaves out its cache counts, and OpenAI can leave out
`input_tokens_details` and either count inside it. A present but malformed
field marks the counts unknown whether it is required or not.

`#uncached` subtracts the cache counts a provider includes in its input
total. When they add up to more than the total, the counts disagree, so the
input count is floored at 0 and the counts are marked unknown, rather than
storing a negative count.

`#sum` adds counts a provider reports apart but a row stores as one, such as
Gemini's output and thought tokens. Two counts that each fit a column can add
up to more than it holds, and `ApiUsage.create!` then raised
`ActiveModel::RangeError`, so `AiService#log_usage` wrote no row. A total
above `ApiUsage.max_token_count` now reads as 0 and marks the counts unknown,
so the call keeps its row. The rescue in `#log_usage` stays as a backstop.

`#mark` logs one `[usage]` warning per call, naming the provider class and
each field that could not be read, never its value, since a malformed field
could hold any text the provider sent.

The object lives for one reply. A service is reused across calls and copied
for each fan-out thread (`AiService#fresh_service`), so the list of problems
is kept here, never on the service.

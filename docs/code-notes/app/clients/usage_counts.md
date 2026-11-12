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

A count that is absent, or JSON null, still reads as 0 and marks nothing.
Gemini leaves out `total_cached_tokens` and `total_thought_tokens` when a call
used none, and OpenAI can leave out `input_tokens_details`.

`#uncached` subtracts the cache counts a provider includes in its input
total. When they add up to more than the total, the counts disagree, so the
input count is floored at 0 and the counts are marked unknown, rather than
storing a negative count.

`#mark` logs one `[usage]` warning per call, naming the provider class and
each field that could not be read, never its value, since a malformed field
could hold any text the provider sent.

The object lives for one reply. A service is reused across calls and copied
for each fan-out thread (`AiService#fresh_service`), so the list of problems
is kept here, never on the service.

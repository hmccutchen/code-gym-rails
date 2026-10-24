# What a usage row records

every provider call writes one `ApiUsage`
row through `AiService#log_usage`, and that row now carries enough to price
it. `model` is the model `#call` routed to (`MODEL_FOR_PURPOSE` /
`DEFAULT_ROUTE`), so it matches those tables and any price list keyed the
same way; the provider is not stored separately because the model name
already says it. `cache_read_tokens` and `cache_write_tokens` are kept apart
from `tokens_in` because Claude's `input_tokens` excludes both and each is
billed at its own rate. On every provider, then, `tokens_in` is ordinary
uncached input, excluding cache writes. OpenAI's `input_tokens` includes
both `input_tokens_details.cached_tokens` and
`input_tokens_details.cache_write_tokens`, so `OpenaiService` subtracts both
and records them separately. Its routed models cache implicitly, regardless
of `cache_system:`, and cache writes cost 1.25 times ordinary input;
`cache_system: false` does not disable that provider default. OpenAI's
`output_tokens` already includes reasoning. Gemini's `total_input_tokens` includes the cached part (a
live repeat of a 14,199-token prompt reported `total_input_tokens` 14,199
with `total_cached_tokens` 8,171), so `GeminiService` subtracts it; Gemini
reports no cache write, so it records 0. Gemini's `tokens_out` is
`total_output_tokens + total_thought_tokens`: its usage reports thinking
apart from output (a live response gave `total_tokens` 736 = 25 input + 193
output + 518 thought), and thinking is billed as output.
Gemini rows from before this under-count output by however much the model
thought and over-count input by whatever was cached, and every row from
before this has a null model and null cache counts: unknown, not zero, and
nothing backfills them, since a user's provider can change.

**A row also records the call's outcome.** `provider` names the provider
class the row was written by (backfilled from `model` for older rows, since
every model name identifies its provider), `http_status` is the reply's
status, `failure` is one of `ApiUsage::FAILURES` or null when the reply was
used, `quota_id` is the limit a 429 named in the provider's own vocabulary
(Gemini's `QuotaFailure.violations[].quotaId`; the first
`anthropic-ratelimit-*-remaining` header reading zero on Claude; the first
`x-ratelimit-remaining-*` reading zero, else the error code, on OpenAI), and
`house_key` says whether a house key paid for it, false until trial mode
arrives. A call that fails before a reply arrives writes one row with zero
tokens, through the same `#log_usage`, from `call_and_log`'s rescue: one row
per call, whatever faraday-retry did inside it, and the write never changes
the error the caller sees. A refusal or truncation is marked on the row its
tokens were billed to. Each `ProviderError` class states its code
(`.failure_code`, inherited unless it states its own), and
`AiService.failure_code_for` reads it.

**A row also records what it cost.** `cost_usd` is priced in `#log_usage`,
at call time, from the provider subclass's `PRICE_PER_MILLION`: one
`AiService::Price` per model, holding US-dollar list rates per million tokens
for input, output, cache writes and cache reads, plus the date someone
checked them. The rates sit on the provider class beside its routes, not in
a domain module, because a list price is a fact about one provider's model,
as its routes are: routing to a new model and pricing it are one edit in one
class, and `ApiUsage` receives a number and never looks a price up. Only Anthropic keys are priced for now (`AiService.prices_usage?`,
true for `ClaudeService` alone): a Gemini or OpenAI row always stores a null
cost, with no warning, until its provider is priced on purpose. Each `Price`
refuses a missing or negative rate when the table is built, so a bad entry
fails at boot rather than inside `#log_usage`. Pricing at call time means a later price change never
rewrites history, as a lookup at read time would. Null means unknown, never
zero: a model with no price writes null and a warning, and every row from
before the column existed stays null. A backfill of the rows that already
named a model was considered and declined, since it needed three providers'
price changelogs for about three weeks of rows that only the operator would
see, and the gap closes on its own when October ends. On a priced
provider, a call with no tokens of any kind costs zero, except a timeout:
the provider may have run and billed part of the call before the read gave
up, so its row stores a null cost (`ProviderError.leaves_tokens_unknown?`,
true for `TimeoutError` alone). A network error stays at zero, since a
refused or dropped connection rarely reached the provider. `model_routing_spec`
fails when a Claude route has no price, or a zero input or output rate, so
routing to a new Claude model means pricing it first. The
figure is a list-price estimate: a free tier, credits or a discount on the
key is invisible to the app.

The Account page reads these costs back. `ApiUsage.own_key_totals` sums
`cost_usd` per provider for the month's own-key rows and counts rows with a
null cost as unpriced, so a Gemini or OpenAI row shows as unpriced instead of
as zero. The weekday projection is not computed there: `MonthlySpend` decides
the month's total and the projection (`docs/code-notes/app/models/monthly_spend.md`).

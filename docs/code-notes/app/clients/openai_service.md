# app/clients/openai_service.rb

## `RETRY_OPTIONS`

Built from `AiService.retry_options`, retrying 429, 500, 502, 503 and 504.
Retry statuses match on the status alone, so a 429 for an exhausted quota
(`insufficient_quota`) is retried like a rate limit before
`#raise_if_out_of_credit` turns it into a `BillingError`.

## `#read_result`

It joins only the `output_text` parts whose text is a string (`AiService#string_field`), so a part whose text is an object, a list or a number is left out of the reply instead of being written into it as Ruby text (#769).

## `#read_usage`

`input_tokens` includes the cache reads and writes in `input_tokens_details`,
so the uncached input is what is left after both, through
`UsageCounts#uncached`. Cache counts that add up to more than the input total
floor the input at 0 and mark the counts unknown, as does any count, or an
`input_tokens_details`, present but malformed
(`docs/code-notes/app/clients/usage_counts.md`).

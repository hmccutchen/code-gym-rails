# app/clients/openai_service.rb

## `RETRY_OPTIONS`

Built from `AiService.retry_options`, retrying 429, 500, 502, 503 and 504.
Retry statuses match on the status alone, so a 429 for an exhausted quota
(`insufficient_quota`) is retried like a rate limit before
`#raise_if_out_of_credit` turns it into a `BillingError`.

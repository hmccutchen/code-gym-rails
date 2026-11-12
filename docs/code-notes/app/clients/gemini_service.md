# app/clients/gemini_service.rb

## `MODEL_FOR_PURPOSE`

Generation and its retry map to `DEFAULT_ROUTE` explicitly, even though an unlisted purpose would fall back to it anyway. Listing them lets the route coverage spec pin both usage labels.

## `MINIMAL_THINKING_LEVEL`

On Gemini, thinking shares the output cap, and Gemini 3 Flash cannot turn thinking off. `minimal` is the lowest level it accepts, so a capped call sends it to leave the most room in the cap for the reply.

## `#retry_delay_from`

Gemini states the wait two ways. `RetryInfo.retryDelay` in the error body is a duration string such as `"39s"`, while the `retry-after` header is whole seconds. The method reads the body's duration first, rounds it up, and falls back to the header.

## `RETRY_OPTIONS`

Built from `AiService.retry_options`, retrying 429, 500, 502, 503 and 504.

## `#read_result`

It joins the text parts through `AiService#joined_text`, so a text part whose text is an object, a list or a number leaves the reply with no text, and the caller raises `InvalidResponseError` (`docs/code-notes/app/clients/ai_service.md`).

## `#read_usage`

`total_input_tokens` includes the cached tokens, so the uncached input is the
difference, through `UsageCounts#uncached`. A cached count larger than the
input total floors the input at 0 and marks the counts unknown, as does any
count present but malformed (`docs/code-notes/app/clients/usage_counts.md`).
A missing or null `usage`, `total_input_tokens` or `total_output_tokens`
also marks them unknown, since Gemini sends those on every finished reply. An
absent cached or thought count is normal and reads as 0. The output column
holds output and thought tokens together, added through `UsageCounts#sum`, so
two counts whose total does not fit the column read as 0 and mark the counts
unknown instead of losing the row.

# app/clients/claude_service.rb

## `#request_body`

When the request carries `max_tokens`, thinking is turned off. A tight cap is shared between thinking and the reply, so with thinking on the model can spend the whole budget before it writes any reply text.

## `#read_result`

A refusal is returned as data in the result hash rather than raised here. That lets `call_and_log` write the usage row first, because a refused request still charges its input tokens.

It reads `content` through `AiService#object_list`, the text block's text through `AiService#string_field` and every token count through `UsageCounts`, in `#read_usage`, so a field of the wrong shape reads as missing instead of raising before the usage row is written (`docs/code-notes/app/clients/ai_service.md`). A count or `usage` block that is present but malformed also marks the call's counts unknown, so its row stores a null cost instead of pricing a count that was never read (`docs/code-notes/app/clients/usage_counts.md`).

## `RETRY_OPTIONS`

Built from `AiService.retry_options`. Claude retries 529 (`overloaded_error`)
as well as 429 and the 5xx gateway statuses the other providers retry, since
Anthropic answers 529 when it is overloaded.

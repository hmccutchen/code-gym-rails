# app/models/provider_error.rb

## Each class carries its own codes

Four places name a provider failure, each for its own reader:

| Class method | Read by | Used for |
| --- | --- | --- |
| `.error_code` | `AiService.error_code_for` | the code a job or log records |
| `.failure_code` | `AiService.failure_code_for` | `ApiUsage#failure` |
| `.judge_fallback_reason` | `AiService.judge_fallback_reason` | why a judge fell back |
| `.failure_kind` | `ProviderFailure.classify` | which explanation a person is shown |

These used to be four `case` tables that switched on the error's class (#442).
Adding a subclass meant remembering all four, and a missed one fell through to
`"other"` without an error. Two tables also had to list a subclass ahead of
its parent (`TruncatedResponseError` before `InvalidResponseError`,
`DeadlineError` before `TimeoutError`). Now each class states the codes that
differ from its parent's and inherits the rest, so a truncated reply is still
an `invalid_response` job error and a deadline still counts as a `timeout`
usage failure, with no order to keep.

`ProviderError` itself holds the defaults: `"other"`, `"provider_error"`, and
nil for the other two. A nil `judge_fallback_reason` leaves the reason to the
HTTP status or the error code. A nil `failure_kind` leaves `ProviderFailure`
to read the status: a 5xx is an outage, anything else `other`.

## What stays a method that takes the error

A rate limit's person-facing kind depends on its status, quota id and retry
wait, so `ProviderFailure.rate_limit_kind` keeps deciding it, and
`RateLimitError` states no `failure_kind`. Likewise the `http_<status>` judge
reason applies only to a bare `ProviderError`, so it stays in
`AiService.http_status_code_for`.

## `provider_error_spec`'s `CODES` table

The spec lists every class with its four codes and fails when
`ProviderError.descendants` holds a class the table doesn't. A new subclass
inherits its parent's codes, so it would never fail silently, but its author
still has to say in the table which codes it carries.

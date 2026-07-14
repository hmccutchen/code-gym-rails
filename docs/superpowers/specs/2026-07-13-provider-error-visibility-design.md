# Surfacing provider API error details to users

## Problem

`AiService::Error` already reaches the user in three places:

- `DailyExercisesController#regenerate` — flash alert
- `ResponsesController#review` — flash alert
- `GenerateDailyExercisesJob` — Turbo Stream broadcast into `dashboard/_generation_failed`

All three already display `e.message` verbatim. But today that message is just
`"Claude API error 429"` or `"Gemini API error 400"` — the HTTP status code,
nothing else. The actual, actionable reason a provider call failed (e.g. "Your
credit balance is too low to access the Anthropic API", "invalid x-api-key
provided") is discarded at the point the error is raised — it's only logged
server-side via the existing `log_raw_snippet` helper, which the user never
sees.

A user hitting a failure today has no way to tell "I'm out of credits" from
"my key is wrong" from "a transient 5xx" without checking their provider's
billing dashboard themselves.

## Goal

Make the message content itself richer, at the source, so the same three
existing surfaces automatically show something the user can act on. No new UI
surfaces, no new error categorization/bucketing — just pass through the
provider's own explanation when one is available.

## Design

### Shared parsing helper (`AiService`)

Add one private helper to the `AiService` base class:

```ruby
# Extracts a provider's own explanation for a failed HTTP response, when one
# is available, so users see actionable detail (e.g. "credit balance too
# low") instead of a bare status code. Falls back to `fallback` whenever the
# body isn't parseable JSON or lacks the expected shape (5xx HTML error
# pages, empty bodies, unrecognized formats).
def extract_provider_message(body, fallback:)
  parsed = JSON.parse(body)
  message = parsed.dig("error", "message")
  message.presence || fallback
rescue JSON::ParserError
  fallback
end
```

Both Anthropic and Gemini nest their error detail the same way —
`{"error": {"type": "...", "message": "..."}}` — so one helper covers both
providers without per-provider branching.

### Provider call sites

`ClaudeService#call` and `GeminiService#call` each already build a fallback
string today (`"Claude API error #{resp.status}"` /
`"Gemini API error #{resp.status}"`). Both switch to:

```ruby
unless resp.success?
  log_raw_snippet("Claude API error #{resp.status} body", resp.body)
  raise AiService::Error, extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
end
```

(same pattern in `GeminiService`, with its own fallback string). The existing
`log_raw_snippet` call is unchanged — the full raw body is still logged
server-side regardless of whether parsing succeeds, preserving today's
debugging trail.

Network-level failures (`rescue Faraday::Error`) and JSON-parsing failures of
a *successful* response (`AiService#parse_json_response`) are untouched —
their messages are already provider-agnostic and descriptive
(`"Network error calling Claude: ..."`, `"Provider returned invalid JSON:
..."`).

### No length cap

The extracted message is passed through as-is, uncapped. (Considered
reusing the existing `RAW_SNIPPET_LIMIT` truncation convention, but provider
error messages are short, human-authored sentences by design — truncation
risk is negligible and not worth the extra logic.)

### Downstream surfaces: unchanged

`daily_exercises_controller.rb`, `responses_controller.rb`,
`generate_daily_exercises_job.rb`, and the `_generation_failed` partial all
already interpolate `e.message` into flash alerts / broadcast content via
plain `<%= %>` — confirmed no `.html_safe` or `raw` anywhere in that path, so
Rails' default ERB auto-escaping already protects against XSS from a
provider-supplied string. No changes needed there.

## Testing

- `spec/services/claude_service_spec.rb` / `spec/services/gemini_service_spec.rb`:
  - New case: stubbed response body is a JSON error object with
    `error.message`; assert the raised `AiService::Error`'s message equals
    that text exactly.
  - Existing cases (non-JSON body `"boom"`, huge plain-text body) must
    continue to fall back to the generic `"<Provider> API error <status>"`
    message unchanged — these are the existing fallback-path assertions and
    should not need modification, only re-verification.

## Out of scope

- Any new UI surface, banner, or dedicated "billing" page.
- Categorizing errors into friendly buckets (credit exhausted / invalid key /
  rate limited / other) with tailored guidance — user explicitly chose
  verbatim pass-through over this.
- Truncation/length capping of the surfaced message.
- Changes to magic-link auth, Resend/SMTP, `/test_login`, the visual-feedback
  work (ActionCable broadcasts, weekday guard, regenerate spinner), or any
  other unrelated area.

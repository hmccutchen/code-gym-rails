# What a person is told when a provider fails

every surface that
rescues a `ProviderError` classifies it with `ProviderFailure.classify`
(pure: `daily_limit`, `short_rate_limit`, `bad_key`, `out_of_credit`,
`outage`, `timeout`, `other`) and renders the class through
`ProviderFailureText`, whose words live in the `provider_failures` locale
table, one entry set per kind and per credential variant (`own_key` now;
`trial` is added by text alone). Nothing passes an error's message to a
user any more: not a flash, a JSON `error`, the dashboard's generation
panel, the status endpoint or Learn's status line. A sentence names the
provider's label, what did not happen on that surface
(`provider_failures.outcomes`), what is still there (`provider_failures.saved`),
the reset and the next step; it can carry no provider text, status code,
socket detail or key, and `provider_failure_text_spec` holds every kind on
every surface to that.

**Page scripts show only the app's own words.** A fetch that fails can
reject with the browser's text ("Failed to fetch"), land on an HTML error
page whose parse error names a token, or come back as the JSON Rails writes
for an unhandled exception, whose `error` is a status phrase and whose
`status` is a number. Every JSON error the app writes goes through
`JsonErrors#render_json_error`, as `{status: "error", error: "…"}` plus any
keys the caller needs (a stale save says `"stale"`), so the string status
is what marks a reply as the app's own. Every page script sends through
`CodeGymRequest.send` (`app/javascript/code_gym/request.js`), which reads the CSRF
token safely, never throws, and returns `{ok, status, data, message,
signedOut}`. Its `message` is the reply's `error` when `status` is a
string, "your session expired" when fetch followed a redirect, and the
caller's fallback otherwise, so no script decides on its own what a failure
may show. `spec/system/server_message_spec.rb` drives each of those replies
through the thinking partner, and `spec/system/request_module_spec.rb` holds
the module itself. The sign-up form's refused address gets
`sessions.email_not_accepted` rather than the validation exception. A save
with no reply at all (`status` 0) is the one case the dashboard words for
itself: its autosave and submit say the answers are kept on this device
(see `offline-answer-saving.md`).

**Rendered when read, not when written.** A failed generation stores its
class, provider, time and requested wait (`users.last_generation_failure`,
`last_generation_failure_provider`, `last_generation_failed_at`,
`last_generation_retry_after`) and `User#generation_failure_message` writes
the sentence for the page or `/dashboard/status` in the user's zone against
the clock, through `ResetClock`: a daily limit resets when the provider
class's `daily_quota_reset_at` says (Gemini's quota day ends at midnight
Pacific; the base class gives a day), a short limit after the wait the
provider asked for or a minute, and once the reset has passed the sentence
says the limit has reset rather than naming a time behind the reader.
The provider is stored because `call_and_log` stamps every
`ProviderError` with the provider whose call raised
(`ProviderError#provider`), and a user can switch keys before reading:
the sentence names the provider that failed, and a stored failure with no
provider reads as the current one.
`last_generation_error` keeps text that is not a provider failure (a
reviewed set kept, an unusable draft, every section rejected) and rows from
before the columns existed, which render as they did. A failed review
section stores `{kind, provider, quota_id, retry_after, at}` in
`review_errors`, never the message; the submitted dashboard renders the
newest one beside the retry button; a row with no `kind` reads as
`other`.

**Out of credit is never a rate limit.** Per platform.claude.com's error
and rate-limit pages, Anthropic returns a 402 `billing_error`, a 400 whose
message begins "You have reached your specified ... API usage limits" or
names the credit balance, or a 429 whose `details.error_code` is
`enforced_spend_limit_reached` with no `retry-after`; OpenAI returns a 429
whose `error.code` is `insufficient_quota`. Each provider raises
`ProviderError::BillingError` for those before a 429 can become a
`RateLimitError`, so waiting is never advised for an empty balance. A
per-day quota id or a wait of an hour or more makes a 429 a daily limit;
any other is a short one.

**Learn keeps a failure per user, not on the shared row.** A failed
write-up is noted in the Rails cache by user and concept
(`ConceptReferenceFailures`, `EXPIRY` one hour, shorter than any quota's
reset), with the provider the job used, and `/learn/:bucket/:concept/status` returns `failed` and the
sentence, on which the page stops polling. Production's cache is Solid
Cache in the one Postgres database, shared by web and worker, which is what
lets the worker's job write what the web reads; development's memory store
is per process, where the jobs run in the web process anyway. Asking for
the write-up again clears the note, and so does a write-up landing.

A setup problem is not a provider failure, and it is not worded as one
(#443). `AiService.for` raises `SetupError` for a user with no recognized
provider, or with the test-only fake provider outside a local environment;
`LanguagePrompts.for` raises it for an unsupported generation language, and
`ConceptVocabulary::UnknownLanguage` is one too. No provider was called in
any of these cases, and none is reachable through the app:
`require_provider` sends anyone without a usable key to Setup, and `User`
validates `provider` and `language`.

`SetupError` sits outside the `ProviderError` family, but every boundary
rescues it next to `ProviderError` and records or renders it the same way.
That's deliberate: a page waiting on a job only stops waiting when a
failure is recorded, and the dashboard re-enqueues generation on every
load until one is. An earlier version let these errors fail unrescued,
which left the dashboard and Learn polling with no end. `ProviderFailure`
classifies it as `setup`, whose wording points at Setup and never names the
provider. Each boundary logs it at error level with the user's id, which is
the only place it shows up, since the app reports to no error tracker.

The hourly batch rescues any error per user, logs it with the user's id and
moves on, so one broken account can't stop generation for the users after
it.

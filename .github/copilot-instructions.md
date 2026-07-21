# Code Review Guidelines

These guidelines exist to catch real problems before they ship, not to enforce
style preferences. A good review finds correctness issues, security gaps,
performance traps, and architectural holes — in that order of urgency, but
covering all four before approving.

What this project is

A Rails 8 app that generates personalized daily coding-practice exercises via an AI provider (Anthropic or Gemini), reviews submitted answers, and adapts future exercises based on performance history. Each user brings their own encrypted API key — there is no shared/admin key anywhere in this codebase.

Stack: Rails 8.0.5, PostgreSQL, Solid Queue (background jobs, no Redis), Faraday for all AI provider HTTP calls (not the official Anthropic SDK, by design — this keeps provider logic swappable). No JS framework — inline tags are the established convention for client-side behavior.

Non-negotiable checks on every generated or reviewed change

Correctness

Every new behavior must have a corresponding test (request/model/service/ job spec, matching whatever the touched code already uses). A PR that adds behavior with zero test coverage must be flagged as blocking, not a nit.
Do not weaken or delete an existing assertion to make a test pass. If a test needs to change, the reasoning must be stated explicitly.

Security

Any new user input reaching a query, shell command, file path, or rendered view must be validated/sanitized. Flag raw string interpolation into SQL or shell commands as blocking, always.
Authorization, not just authentication: any new controller action must confirm the current user is allowed to access that specific record, not just that they're logged in. current_user being present is not authorization.
Never allow an API key, encrypted or not, to be logged, rendered in a view, or included in an error message. Provider keys must only ever pass through the encrypted api_key column and the request headers built in app/services/\*\_service.rb.
Never approve a change that reads or transmits another user's api_key, email, or personal data without an explicit, visible authorization check.

Performance

Flag any .each/loop that triggers a query per iteration — check for missing includes/preload. This project's data is currently small-scale (one row per user per weekday), but the habit matters — flag it regardless of current data volume.
Flag any new where/find_by on an unindexed column.
Flag any synchronous external HTTP call (AI provider, email) added directly in a controller action rather than a background job — this project's convention is Solid Queue jobs for anything provider-facing or email-facing that isn't already justified as needing to block (e.g. explicitly synchronous by design, like the "anonymize on delete" flow).

Architecture — apply this project's actual conventions, not generic advice

AI provider logic belongs in app/services/ai_service.rb (shared/base logic: prompt-building, schema, error types) and its subclasses (claude_service.rb, gemini_service.rb — provider-specific HTTP/auth only). Flag any AI-calling code that bypasses this — e.g. a controller building its own Faraday request instead of going through AiService.for.
Concept vocabularies (RAILS_CONCEPTS, JS_CONCEPTS, and any other closed vocabulary) are deliberately closed Ruby constants, not free-form strings and not a database-editable list. Flag any change that lets a concept tag bypass normalization against the fixed vocabulary — this is intentional, not an oversight, and exists to keep concept history comparable over time.
Date.current/"today" logic must resolve inside the user's timezone (Time.use_zone), never assume server/UTC time, for anything user-facing. Flag any new "today" computation that doesn't go through the existing zone-wrapping convention (ApplicationController#use_time_zone).
Magic-link auth, session handling, and the SMTP/Resend configuration are considered stable, load-bearing infrastructure. Any change touching SessionsController, ApplicationMailer, or config/environments/\*.rb's mailer settings must be flagged for extra scrutiny, and must not be bundled into an unrelated feature PR.
Never regenerate or duplicate an existing shared partial/component. If a rendering already exists for "show one day's response + review," reuse it; flag any PR that forks a second copy of existing view logic.

Failure handling

Any new call to an AI provider must handle failure without crashing the request that triggered it (rate limits, auth failures, malformed JSON are expected, ongoing realities of this integration, not edge cases). Flag any new provider call with no rescue/error path.
Background jobs that call an AI provider must fail silently from the user's perspective (log and move on) unless the spec/PR explicitly says otherwise — a failed background generation must never surface as a user-facing crash.
Style conventions specific to this repo
Predicate methods follow the existing reviewed?/submitted? naming style — boolean methods end in ?, and check for the existing method before adding a new one that duplicates logic.
jsonb columns (problem_set, ai_review, concept_tags) are the established pattern for exercise/response data that varies in shape. Don't introduce a new normalized table for data that's naturally scoped to a single user's single day unless there's a stated reason a jsonb column won't work (e.g. data shared across users, like ConceptReference).
Old data must never break on a new field. Any new jsonb key must be read with a nil-safe guard (.presence, safe navigation) everywhere it's displayed or used in logic — flag any read that assumes a new field exists on historical rows.
When reviewing a pull request specifically
State explicitly whether each of the sections above was checked, not just general impressions of code quality.
A PR can be approved with unresolved style nits. A PR must not be approved with an unresolved item from Security, Failure handling, or the Architecture checks above — treat those as blocking regardless of how small the rest of the diff is.
If a PR's stated purpose doesn't match what the diff actually does, say so explicitly before evaluating the diff on its own terms.

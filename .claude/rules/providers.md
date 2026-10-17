---
paths:
  - "app/services/{ai_service,claude_service,gemini_service,openai_service,fake_service,lazy_cache_store}.rb"
  - "app/models/{ai_provider,api_usage,provider_credential,provider_failure,provider_failure_text,reset_clock,concept_reference_failures,user}.rb"
  - "app/controllers/concerns/{provider_call_limits,provider_failure_rendering,json_errors}.rb"
  - "app/controllers/{application,api_keys,responses,concept_references,daily_exercises}_controller.rb"
  - "app/helpers/generation_failure_helper.rb"
  - "app/javascript/code_gym/request.js"
  - "config/initializers/filter_parameter_logging.rb"
  - "script/{probe_gemini_capacity,gemini_capacity_probe,check_gemini_structured_output,gemini_structured_output_check}.rb"
  - "spec/fixtures/provider_errors/**"
  - "spec/**/*{_service,provider,api_usage,model_routing,request_characterization,request_module,server_message}*"
  - "app/controllers/{dashboard,learn}_controller.rb"
  - "app/jobs/{generate_daily_exercises_job,generate_concept_reference_job}.rb"
  - "app/views/dashboard/_generation_failed.html.erb"
  - "app/services/response_review.rb"
---

# Providers, keys, usage and failures

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Per-user API keys** (`docs/decisions/per-user-api-keys.md`): Each user
  keeps one encrypted key per provider in `users.api_keys`; a key's prefix
  picks its provider, and `user.provider` names the one in use, so
  `AiService.for(user)` is the only dispatch. Use `User#store_api_key`,
  `User#api_key` and `User#stored_providers`; no keys stores NULL.
  `ResponseReview` sets `daily_responses.review_provider` on every review.
- **Provider abstraction**: `AiService` is a template-method base class owning provider orchestration, JSON parsing, usage logging and every prompt but the generation prompt, which it delegates to `GenerationPrompt`; the concept vocabularies those prompts draw from live in `ConceptVocabulary`. `AiService#call(request)` is the template for the HTTP round trip; subclasses implement `request_body`, `read_result`, `raise_for_status` and `provider_name` behind it, plus `build_connection`, define the `API_URL` it posts to, and own which model each purpose routes to (see "Per-purpose model routing" below). Each call carries one `AiService::Request` built by `AiService.request_for` from the purpose's row in `CALL_PROFILES` (see `.claude/rules/patterns.md`). Adding a provider means adding a subclass and an `AiProvider.all` entry, not editing the base. The registry follows `ExerciseSection.all`'s explicit class-list pattern, so Zeitwerk loads each class when asked rather than relying on subclasses having already registered themselves. `User` validates against its keys and Setup uses the subclasses' key patterns. `FakeService` has no key pattern and is available only in local environments; a manually stored fake provider is still refused in production.
- **Per-purpose model routing**
  (`docs/decisions/per-purpose-model-routing.md`): Each provider routes a call
  by its `purpose` through its own `MODEL_FOR_PURPOSE`, falling back to
  `DEFAULT_ROUTE`; `model_routing_spec` fails on a key with no row in
  `AiService::CALL_PROFILES`. Effort is stated explicitly on each route, so a
  provider default change cannot move it silently. A capped call turns
  thinking off from
  `ClaudeService::THINKING_OFF` (or `OpenaiService::REASONING_OFF`), so a
  capped purpose cannot route to Opus 5.5, and an OpenAI model without `none`
  needs a `reasoning_allowance`. `judge_section`, review and `duck_thread`
  stay on Sonnet as measured decisions; Haiku would end the duck's prompt
  caching. `script/compare_models.rb` runs only Claude, so the OpenAI routes
  are uncompared.
- **Conversational calls send real turns**
  (`docs/decisions/conversational-calls-send-real-turns.md`): `#duck_response`
  and `#answer_follow_up` pass prior turns to `AiService.request_for` as
  `history:`, which becomes the request's `history` field, with only the new
  turn in `prompt` and stable context in `system`. Every other caller leaves
  `history` empty and must stay byte-identical, which the request snapshots in
  `provider_request_characterization_spec` and the single-shot group hold. Of
  the two, only the duck's profile sets `cache_system: true`. Gemini still
  flattens history via `#flatten_history`, a known forgery gap.
- **The duck thread is stored** (`docs/decisions/the-duck-thread-is-stored.md`):
  `DuckThread`, one row per exercise keyed by section, is the one authority for
  a section's turns, user-turn count and version; generation, review, the
  judges, mastery and planning never read it (`duck_thread_isolation_spec`).
  A page showing another set (its draft scope) or behind the stored version is
  told to refresh before the call; the append and Clear run under the user
  row lock, `with_response_locked` and the row lock, and return a named
  outcome (`:deleted`, `:submitted`, `:stale`) when what they read moved.
  Every Clear moves the version, and counts itself when it emptied turns. The
  cap is six user turns a thread, counted on the server, and a posted `thread`
  is ignored. Threads are kept 365 days (`SweepDuckThreadsJob`), emptied on
  start over, deleted on account deletion, and never rendered after submit.
- **Per-user request limits** (`docs/decisions/per-user-request-limits.md`):
  Limits guard a trial's house key, so own-key accounts skip them
  (`ApplicationController#own_key?`). Every endpoint billing one provider call
  declares `ProviderCallLimits`, one shared hourly and daily count that runs
  before every other check. `/generate`, Learn prepare actions and the
  per-user generation job permit apply to all accounts. All use
  `LazyCacheStore`.
- **What a usage row records** (`docs/decisions/what-a-usage-row-records.md`):
  Every provider call writes exactly one `ApiUsage` row through
  `AiService#log_usage`, including a call that fails before a reply (zero
  tokens, from the rescue in `call_and_log(user, request)`). `model` is the
  routed model; `tokens_in` is uncached input, with cache reads and writes in their own
  columns, so each provider subclass subtracts what its API counts inside
  input. `failure` comes from `AiService.failure_code_for`.
- **How a cut-off reply is recognized**
  (`docs/decisions/how-a-cut-off-reply-is-recognized.md`): Providers report
  truncation as data and `AiService#call_and_log` decides it is fatal after
  writing the usage row: Claude `stop_reason == "max_tokens"`, Gemini status
  `incomplete`, OpenAI `incomplete` unless the reason is `content_filter` (a
  refusal). A request with `allow_truncated` set, which only the
  `duck_thread` profile does, shows partial prose. Auth errors go
  through `AiService#raise_if_key_rejected` and never log the provider body.
- **What a person is told when a provider fails**
  (`docs/decisions/what-a-person-is-told-when-a-provider-fails.md`): Every
  surface that rescues an `AiService::Error` classifies it with
  `ProviderFailure.classify` and words it through `ProviderFailureText` and
  the `provider_failures` locale table; no error message, provider text,
  status code or key reaches a user. Page scripts show only
  `CodeGymRequest.send`'s `message`, JSON errors go through
  `render_json_error`, and `AiService::BillingError` is never treated as a
  rate limit.
- **What stays out of the logs**: `config/initializers/filter_parameter_logging.rb`
  filters what engineers write (`answers`, `message`, `question`,
  `pseudocode`, `prior_alternates`, the duck's `thread`), the login `code`
  and the push keys from request logs. Entries match as substrings, so `code`
  is anchored (`/\Acode\z/`); a bare `:code` would also hide `pseudocode`
  and every `code_review` key. The same list is Active Record's
  `filter_attributes`, so these columns also read `[FILTERED]` in `inspect`.
  A reply that can quote an engineer's answer (a review grade, a pseudocode
  critique) is parsed with `log_raw: false`, and jobs log `user <id>`, never an
  email.

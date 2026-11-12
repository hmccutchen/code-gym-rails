---
paths:
  - "app/clients/{ai_service,claude_service,gemini_service,openai_service,fake_service,lazy_cache_store}.rb"
  - "app/prompts/{duck_prompt,follow_up_prompt}.rb"
  - "app/models/{ai_provider,call_profiles,api_usage,monthly_spend,provider_credential,provider_error,provider_failure,provider_failure_text,reset_clock,concept_reference_failures,user}.rb"
  - "app/controllers/concerns/{provider_call_limits,provider_failure_rendering,json_errors}.rb"
  - "app/controllers/{application,api_keys,responses,concept_references,daily_exercises}_controller.rb"
  - "app/helpers/generation_failure_helper.rb"
  - "app/javascript/code_gym/request.js"
  - "config/initializers/filter_parameter_logging.rb"
  - "script/{probe_gemini_capacity,gemini_capacity_probe,check_gemini_structured_output,gemini_structured_output_check}.rb"
  - "spec/fixtures/provider_errors/**"
  - "spec/**/*{_service,provider,call_profiles,duck_prompt,follow_up_prompt,api_usage,model_routing,request_characterization,request_module,server_message}*"
  - "app/controllers/{dashboard,learn}_controller.rb"
  - "app/jobs/{generate_daily_exercises_job,generate_concept_reference_job}.rb"
  - "app/views/dashboard/_generation_failed.html.erb"
  - "app/services/response_review.rb"
  - "app/models/{scheduled_generation,key_hold}.rb"
  - "app/jobs/{enqueue_due_generations_job,regenerate_exercise_job}.rb"
---

# Providers, keys, usage and failures

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Per-user API keys** (`docs/decisions/per-user-api-keys.md`): Each user
  keeps one encrypted key per provider in `users.api_keys`; a key's prefix
  picks its provider, and `user.provider` names the one in use, so
  `AiService.for(user)` is the only dispatch. Use `User#store_api_key`,
  `User#remove_api_key`, `User#api_key` and `User#stored_providers`; no keys
  stores NULL. Setup removes one stored key at a time
  (`DELETE /setup/keys/:provider`, under the user row lock, nothing written
  for an anonymized account). `#remove_api_key` returns one of
  `User::KEY_REMOVAL_OUTCOMES`, which the action maps to its message. The
  key in use, once removed, hands over to the most recently saved key that
  remains (`users.key_saved_times`, written with `api_keys` in one
  assignment; no recorded time ranks last, ties go in `AiProvider.keys`
  order). Removing the last key leaves `api_keys` NULL and `provider` nil,
  the state of an account that never added a key. A generation failure
  recorded against the removed provider is cleared in the same save. The
  page never shows a key. A "Provider in use" choice is checked against
  `stored_providers` under the row lock too, so a key removed in another
  tab cannot be put in use.
  `ResponseReview` sets `daily_responses.review_provider` on every review.
  A pasted key is checked through `AiService.check_key(provider_key, key)`,
  the one other way to a provider class, which applies the same
  availability gate; `AiService.skip_key_check` passes that gate and calls no
  provider. `AiProvider.detect` first refuses a key that is not one
  run of printable ASCII within `AiProvider::MAX_KEY_LENGTH`
  (`KEY_SHAPE`), the one home of that rule. The check is one GET to the
  provider's list-models endpoint (`MODELS_URL`, with the subclass's
  `#auth_headers`), bounded as a whole by
  `CallProfiles::KEY_CHECK_TOTAL_SECONDS`, with no retry, outside
  `call_and_log`. The instance `#check_key` returns one of
  `AiService::KEY_CHECK_RESULTS` and raises nothing; the class method
  raises `SetupError` for an unknown or unavailable provider, as
  `AiService.for` does. Only `:rejected` (a 401, or Gemini's 400
  `API_KEY_INVALID`) blocks the save; a 403 and an unanswered check save
  with a warning that names no status code. It logs the result and an error
  class, never a key, a provider body or an error message: a transport
  failure at info, any other error class at error level. A key that was
  not saved leaves the key-hold count alone, and a saved one is merged under
  the user row lock, where an account deleted during the check gets no
  key and the browser is sent to sign in. The form that follows a rejection, and only that one,
  offers "Save without checking": the same `PATCH /setup` with
  `skip_check=1` goes through `AiService.skip_key_check`, which calls no
  provider and logs `result=skipped`. Every other step still runs (save
  limit, trimming, shape, prefix, row lock), and a rejected key is never
  echoed into the page, the session or a log.
- **Provider abstraction**: `AiService` is a template-method base class owning provider orchestration, JSON parsing, usage logging, and calls each prompt class (`app/prompts/*_prompt.rb`; `.claude/rules/patterns.md` says what one holds) for its text; the concept vocabularies those prompts draw from live in `ConceptVocabulary`. `AiService#call(request)` is the template for the HTTP round trip; subclasses implement `request_body`, `read_result`, `raise_for_status` and `provider_name` behind it, plus `build_connection`, define the `API_URL` it posts to, and own which model each purpose routes to (see "Per-purpose model routing" below). Each call carries one `AiService::Request` built by `AiService.request_for` from the purpose's row in `CallProfiles::BY_PURPOSE` (see `.claude/rules/patterns.md`), the provider-neutral module that also holds the timeouts, retry counts and worst-case call times. Adding a provider means adding a subclass and an `AiProvider.all` entry, not editing the base. The registry follows `ExerciseSection.all`'s explicit class-list pattern, so Zeitwerk loads each class when asked rather than relying on subclasses having already registered themselves. `User` validates against its keys and Setup uses the subclasses' key patterns. It is also where a model asks for a provider's own quota day (`.daily_quota_reset_at`), so no other model names a provider class; call timing is no provider's fact and is read from `CallProfiles`. `FakeService` has no key pattern and is available only in local environments; a manually stored fake provider is still refused in production.
- **Per-purpose model routing**
  (`docs/decisions/per-purpose-model-routing.md`): Each provider routes a call
  by its `purpose` through its own `MODEL_FOR_PURPOSE`, falling back to
  `DEFAULT_ROUTE`; `model_routing_spec` fails on a key with no row in
  `CallProfiles::BY_PURPOSE`. Effort is stated explicitly on each route, so a
  provider default change cannot move it silently. A capped call turns
  thinking off from
  `ClaudeService::THINKING_OFF` (or `OpenaiService::REASONING_OFF`), so a
  capped purpose cannot route to Opus 5.5, and an OpenAI model without `none`
  needs a `reasoning_allowance`. `judge_section`, review and `duck_thread`
  stay on Sonnet as measured decisions; Haiku would end the duck's prompt
  caching. `script/compare_models.rb` compares only Claude models, so the
  OpenAI routes are uncompared; its `judge_shape` mode checks one provider's
  judge replies against the verdict shape and picks no model.
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
  before every other check. `/generate`, Learn prepare actions, the
  per-user generation claim and queue permit, and Setup's key saves
  (`ApiKeysController::KEY_SAVES_PER_HOUR` per account,
  `KEY_SAVES_PER_HOUR_BY_IP` per address, since a checked save asks a
  provider about a key; a save without checking counts too) apply to all
  accounts. All use `LazyCacheStore`.
- **The key hold** (`docs/decisions/pausing-generation.md`, "Holding the
  schedule for a key that keeps failing"): `User#record_generation_failure!`
  counts a failure classified as a kind in `KeyHold::KINDS` (bad key, out of
  credit) in `users.generation_account_failures`, and only inside
  `GenerateDailyExercisesJob#persist_failure`'s claim-guarded write. A call
  whose provider and key are no longer the ones in use records no failure
  at all, in that job and in `RegenerateExerciseJob`: both note
  `User#key_in_use` before the call and write through
  `User#report_call_failure` under the user row lock, the one home of that
  rule, which also clears a failure left today. At
  `KeyHold::AFTER` in a row `ScheduledGeneration.users` drops the account,
  so the hand-out and any queued scheduled job stop calling its key. `KeyHold`
  (pure) owns the kinds and the count; `User` and `ScheduledGeneration` read
  it and neither names the other for this rule. A generation the user starts
  still runs. `#record_generation_success!` and `#store_api_key` set the
  count back to zero, and so do `#remove_api_key` and `#use_provider` when
  they change the provider in use;
  no other failure kind, and no regeneration failure, changes it. The hold is not a pause: it writes no
  pause column and shows no pause line.
- **What a usage row records** (`docs/decisions/what-a-usage-row-records.md`):
  Every provider call writes exactly one `ApiUsage` row through
  `AiService#log_usage`, including a call that fails before a reply (zero
  tokens, from the rescue in `call_and_log(user, request)`). Setup's key
  check is the one exception and writes none. `model` is the
  routed model; `tokens_in` is uncached input, with cache reads and writes in their own
  columns, so each provider subclass subtracts what its API counts inside
  input. `failure` comes from `AiService.failure_code_for`. `cost_usd` is
  priced at call time from the subclass's `PRICE_PER_MILLION`, for Anthropic
  keys only (`prices_usage?`); null means unknown, Gemini and OpenAI rows stay
  null, and older rows stay null (no backfill). A timeout, or a reply whose
  token counts `UsageCounts` could not read (present but malformed, cache counts
  above the input total, or a sum above what a row holds), marks the counts
  unknown and stores null. A required count (the `usage` block and the input
  and output totals every reply carries) that is missing or null marks them
  unknown too; a missing optional count (cache, thought, OpenAI's details)
  reads as 0. `model_routing_spec` fails on
  a Claude route with no price.
  The Account page sums `cost_usd` per provider through `ApiUsage.own_key_totals`, counts null rows as unpriced, and leaves the projection to `MonthlySpend`.
- **How a cut-off reply is recognized**
  (`docs/decisions/how-a-cut-off-reply-is-recognized.md`): Providers report
  truncation as data and `AiService#call_and_log` decides it is fatal after
  writing the usage row: Claude `stop_reason == "max_tokens"`, Gemini status
  `incomplete`, OpenAI `incomplete` unless the reason is `content_filter` (a
  refusal). Any other status from Gemini or OpenAI is an error, raised after
  the usage row too; OpenAI also rejects a missing status, while Gemini
  accepts one. A request with `allow_truncated` set, which only the
  `duck_thread` profile does, shows partial prose. Auth errors go
  through `AiService#raise_if_key_rejected` and never log the provider body.
- **What a person is told when a provider fails**
  (`docs/decisions/what-a-person-is-told-when-a-provider-fails.md`): Every
  surface that rescues a `ProviderError` classifies it with
  `ProviderFailure.classify` and words it through `ProviderFailureText` and
  the `provider_failures` locale table; no error message, provider text,
  status code or key reaches a user. Page scripts show only
  `CodeGymRequest.send`'s `message`, JSON errors go through
  `render_json_error`, and `ProviderError::BillingError` is never treated as a
  rate limit. A setup problem (no usable provider, the fake provider outside
  a local environment, an unsupported language) raises `SetupError`, which
  is not a `ProviderError`. Every boundary that rescues a `ProviderError`
  rescues it too, and `ProviderFailure` classifies it as `setup`, worded
  as a problem with the account's setup and never as the provider's. It is
  logged at error level with the user's id. The hourly hand-out
  (`EnqueueDueGenerationsJob`), which only enqueues, also rescues any error
  per user, so one account can't stop it.
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

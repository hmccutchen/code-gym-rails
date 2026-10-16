# One request value per provider call, a call profile per purpose

Status: draft for review, revised after the first review found the caller
inventory incomplete. Nothing is implemented.
Date: 2026-10-16. Checked against `main` at `5d27636`, after refactor A
(#402) merged.

## Goal

Every provider call goes through `AiService#call_and_log`, which forwards
nine keywords to `#call`, and five classes define `#call` with that same
nine-keyword signature. The facts about one purpose live in four places: the
model route in each provider's table, the token cap, timeout, caching and
attempt settings repeated at the call site, the purpose list on `ApiUsage`,
and the fake provider, which picks its canned reply by matching the system
prompt's text rather than by the purpose it is handed.

After this change a provider's `#call` takes one request value. A call site
names its purpose, and a profile table on `AiService` supplies the cap,
timeout, caching, attempt and truncation settings for that purpose. The
fake provider picks its reply by purpose. `call_and_log` stays as the one
place that writes the usage row and decides a cut-off reply is fatal. Every
recorded request body stays byte-identical, and every provider spec keeps
its assertions.

This is a pure refactor. No request body, header, timeout value, retry
policy, usage row or user-visible text changes.

## What drifted since the earlier review

| Claim in the review | On `main` today |
|---|---|
| `#call` takes 9 keywords | Still true, in all five classes: `app/services/ai_service.rb:1116`, `claude_service.rb:43`, `gemini_service.rb:37`, `openai_service.rb:39`, `fake_service.rb:299`. The signatures are character-identical |
| `call_and_log` has 14 call sites | Still true (`ai_service.rb`, lines 491 to 1256). `call_and_log` itself adds a tenth setting, `allow_truncated:`, that never reaches `#call` |
| `single_attempt` touched 7 files, `response_schema` 10 | Cannot be checked here: the clone is shallow and its root is #334, before either keyword. What can be measured today: each of the nine keywords appears in the same 5 `app/` files, and `max_tokens` in 14 spec files, `history:` in 16, `purpose:` in 18 |
| `ApiUsage::PURPOSES` is the purpose list | Still true, 14 entries. Two specs enumerate purposes a second way, by scanning `ai_service.rb`'s source for `purpose: "..."` (`model_routing_spec.rb:5`, `ai_service_spec.rb:186`); both scans stop matching once a call site names its purpose through a request |
| The fake picks by regex against the prompt | It matches the `system` text, not the prompt: 13 `when /.../` branches on `system` (`fake_service.rb:300-333`), with `prompt` read only inside three branches to pick a section or kind |
| The "additive keyword" pattern is recorded in CLAUDE.md | Not since #401. It is stated in `docs/decisions/conversational-calls-send-real-turns.md:12` ("the third instance of the additive-kwarg pattern") and `docs/decisions/two-stage-generation.md:179-181` ("fourth" and "fifth"). CLAUDE.md has no such note, so there is nothing there to update; the two decision docs and `.claude/rules/providers.md` are what change |
| The three real providers repeat the same sequence for failed replies | True, and wider than failures: see "Provider duplication" |
| `provider_request_characterization_spec` pins request bodies | True: 15 snapshots, five keyword shapes for each of three providers, built by sending `#call` `system:`, `prompt:` and a keyword set. No shape is built from a purpose's real call-site settings, so no snapshot today pins what `judge_review` or `duck_thread` sends |

## The four places a purpose's facts live today

### The call sites

Each `call_and_log` site passes the settings for its purpose by hand. What
is per purpose and what is per call:

| Purpose | Per-purpose settings at the site | Per-call values |
|---|---|---|
| `generate_exercise` | `read_timeout: GENERATION_READ_TIMEOUT`, or `SYNC_GENERATION_READ_TIMEOUT` when `blocking:` | system, prompt |
| `retry_section` | `read_timeout: RETRY_READ_TIMEOUT` | system, prompt |
| `review_response` | `cache_system: true`, `read_timeout: REVIEW_READ_TIMEOUT` | system, prompt |
| `assess_difficulty` | `max_tokens: DIFFICULTY_ASSESSMENT_MAX_TOKENS` | system, prompt |
| `generate_concept_reference` | `read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT` | system, prompt |
| `generate_recognition_guide` | `read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT` | system, prompt |
| `explain_concept_differently` | `max_tokens: CONCEPT_ALTERNATE_MAX_TOKENS` | system, prompt |
| `explain_differently` | none | system, prompt |
| `review_follow_up` | none | system, prompt, history |
| `duck_thread` | `max_tokens: DUCK_RESPONSE_MAX_TOKENS`, `allow_truncated: true`, `cache_system: true` | system, prompt, history |
| `pseudocode_critique` | `max_tokens: PSEUDOCODE_CRITIQUE_MAX_TOKENS` | system, prompt |
| `pseudocode_translate` | none | system, prompt |
| `judge_section` | `max_tokens: JUDGE_MAX_TOKENS` | system, prompt, `response_schema: JudgeVerdict.schema_for(kind)` |
| `judge_review` | `max_tokens: REVIEW_JUDGE_MAX_TOKENS`, `read_timeout: REVIEW_JUDGE_READ_TIMEOUT`, `single_attempt: true` | system, prompt, `response_schema: ReviewProseVerdict.schema` |

Two things in that table shape the design. `generate_exercise` has two
timeouts, chosen by the caller's `blocking:` flag, so its profile is not one
value. And `judge_section`'s schema varies by kind, so the schema is a
per-call value even though `judge_review`'s is a constant.

### The route tables

Each provider's `MODEL_FOR_PURPOSE` and `DEFAULT_ROUTE` map a purpose to a
model and effort. They stay where they are: the providers share no model
names and turn thinking down differently, which
`docs/decisions/per-purpose-model-routing.md` explains. This refactor does
not touch routing.

### The purpose list

`ApiUsage::PURPOSES` validates the usage row. `model_routing_spec` fails on
a route for a purpose no call site logs, and the single-shot group in
`ai_service_spec` asserts every purpose but two reaches `#call` with no
history. Both find the purposes by scanning the source of `ai_service.rb`
for `purpose: "..."`.

### The fake provider

`FakeService#call` picks its reply with a `case system` of 13 regexes, one
per system prompt the app sends (`generate_exercise` and `retry_section`
share `build_system_prompt`, so 13 branches cover 14 purposes). The
`purpose:` keyword arrives and is ignored. Rewording a system prompt breaks
the fake without any spec naming the connection.

Four specs depend on that text matching from outside `FakeService#call`,
and they are the finding that changes the design below. They stub Faraday
at the HTTP layer to exercise a real provider's request and reply handling,
and use the fake as the reply oracle by pulling the system text back out of
the posted body: `spec/script/gemini_capacity_probe_spec.rb:34,112,152`,
`spec/script/forced_concept_drafts_spec.rb:22`,
`spec/script/model_comparison_spec.rb:31` and
`spec/script/security_audit/prompt_injection_red_team_spec.rb:19`. At that
layer there is no purpose to hand the fake, only the body.

## Provider duplication

The three real `#call` bodies share, line for line apart from the provider
name:

- the request block that sets `req.options.timeout = read_timeout` and
  merges `long_running:` and `single_attempt:` into the Faraday context
  (`claude_service.rb:55-58`, `gemini_service.rb:50-53`,
  `openai_service.rb:45-50`; OpenAI's `long_running` rule also counts a
  `reasoning_allowance` route as final);
- `raise_for_status(resp) unless resp.success?`;
- `parse_provider_envelope(resp.body, provider: "Name")`;
- `rescue Faraday::Error => e` raising `AiService::TimeoutError` or
  `NetworkError` with "Network error calling Name";
- `route_for(purpose)` and `routed_model(purpose)` (Gemini inlines the
  lookup).

What differs is the body each provider builds, how it reads text, usage,
truncation and refusal out of the reply, and how `raise_for_status`
classifies an error body. That split is the template-method line this
refactor draws.

## Design

### `AiService::Request`

```ruby
class AiService
  Request = Data.define(:purpose, :system, :prompt, :history, :response_schema,
                        :max_tokens, :read_timeout, :cache_system, :single_attempt, :allow_truncated)

  CALL_PROFILES = {
    "generate_exercise"           => { read_timeout: GENERATION_READ_TIMEOUT, blocking_read_timeout: SYNC_GENERATION_READ_TIMEOUT },
    "retry_section"               => { read_timeout: RETRY_READ_TIMEOUT },
    "review_response"             => { cache_system: true, read_timeout: REVIEW_READ_TIMEOUT },
    "assess_difficulty"           => { max_tokens: DIFFICULTY_ASSESSMENT_MAX_TOKENS },
    "generate_concept_reference"  => { read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT },
    "generate_recognition_guide"  => { read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT },
    "explain_concept_differently" => { max_tokens: CONCEPT_ALTERNATE_MAX_TOKENS },
    "explain_differently"         => {},
    "review_follow_up"            => {},
    "duck_thread"                 => { max_tokens: DUCK_RESPONSE_MAX_TOKENS, cache_system: true, allow_truncated: true },
    "pseudocode_critique"         => { max_tokens: PSEUDOCODE_CRITIQUE_MAX_TOKENS },
    "pseudocode_translate"        => {},
    "judge_section"               => { max_tokens: JUDGE_MAX_TOKENS },
    "judge_review"                => { max_tokens: REVIEW_JUDGE_MAX_TOKENS, read_timeout: REVIEW_JUDGE_READ_TIMEOUT, single_attempt: true }
  }.freeze

  def self.request_for(purpose, system:, prompt:, history: [], response_schema: nil, blocking: false)
```

- `request_for` fetches the profile with `fetch`, so an unknown purpose
  fails at the call site, and fills the request's settings from it with the
  same defaults `#call` has today (`cache_system: false`,
  `read_timeout: READ_TIMEOUT`, `max_tokens: nil`, `single_attempt: false`,
  `allow_truncated: false`). `blocking: true` selects
  `blocking_read_timeout` where a profile has one and is an error where it
  does not.
- A second constructor, `Request.build(system:, prompt:, purpose: nil, **settings)`,
  applies those same defaults with no profile, and takes any setting
  explicitly. It exists for the low-level tests and scripts that today call
  `#call` or `call_and_log` with a purpose and hand-picked settings that are
  not that purpose's profile: the truncation tests that send `duck_thread`
  with `allow_truncated: false`, the Gemini truncation test that caps
  `explain_differently` at 60 tokens, and the request snapshots' legacy
  shapes. Production code never calls it; a spec pins that `app/` has one
  caller of `Request.build`, the `request_for` factory itself.
- A caller that needs to vary one setting on a built request uses
  `Data#with`: `request.with(single_attempt: true)`. The two scripts below
  depend on that.
- The profile values are the existing constants, not new numbers, so
  `ai_service_spec`'s timeout-budget group and the code notes that document
  each constant keep their names and meaning.
- A spec pins `CALL_PROFILES.keys` equal to `ApiUsage::PURPOSES`, the way
  `LANGUAGE_PROMPTS`' keys are pinned to `ConceptVocabulary::LANGUAGES`.
  `PURPOSES` stays the validation list on the model; the profile table
  does not reach into a model and the model does not read a service
  constant.
- The schema stays per call: `judge_section` passes
  `JudgeVerdict.schema_for(kind)` and `judge_review` passes
  `ReviewProseVerdict.schema`, both through `response_schema:`. One rule
  for both is simpler than a profile field that one of them overrides.

### `call_and_log(user, request)`

Keeps its body: the trial allowance check, the rescue that writes a
zero-token usage row, the usage row for a reply, and the error, refusal and
truncation decisions. It reads `request.allow_truncated` and
`request.purpose` instead of keywords, and passes the request to `#call`.
The 14 call sites become:

```ruby
result = call_and_log(user, AiService.request_for("judge_review",
  system: REVIEW_PROSE_JUDGE_SYSTEM_PROMPT, prompt: review_prose_prompt(kind, coach, projection),
  response_schema: ReviewProseVerdict.schema))
```

### Providers: `call(request)` and a shared template

`AiService#call(request)` becomes the template:

```ruby
def call(request)
  resp = post(request_body(request), request)
  raise_for_status(resp) unless resp.success?
  read_result(parse_provider_envelope(resp.body, provider: provider_name), request).merge(http_status: resp.status)
rescue Faraday::Error => e
  raise (e.is_a?(Faraday::TimeoutError) ? TimeoutError : NetworkError), "Network error calling #{provider_name}: #{e.message}"
end
```

with `post` owning the timeout and the `long_running` and `single_attempt`
context. Each real provider implements `request_body(request)`,
`read_result(parsed, request)`, `provider_name`, `raise_for_status` and
`routed_model`, and keeps its route tables, retry options and connection.
`OpenaiService` overrides the one line that decides `long_running`, since
its rule also counts a `reasoning_allowance` route as final. `ClaudeService`
keeps `THINKING_OFF` and `GeminiService` keeps `MINIMAL_THINKING_LEVEL`
inside their `request_body`, reading `request.max_tokens`.

`http_status` moves into the template because all three merge it the same
way today; the result hashes otherwise keep their exact keys, since
`log_usage` and the specs read them.

### `FakeService` picks by purpose

`FakeService#call(request)` looks up `request.purpose` in one table whose
values are either a canned reply or a callable of the prompt, for the three
replies that read a section or kind out of it (`review_response`,
`assess_difficulty`, `judge_section`). The 13 regexes go. A purpose with no
entry raises, as an unrecognized system prompt does today.

The four HTTP-stub specs need a purpose for the body they intercepted.
Options, with a recommendation:

1. **A marker table in test support.** `spec/support/fake_replies.rb`
   maps each purpose to the phrase its system prompt carries today (the
   13 regexes, named by purpose), and offers `purpose_for(system)`. The
   four specs call `FakeService.new(...).call(AiService.request_for(purpose_for(system), ...))`.
   The fake itself has no text matching, and rewording a system prompt
   fails one named lookup in one support file. Recommended.
2. Keep the regexes inside `FakeService` as a fallback when `purpose` is
   nil. Two ways to pick, and the production fake still carries prompt
   text. Not recommended.
3. Rewrite the four specs to stub at `#call` instead of Faraday. Not
   possible for their goal: they exist to drive a real provider's HTTP
   handling, and the fake is only their reply oracle.

### Scripts and the orchestration modules

`JudgedGeneration::Provider` and `ReviewGrading::Provider` wrap `AiService`
methods such as `judge_section` and `grade`, not `#call`, so they are
untouched.

Three scripts reach `#call` or its neighbours and must migrate with it;
the first draft of this spec missed them:

- `script/gemini_structured_output_check.rb:49` overrides `#call` on a
  `GeminiService` subclass to force `single_attempt: true`, so a retry
  cannot spend the free tier's daily budget on the same fixture. It
  becomes `define_method(:call) { |request| super(request.with(single_attempt: true)) }`.
  Its HTTP-level spec stays.
- `script/concept_reference_calibration.rb:140-143` overrides `#call` to
  replace the read timeout on the one purpose it measures, leaving the
  route alone. It becomes a `with(read_timeout: timeout)` on requests whose
  `purpose` is the measured one. Its spec and its `AttemptCounter`
  middleware stay.
- `script/model_comparison.rb:400` overrides the private `route_for` on
  `ClaudeService` to pin a comparison's model. The provider template keeps
  `route_for(purpose)` as a private method on `ClaudeService` and
  `OpenaiService` (and gives `GeminiService` one instead of its inline
  lookup), so that override and the pinned comparisons it produces keep
  working. `model_comparison_spec` also spies `receive(:call)` twice.

## The pattern this replaces, and where to say so

Two decision docs record that `#call` grew by one additive keyword at a
time, each new keyword defaulting so every other caller stayed
byte-identical: `conversational-calls-send-real-turns.md` for `history:`
and `two-stage-generation.md` for `response_schema:` and `single_attempt:`.
The PR replaces that pattern and says why: the fifth keyword showed that
each addition edits five `app/` files and every spec that overrides `#call`,
while the settings themselves are facts about a purpose, not about a call.
The three places that change:

- `docs/decisions/conversational-calls-send-real-turns.md:12` and
  `docs/decisions/two-stage-generation.md:179-181`: the sentences naming
  the keyword count become a note that the keywords are now fields of
  `AiService::Request`, with the byte-identical guarantee restated against
  the request snapshots.
- `.claude/rules/patterns.md`: the existing "Template method for
  providers" entry says subclasses implement `#call` and
  `#build_connection`. It changes to say subclasses implement
  `request_body`, `read_result`, `raise_for_status`, `provider_name` and
  `build_connection` behind `AiService#call(request)`, and keep
  `route_for`. A new entry, "One request value per provider call, a
  profile per purpose", names `AiService::Request`, `CALL_PROFILES`,
  `Request.build` for tests, and that a call site names only its purpose.
  Leaving the old entry beside the new one would give two contradictory
  instructions.
- `.claude/rules/providers.md`: the "Provider abstraction" entry says
  subclasses implement `request_body`, `read_result`, `raise_for_status`
  and `build_connection`; the "Conversational calls" entry says `history`
  is a request field; the usage-row and cut-off entries name
  `call_and_log(user, request)`.

CLAUDE.md itself carries no additive-keyword note since #401, so the PR
does not edit it.

## Specs

### Safety net recorded before the move (step 0)

`provider_request_characterization_spec` pins five keyword shapes per
provider. None is a real purpose's settings. Step 0 adds one shape per
purpose per provider, built on unchanged code by calling `#call` with
exactly the keywords that purpose's call site passes today (the table
above, with `generate_exercise` recorded twice, blocking and not, and a
fixed schema for the two judges), and records the 14 plus 1 bodies for each
of three providers. After the move the same shapes are built through
`AiService.request_for` and must match byte for byte. The five legacy
shapes stay and are built with `Request.new` directly, since they combine
settings no purpose has.

### The contract is more than the request body

Two requests with identical bodies can still differ in what the transport
does: the read timeout, the `long_running` and `single_attempt` Faraday
context that decides whether a timeout or a 429 is retried, the attempt
count, the headers, and what `call_and_log` does with the reply (usage
row, truncation, refusal). The request snapshots pin none of that. The
provider specs do, by driving stubbed HTTP and counting attempts, and they
stay as they are. Two additions make the settings side explicit:

- A resolved-settings example per purpose that drives the real application
  caller (`judge_review_prose`, `duck_response`, `generate_concept_reference`
  and so on) on a no-network provider double, with a spy around
  `call_and_log(user, request)` that records the request and delegates to
  the original method. It asserts `read_timeout`, `max_tokens`,
  `cache_system`, `single_attempt` and `allow_truncated` equal today's
  call-site settings. This captures the settings through the caller,
  not through a reconstruction of the profile. These examples land in
  step 1: the providers still call `@conn.post` directly then, and their
  keyword interface does not receive `allow_truncated`.
- Transport examples per provider that send one request with a long
  timeout and one with `single_attempt: true` and assert the Faraday
  context and attempt count, which today's provider specs assert through
  kwargs. These land in step 2 with the shared `post` implementation.

### The full caller inventory

Everything outside `app/` that defines, overrides, spies on or invokes
`#call` or `call_and_log`, found with
`grep -rnE "def call\(|define_method\(:call|receive\(:call|send\(:call" script spec`.
Every item migrates in the same step as the interface it depends on.

| Today | Where | Count | After |
|---|---|---|---|
| `def call(system:, prompt:, cache_system: ..., single_attempt: false)` doubles with the full nine-keyword signature | `ai_service_spec.rb` (18, at lines 110, 135, 196, 2955, 2980, 3097, 3124, 3220, 3266, 3312, 3340, 3399, 3595, 4031, 4299, 4542, 5902, 6054), `review_grading_spec.rb:151`, `forced_concept_drafts_spec.rb:81` | 20 | `def call(request)` reading `request.system`, `.prompt`, `.read_timeout`, `.max_tokens`, `.purpose`; the `double_class` keeps recording `read_timeouts_by_purpose` from the request |
| `receive(:call)` expectations, stubs and wrappers | `ai_service_spec.rb` (15), `review_grading_spec.rb` (3), `model_comparison_spec.rb` (2), `ai_service_trial_spec.rb` (2), `level_suggestion_isolation_spec.rb:22`, `trial_isolation_spec.rb:25`, `generate_concept_reference_job_spec.rb:223`, `learn_spec.rb:526`, `responses_duck_thread_spec.rb:388`, `responses_pseudocode_spec.rb:311`, `hardening_targets_spec.rb:105`, `deferred_module_spec.rb` | 30 | migrate in step 2; keep stubbed results, capture the positional request in wrappers, and replace `with(hash_including(prompt: ...))` with `with(having_attributes(prompt: ...))` or a block reading the request |
| `receive(:call_and_log)` stubs and wrappers, including the judge-isolation group at `ai_service_spec.rb:4849-4938` that asserts answer keys and server stamps never reach the judge | `ai_service_spec.rb` | 16 | migrate in step 1; keep stubbed results, and change wrappers to `captured = args.last` and `captured.purpose`, `captured.max_tokens`, `captured.system`, `captured.prompt`; preserve every assertion's expected values and meaning |
| `send(:call, system:, prompt:, **kwargs)` | `claude_service_spec` 39, `gemini_service_spec` 32, `openai_service_spec` 18, `gemini_capacity_probe_spec` 4 | 93 | `send(:call, AiService::Request.build(system:, prompt:, **kwargs))`, through a support helper so each site changes only its head |
| `send(:call_and_log, user, purpose:, system:, prompt:, ...)` | `ai_service_spec.rb` 7, `ai_service_trial_spec.rb` 2, `gemini_truncation_spec.rb` 1, others 2 | 12 | `send(:call_and_log, user, AiService::Request.build(purpose:, system:, prompt:, **settings))`. These tests pass settings that are not the purpose's profile on purpose: `ai_service_spec.rb:316-324` sends `duck_thread` with `allow_truncated` left false to see `TruncatedResponseError` and a `failure: "truncated"` row, and `gemini_truncation_spec.rb:29` caps `explain_differently` at 60. Through `request_for` they would get the duck's `allow_truncated: true` and no cap, and their assertions would have to change. They use `Request.build` and keep their assertions; the profiles are tested separately |
| `openai_service_spec`'s `logged_call(body, **kwargs)` helper | 1 helper, 2 examples | | `Request.build` with the `allow_truncated:` it is given |
| The single-shot group's `spy_class` and its source scan | `ai_service_spec.rb:170-215` | 1 | `call(request)` recording `request.history`; purposes from `CALL_PROFILES.keys` |
| `model_routing_spec`'s `purposes_in_use` source scan | `model_routing_spec.rb:5` | 1 | `AiService::CALL_PROFILES.keys` |
| The HTTP-stub oracle specs | the four files above | 6 sites | step 2 wraps the existing system and prompt in `Request.build`, with no purpose required while the fake still matches text; step 3 adds `purpose_for(system)` from the marker table |
| `fake_service_spec` | 1 send | | step 2 converts the direct send to `Request.build` with the same system and prompt; step 3 drives it by purpose and adds one example per purpose |
| The two script overrides and `ModelComparison#route_for` | `script/` | 3 | as in "Scripts" above; their specs unchanged |
| Request snapshot spec | 15 fixtures | | 15 legacy shapes through `Request.build`, plus 45 per-purpose shapes through `request_for` |

Every assertion in those files about error bodies, status codes, retries,
quota ids, refusals, truncation, usage rows, what reaches the judge and
what the duck sends keeps its expected values and meaning. Mechanical
accessor and matcher changes, such as `captured[:purpose]` to
`captured.purpose`, are allowed. No expectation is weakened to accommodate
the factory; where a test's settings are not a profile, the test says so
by using `Request.build`.

New examples: `CALL_PROFILES.keys == ApiUsage::PURPOSES`; `request_for`
raises on an unknown purpose and on `blocking: true` for a purpose without
a blocking timeout; the resolved-settings and transport examples above;
`app/` has exactly one caller of `Request.build`; and the template's
rescue maps `Faraday::TimeoutError` to `TimeoutError` and other Faraday
errors to `NetworkError` for each provider.

## Docs

- `docs/code-notes/app/services/ai_service.md`: entries for `Request`,
  `CALL_PROFILES`, `.request_for` and `#call` as template; the
  `call_and_log` entry reads the request.
- `docs/code-notes/app/services/claude_service.md` and
  `gemini_service.md`: `#call` entries become `#request_body` and
  `#read_result` entries. `openai_service.rb` has no code note today; its
  `reasoning_allowance` timeout rule and JSON-mode request line carry
  in-code comments and need none.
- `docs/file-map.md`: the provider lines name the two methods a subclass
  implements.
- The two decision docs and the two rule files listed above.
- `docs/decisions/per-purpose-model-routing.md:8` ("`call_and_log` hands
  `purpose:` to `#call`") and `what-a-usage-row-records.md` ("`model` is
  the model `#call` routed to") stay true as written.

## Steps

Each step is its own commit, green before the next. An interface changes
in the same step as every override, double and spy that depends on it;
nothing is left to "pass vacuously", because the two source scans return
an empty list the moment the call sites stop saying `purpose: "..."`, and
the specs that read them fail rather than pass.

0. **Record per-purpose request bodies on unchanged code.** Extend the
   request characterization spec with the per-purpose shapes, record them,
   extend its manifest, and commit before any code moves.
1. **The request value, with the providers unchanged.** Add `Request`,
   `Request.build`, `CALL_PROFILES` and `.request_for`;
   `call_and_log(user, request)` unpacks the request into today's nine
   keywords for `#call`. In the same commit: the 14 call sites, the 12
   `call_and_log` sends (through `Request.build` where their settings are
   not the profile), the 16 `receive(:call_and_log)` stubs and wrappers, the two
   purpose scans, the profile-equality examples and the resolved-settings
   examples capturing at `call_and_log`. The nine-keyword `#call` is
   untouched, so every `#call` double and provider spec stays green.
2. **Providers and every `#call` double take the request.** The template
   `#call(request)` on `AiService`; `request_body`, `read_result`,
   `provider_name` and `route_for` on each real provider; `post` with the
   context rule and OpenAI's override. In the same commit, because they all
   break the moment `#call` takes a positional request: `FakeService#call`'s
   signature (its `case system` body unchanged for this step), the 20
   keyword doubles, the 30 `receive(:call)` expectations, stubs and wrappers,
   the 93 `send(:call` sites through the support helper, the six HTTP-oracle
   calls and the direct `fake_service_spec` call through `Request.build`,
   the two script overrides, the transport examples, and the request
   snapshot spec's builder. The oracle and fake-service test calls keep
   their existing system and prompt, with no purpose required yet. Request
   snapshots, old and new, unchanged.
3. **The fake picks by purpose.** The reply table replaces the `case
   system`, the marker table lands in test support, and the four oracle
   specs start setting the purpose on their requests through that table.
   `fake_service_spec` switches its direct request to a purpose and adds
   coverage for every purpose. All request-signature conversions already
   landed in step 2.
4. **Docs.** The rule files, decision docs, code notes and file map above.

## Risks

- **A provider's error path changes shape.** The template moves
  `raise_for_status` and the rescue out of each file. The provider specs
  (89 examples across the three) pin status codes, billing errors, quota
  ids, retries and single-attempt behavior by driving stubbed HTTP, and
  must pass unchanged. Step 2 is the step to review line by line.
- **The `long_running` rule.** Three providers compute it as
  `read_timeout > READ_TIMEOUT`; OpenAI also counts a `reasoning_allowance`
  route. A shared `post` with one override keeps both; `claude_service_spec`
  and `openai_service_spec` already assert which timeouts retry.
- **A per-purpose snapshot that differs after the move** means a profile
  does not reproduce its call site. That is the failure step 0 exists to
  surface; the fix is the profile, never the snapshot.
- **The blocking generation timeout.** `generate_exercise` is the one
  purpose whose settings depend on the caller. `blocking:` on `request_for`
  keeps that explicit; the spec pins both timeouts.
- **Enumeration by source scan.** Two specs stop seeing purposes once call
  sites use `request_for`; they return an empty list and fail. Both move to
  `CALL_PROFILES.keys` in step 1, with the call sites.
- **A test's settings that are not its purpose's profile.** The duck
  truncation tests and the Gemini cap test are the known cases;
  `Request.build` keeps them exact. The review of step 1 reads every
  migrated `call_and_log` send for this, not only the three found so far.
- **The fake's oracle specs.** Recommendation 1 keeps them green with one
  support table. If the user prefers option 2, the fake keeps text
  matching and the spec says so.
- **Spec churn.** About 180 sites in specs and scripts need review (93
  provider sends, 7 oracle and fake sends, 20 doubles, 46 expectations,
  stubs and wrappers, 12 `call_and_log` sends, 3 scripts and the snapshot
  builder). The support helper keeps each `send` change to the call's
  head; the doubles and spies read the request instead of keywords.
  Mechanical accessor and matcher changes preserve the expected values
  and meaning of each assertion.
- **Scripts without specs for the changed line.** The two script overrides
  are covered by their HTTP-level specs, which run in the suite; the
  `route_for` override is covered by `model_comparison_spec`'s pinned
  comparisons.
- **What this does not do.** Routing tables stay per provider. The
  `SCENARIO_POOLS` and `config_for` exceptions recorded after refactor A
  are unrelated and stay. `history` flattening on Gemini stays.

## Verification

1. Request characterization spec after every step, without
   `UPDATE_REQUEST_SNAPSHOTS`; `git diff` against the step-0 commit on
   `spec/fixtures/request_snapshots` is empty.
2. The provider specs, `ai_service_spec`, `review_grading_spec`,
   `model_routing_spec`, `fake_service_spec`, the three script specs, the
   job and request specs that spy on `#call` or `call_and_log`, both isolation specs,
   the trial spec and the truncation spec after each of steps 1 to 3, with
   `git diff` reviewed for unchanged expected values and equivalent
   assertions. Accessor and matcher conversions are allowed; weakening an
   assertion to match new defaults is not.
3. The full unit suite once after step 4; system specs once; `bin/rubocop`,
   `bin/comment-check`, `bin/rails zeitwerk:check`.
4. Grep gates: no `def call(system:` anywhere under `app/`, `spec/` or
   `script/`; no `purpose: "` outside `request_for` calls under `app/`; no
   `when /` in `fake_service.rb`; `Request.build` called once under `app/`.
5. The `critical-reviewer` agent once, after all steps land and are green.
6. The PR description states the replaced pattern and why, the oracle
   decision taken, the unchanged snapshots, and which checks ran.

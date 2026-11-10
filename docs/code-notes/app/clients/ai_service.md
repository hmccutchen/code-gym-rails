# app/clients/ai_service.rb

## Error classes

`RateLimitError` is a 429 that survived Faraday's own retries.

`NetworkError` covers a call that got no HTTP answer and did not time out: a
refused connection, a reset or a DNS failure. `TimeoutError` is kept apart from
it so callers can explain a timeout in the user's terms instead of showing
Faraday's socket message.

`InvalidResponseError` means malformed JSON or the wrong shape. That is usually
a bug in our prompt or schema, not something the user can fix.
`TruncatedResponseError` is the reply that hit the output token cap; it has its
own name so the unfinished JSON doesn't read as a generic parse error.
`RefusalError` is a safety refusal, a 200 with no text, named so it isn't
misread as an empty-response parse error.

`UnsupportedRouteError` is a configuration mistake, such as a capped call to a
model that can't turn thinking off. It subclasses `Error` so the existing
rescues catch it.

## `RETRY_TIMEOUT_GUARD`

A timeout on a long-running call is final: the provider has likely finished and
billed the work, so a retry pays twice.

## `MAX_GENERATED_CODE_LENGTH`

Provider output is rendered into the page, so it is bounded at the boundary.

## `Request` and `Request.build`

One value carries everything a provider call needs, so a new setting is one
new field here, read by the providers that use it. `Request.build` fills the
defaults a call gets with no profile (`CallProfiles::READ_TIMEOUT`, no token cap, no
caching, retries on, truncation fatal) and takes any setting. Tests and
scripts use it when they need settings no profile has, such as a
`duck_thread` request with truncation left fatal. `.request_for` is its one
caller under `app/`, and `ai_service_request_spec` holds that. A caller that
changes one setting on a built request uses `Data#with`, as
`script/gemini_structured_output_check.rb` does for `single_attempt`.

## `.request_for`

A call site names its purpose and passes only the values that change per
call: system, prompt, history and response schema. The schema is per call
because `judge_section`'s depends on the kind. Every other setting is the
purpose's profile, unchanged. An unknown purpose raises at the call site.

## `MAX_LADDER_GUIDANCE_CHARS`

When mid-level was added, the tested ceiling rose from 48,000 to 54,000 characters.
That historical day-shape measurement was 53,632 characters with four levels
against 45,270 with three, using maximum-length rungs: 8,362 more characters
in the largest possible block. The constant checks the budget; it neither
pads nor truncates a prompt.

Per-generation spend depends on actual rung text, targets and provider
tokenization. As an illustrative estimate only, at three characters per token
the maximum-block increase is about 2,787 input tokens, or $0.011 for one
uncached Opus 5.5 draft at $4 per million input tokens. That is not a measured
token count or a dollar ceiling. Shorter rungs and shared levels reduce the
block. A kind without ladder guidance still sends its shared standard and
concrete expectation; every planned kind is listed. Reference rewrites also
generate one additional rung, whose actual output-token cost is unmeasured.
The current #718 measurement and its bounded customized-shape scope live in
`docs/decisions/kind-difficulty-expectations.md`; the estimate above describes
the earlier mid-level addition, not #718.

## `MAX_CONCEPT_GUIDE_LENGTH`

Catches a runaway response: several times the two short paragraphs per field
the prompt asks for.

## `RAW_SNIPPET_LIMIT`

Keeps exception messages, which reach flash alerts and error trackers, free of
large provider output.

## `.provider_key`

nil only on a bare subclass, such as a spec double, whose usage rows then carry
no provider.

## `#generate_judged_exercise`

The one way the app generates a set: draft, then judge (#703). A
single-stage method (`#generate_exercise`, `#generate_unjudged_exercise`)
used to sit beside it for weekend sets. Once every day was judged, only a
measurement script called it, so it went. A script that wants a draft alone
calls `ExerciseDraft.call` with `#exercise_draft_provider`.

## `#review_grading_provider`

Hands `ReviewGrading` the provider calls and prompts it needs as callables, the
way `#judged_generation_provider` does for `JudgedGeneration`. It is public,
unlike that sibling, because `ReviewGrading`'s specs and
`script/model_comparison.rb` build a provider from a service they hold; the
struct carries bound methods and two flags, never a key. The fan-out and
every per-section rule live there; this class keeps the prompts and the calls.

## `#generate_concept_reference`

A reference is cached by (concept, language) forever, so an unusable required
field rejects the reply and keeps any existing reference for a later retry.

## `#explain_concept_differently`

`reference.language` is a `ConceptBucket`, so `LanguagePrompts.for` also resolves the
language-independent buckets here.

## `#explain_differently`

Returns a plain string, not JSON: there is nothing to parse, and
`parse_json_object` would only add a way to fail.

## `#critique_pseudocode`

`gaps_found` is a typed boolean because a malformed response also normalizes to
an empty list, so the list alone can't tell "no gaps" from "unreadable".

## `#translate_pseudocode`

Round 2 is one call, always available, and never gated on round 1's outcome.
The code is normalized before it is measured, since NFC normalization can
lengthen a string past `UserText.tagged`'s cap downstream. Code over
`MAX_GENERATED_CODE_LENGTH` is rejected, never truncated: cut code no longer
matches the plan it is graded as, and raising keeps the round retryable.

## `.error_code_for`, `.failure_code_for` and `.judge_fallback_reason`

Class methods so `JudgedGeneration` and `ReviewGrading` name failures the same
way this class does. Each reads the code from the error's own class (see
`docs/code-notes/app/models/provider_error.md`). `.judge_fallback_reason`
keeps the cases that are not about a `ProviderError` class: a verdict the
judge's reply failed (`invalid_output`), a Ruby `Timeout::Error`, and a bare
`ProviderError` with a status, which reads as `http_<status>`.

## `#judged_generation_provider`

Hands over callables, so neither `judge_section` nor `retry_section` has to
join this class's public API. Each closes over the generation's deadline and
passes it to `#call_and_log`, which checks it after the request is built, since
a retry's ladders and prompt can spend the time the check would have allowed.
`ExerciseDraft.retry_section` passes the deadline less a judge's worst case,
so its re-judge still has room. `judge_identity` names this provider and the
model `#model_for("judge_section")` reads, for the solves `JudgedGeneration`
hands back.

## `#model_for`

The public reader for the model a purpose routes to, backed by each
subclass's private `routed_model` (and so its `route_for`). The jobs read the
draft model through it and the judge's identity is built from it, so nothing
parses a model name out of `ApiUsage`. `FakeService` answers `"fake"`, the
model its replies report.

## `JudgedSet`

`solves` defaults to an empty list, so a set built without a judge (the job
specs' stand-ins) carries none.

## `#exercise_draft_provider` and `#generation_prompt`

`#exercise_draft_provider` is public, as `#review_grading_provider` is, so a
script can draft a set without judging it. A draft always runs on the
`generate_exercise` profile's timeout.

`ExerciseDraft` does the drafting and reaches this class only through the
provider's two callables. `#generation_prompt` is the one place a
`GenerationPrompt` is built: it binds `#annotate_retention_concept` as the
retention callable, which stays here because `RealSource` lists it as a
curated excerpt. The `prompt` callable calls the method each time rather than
capturing it, so `script/forced_concept_drafts.rb` can wrap the factory on one
service instance to add a line to that instance's prompts alone, and the
override never reaches `GenerationPrompt` itself. `#generate_problem_set` is
the `generate` callable: it builds the request, calls, and parses the reply
with `log_raw: false`. `#record_suggested_concept` is the `record_suggestion`
callable, kept here so a script's subclass can override it.

## `#normalize_optional_reference_fields!`

Optional fields are rendered into pages and prompts, so anything other than a
bounded String becomes nil instead of raising.

## `#log_pseudocode_critique`

Logs counts and flags only, and pairs with
`ResponseReview#log_pseudocode_diagnostics` by user id and date.

## `#text_or_raise`

A blank response would fail a validation outside `rescue ProviderError` and
give the user a raw 500.

## `#annotate_retention_concept`

Names the sections that can host the concept today; otherwise the model
guesses, and ingest records a false miss. It returns nil when no section today
can host the concept, and `GenerationPrompt#retention_block` drops it from the
prompt (`filter_map`). It stays here while the rest of the template lives in
`GenerationPrompt`: `RealSource::APPLICATION_CODE` lists this method as a
curated excerpt, so moving it would change exercise content and the
source-history identity keyed on its path and name.

It asks `DayHosts`, the planner's own rule, built with the day's
`code_review` mode and trap and with each section's rung, so the hosting
conditions live in one place: the planning-host hook, the bucket the check
records under (`cm.language`) and the trap's withheld concept. It reads
vocabularies in the day's language, not `cm.language`, since
`ConceptVocabulary::LANGUAGES`' "architecture" entry would report false
hosts. The planner passes no rungs and gets the strictest list, which every
rung's vocabulary contains on every mode and trap (`day_hosts_spec`). So,
given the same trap, the prompt may name one more host than the planner
counted, never fewer: a tradeoff concept on a `principal_engineer`
`design_comparison`.

## Review day context (`sections = keys.map`)

"rounds" goes to every key so the assembler needn't branch on which kind reads
it.

## `INFRASTRUCTURE_ERRORS`

Read by `ReviewGrading` and `JudgedGeneration`. Tagged like provider errors so the other sections still save. It does not
include `StandardError`, which would hide real bugs behind a retry.

## `#call`

The template every real provider runs: post the body the subclass's
`request_body` builds, raise through its `raise_for_status` on a failed
status, parse the envelope, read the result through its `read_result`, and
add `http_status`. These steps are the same for every provider, so they live
here once. `#post` sets the request's read timeout and puts `long_running`
and `single_attempt` in the Faraday context, where `RETRY_TIMEOUT_GUARD`
reads them; `OpenaiService` overrides `#long_running?` for a route
reasoning within an allowance. A Faraday timeout becomes `TimeoutError` and
any other Faraday error `NetworkError`, both naming the provider.
`FakeService` overrides `#call` itself, since it makes no HTTP request.

## `#parse_provider_envelope`

Callers rescue `ProviderError`, so a body that is not a JSON object (an HTML
page, a cut-off reply) must arrive as one.

## `#extract_provider_message`

Every provider nests error detail as `{"error": {"message": ...}}`. Each
provider's `raise_for_status` parses the body once through `#error_envelope`
and passes the resulting hash here, so the body is never parsed twice. A
missing or blank message falls back to `fallback`, and so does a message that
is not a string: a hash or an array would otherwise reach `ProviderError` and
show up as its `inspect` text. `#error_envelope` returns an
empty hash for a body that is not JSON or whose `"error"` is a string or an
array, as in a 500 reply of `{"error":"upstream down"}`, so those fall back
too. Reading the message with `dig` raised `TypeError`, which escaped
`call_and_log` without writing a usage row.

## `#object_field`

Returns the named field when it is a JSON object and an empty hash otherwise.
`#error_envelope` and each provider's `read_result` read nested reply fields
through it (`usage`, OpenAI's `input_tokens_details` and
`incomplete_details`, Claude's `stop_details`), because `dig` or `[]` on a
string a provider sent in place of an object raises `TypeError` or
`NoMethodError`. Neither is a `ProviderError`, so the call escaped
`call_and_log` without its usage row. Each field is optional, so an unreadable
one reads as absent: no cache counts, no content-filter reason, no refusal
category.

## `#log_raw_snippet`

Raw output is logged instead of put in an exception message, which would reach
flash alerts and error trackers. `.scrub` repairs a multi-byte character that
`byteslice` cut in half.

## `#log_usage`

Rescues database errors only. Swallowing anything else would silently empty the
table that cost questions rely on.

It checks out no connection by hand. `ApiUsage.create!` takes one through
Active Record's `with_connection` and returns it after the write, on any
thread, and a fan-out thread also runs inside the executor
(`docs/code-notes/app/clients/caller_zone_thread.md`). The block that wrapped
the write in `connection_pool.with_connection` came out with #754; a failed
checkout still raises `ActiveRecord::ConnectionTimeoutError`, which the rescue
logs.

The row's `cost_usd` is priced here, at call time, from the subclass's
`PRICE_PER_MILLION`, so a later price change never rewrites an old row. A model
with no price writes a null cost and a warning instead of raising, because the
call the row records has already happened. A provider whose `prices_usage?` is
false, every provider but Claude for now, writes a null cost and no warning,
since the gap is deliberate.

## `.cost_usd`

On a priced provider, a result with no tokens of any kind costs zero whatever
its model, so a call that failed before a reply is never left unknown. A
timeout is the exception: `failed_call_result` carries `tokens_unknown` from
`ProviderError.leaves_tokens_unknown?`, and the cost stays null with no warning,
since a gap the error explains is not a missing price. `Price`
turns each rate into a `BigDecimal` through `to_s` when the table is built, so
`0.2` stays two tenths rather than a float's nearest value, and a missing or
negative rate raises at boot rather than on a call.

## `#build_review_section_prompt`

It gathers values only: the section, `DailyResponse#answer_for`, `DailyResponse#answered?` and the rung from `#review_rung`. `ReviewPrompt.for_section` chooses between the graded and the walkthrough prompt (#583). It is the one reader of `ReviewApproachParagraph.enabled?`, which it hands over as `approach:`, so the prompt class never reads the environment. Every mode of `script/model_comparison.rb` that grades a section (`review`, `review_calibration` and `review_stability`, which the regrade script runs) builds its prompts through this method, so they follow the switch too. The `review_prose` modes call only the prose judge. Unset the variable in the shell to compare today's prompt.

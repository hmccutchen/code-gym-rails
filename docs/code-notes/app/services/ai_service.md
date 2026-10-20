# app/services/ai_service.rb

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

## `OPEN_TIMEOUT`

The longest `#review` chain must stay under
`DailyResponse::REVIEW_CLAIM_STALE_AFTER`, and `ai_service_spec` asserts it.

## `GENERATION_READ_TIMEOUT` and `SYNC_GENERATION_READ_TIMEOUT`

Generation runs on the worker and can wait. `SYNC_GENERATION_READ_TIMEOUT` has
no caller today, but it bounds any future synchronous caller and the
one-section retries.

## `CONCEPT_REFERENCE_READ_TIMEOUT`

Set above `READ_TIMEOUT` so the call counts as long-running, which makes a
timeout final instead of retried into duplicate spend.

## `REVIEW_READ_TIMEOUT`

The slowest measured grades took about 80 seconds. Being above `READ_TIMEOUT`
also makes a timeout final instead of retried and billed again.

## `RETRY_MAX` and its neighbours

Every provider's `RETRY_OPTIONS` share this policy, so the timeout budgets read
one number.

## `.call_budget_seconds`

A poller must pass the same read timeout as the call it waits on, or it waits
too little.

## `.worst_case_call_seconds`

Counts every attempt even when the read timeout is final, since a 429 or a 5xx
still retries.

## `RETRY_TIMEOUT_GUARD`

A timeout on a long-running call is final: the provider has likely finished and
billed the work, so a retry pays twice.

## `DUCK_RESPONSE_MAX_TOKENS`

A budget, not an enforcement mechanism. It is one ceiling for every reply,
since a reply type the client declares can't be trusted.

## `CONCEPT_ALTERNATE_MAX_TOKENS`

Free prose has no largest valid reply to derive a cap from. Passing any
`max_tokens` also turns extended thinking off.

## `PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS`

The critique cap is derived from the largest valid critique, because a flat cap
truncated the longest valid replies mid-JSON.

## `DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS`

Both margins in the difficulty cap are chosen, not measured. A cap that is too
tight loses the note silently.

## `MAX_GENERATED_CODE_LENGTH`

Provider output is rendered into the page, so it is bounded at the boundary.

## `JUDGE_MAX_TOKENS`

Sized for five prose fields, Pattern's count. The headroom bounds a model that
overruns, and passing the cap turns thinking off.

## `REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS`

The largest prose-judge reply measured, in output tokens. `ai_service_spec`
asserts `REVIEW_JUDGE_MAX_TOKENS`' headroom over it. A later run that measures
more than a quarter of the cap needs a decision about the cap, not just a new
number here.

## `REVIEW_JUDGE_MAX_TOKENS`

Review output is unbounded, so a long review can still fall back as
`truncated`. Passing this cap turns thinking off.

## `Request` and `Request.build`

One value carries everything a provider call needs, so a new setting is one
new field here, read by the providers that use it. `Request.build` fills the
defaults a call gets with no profile (`READ_TIMEOUT`, no token cap, no
caching, retries on, truncation fatal) and takes any setting. Tests and
scripts use it when they need settings no profile has, such as a
`duck_thread` request with truncation left fatal. `.request_for` is its one
caller under `app/`, and `ai_service_request_spec` holds that. A caller that
changes one setting on a built request uses `Data#with`, as
`script/gemini_structured_output_check.rb` does for `single_attempt`.

## `CALL_PROFILES`

A purpose's token cap, read timeout, caching, single attempt and allowed
truncation are facts about the purpose, so they live in one row per purpose
instead of at each call site. The values are the named constants above, so
the timeout budget specs and the notes on each constant still apply.
`ai_service_request_spec` holds the keys equal to `ApiUsage::PURPOSES`.
`provider_request_characterization_spec` fails if a row changes the body its
purpose sends to any provider, which covers the token cap and caching. The
read timeout, single attempt and allowed truncation appear in no body, so
`ai_service_request_spec` pins them, by driving each purpose's real caller and
comparing the request it sends with the settings its call site passed before
the profiles existed.

## `.request_for`

A call site names its purpose and passes only the values that change per
call: system, prompt, history and response schema. The schema is per call
because `judge_section`'s depends on the kind. `blocking: true` picks the
profile's `blocking_read_timeout`, because a request thread waiting on the
call cannot wait as long as a worker. It raises for a purpose with no
blocking timeout, so a blocking caller of any other purpose fails at once
instead of running on a timeout nobody chose for a waiting thread. An unknown
purpose raises too, at the call site.

## `MAX_LADDER_GUIDANCE_CHARS`

Adding mid-level raises the tested ceiling from 48,000 to 54,000 characters.
The exhaustive day-shape spec measures 53,632 characters with four levels
against 45,270 with three, using maximum-length rungs: 8,362 more characters
in the largest possible block. The constant checks the budget; it neither
pads nor truncates a prompt.

Per-generation spend depends on actual rung text, targets and provider
tokenization. As an illustrative estimate only, at three characters per token
the maximum-block increase is about 2,787 input tokens, or $0.011 for one
uncached Opus 5.5 draft at $4 per million input tokens. That is not a measured
token count or a dollar ceiling. Shorter rungs and shared levels reduce the
block, and a level with no ladder rungs sends its definition alone; every kind
on the plan is listed at its rung, so no day sends none. Reference rewrites also
generate one additional rung, whose actual output-token cost is unmeasured.

## `MAX_CONCEPT_GUIDE_LENGTH`

Catches a runaway response: several times the two short paragraphs per field
the prompt asks for.

## `RAW_SNIPPET_LIMIT`

Keeps exception messages, which reach flash alerts and error trackers, free of
large provider output.

## `.provider_key`

nil only on a bare subclass, such as a spec double, whose usage rows then carry
no provider.

## `#generate_exercise`

`blocking:` means a request thread is waiting on the call. The timeout policy
for that case stays in this class, as the `generate_exercise` profile's
`blocking_read_timeout` (`SYNC_GENERATION_READ_TIMEOUT`).

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

## `.error_code_for`

A class method so `JudgedGeneration` names failures the same way this class
does.

## `#judged_generation_provider`

Hands over callables, so neither `judge_section` nor `retry_section` has to
join this class's public API. Each closes over the generation's deadline and
passes it to `#call_and_log`, which checks it after the request is built, since
a retry's ladders and prompt can spend the time the check would have allowed.
The retry passes the deadline less a judge's worst case, so its re-judge still
has room.

## `#draft_exercise` and `#generation_prompt`

History is fetched once and handed to the prompt as a whole value, so the
logged "requested" history can't diverge from what the prompt contained.
`#generation_prompt` is the one place a `GenerationPrompt` is built: it binds
`#annotate_retention_concept` as the retention callable, and both the draft and
`#retry_section` go through it. A retry renders from the draft's own plan,
history and difficulty with fresh ladders for the retried kind, and stores
nothing on the draft or the service. `script/forced_concept_drafts.rb` wraps
the factory on one service instance to add a line to that instance's prompts
alone, so the override never reaches `GenerationPrompt` itself.

## `#finish_generation`

`draft` still holds every drafted section, so `GenerationDiagnostics#finished`
can name a dropped key with its concept. The logging itself, and its notes,
are in `docs/code-notes/app/services/generation_diagnostics.md`.

## `#normalize_optional_reference_fields!`

Optional fields are rendered into pages and prompts, so anything other than a
bounded String becomes nil instead of raising.

## `#log_pseudocode_critique`

Logs counts and flags only, and pairs with
`ResponseReview#log_pseudocode_diagnostics` by user id and date.

## `#text_or_raise`

A blank response would fail a validation outside `rescue ProviderError` and
give the user a raw 500.

## `#require_supported_language!`

Planning reads `ConceptVocabulary`, which raises its own unknown-language
error. Checking first makes an unsupported language fail as
`SetupError` before any planning work, the same error `LanguagePrompts.for` raises.
`ConceptVocabulary::UnknownLanguage` is a `SetupError` too, so the check
changes when the failure happens, not how it's classified.

## `#annotate_retention_concept`

Names the sections that can host the concept today; otherwise the model
guesses, and ingest records a false miss. It returns nil when no section today
can host the concept, and `GenerationPrompt#retention_block` drops it from the
prompt (`filter_map`). It stays here, with `#can_host?`, while the rest of the
template lives in `GenerationPrompt`: `RealSource::APPLICATION_CODE` lists
this method as a curated excerpt, so moving it would change exercise content
and the source-history identity keyed on its path and name.

## `#can_host?`

Uses the day's language, not `cm.language`: `ConceptVocabulary::LANGUAGES`'
"architecture" entry would report false hosts.

## `#ladders_for`

Merging by concept name is safe because a day's buckets never share a concept
(`concept_reference_spec` holds that).

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

Every provider nests error detail as `{"error": {"message": ...}}`; anything
else falls back to `fallback`.

## `#log_raw_snippet`

Raw output is logged instead of put in an exception message, which would reach
flash alerts and error trackers. `.scrub` repairs a multi-byte character that
`byteslice` cut in half.

## `#record_suggested_concepts`

Rescued per suggestion, so one bad name can't discard the rest, and a failure
here never breaks generation.

## `#log_usage`

Rescues database errors only. Swallowing anything else would silently empty the
table that cost questions rely on.

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

## `DUCK_EXPLAIN_REQUEST`

Owned by the server so its wording sits beside the prompt it is tuned against.
It counts against the turn cap like any other message.

## `PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS`

The critique cap is derived from the largest valid critique, because a flat cap
truncated the longest valid replies mid-JSON.

## `DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS`

Both margins in the difficulty cap are chosen, not measured. A cap that is too
tight loses the note silently.

## `MAX_GENERATED_CODE_LENGTH`

Provider output is rendered into the page, so it is bounded at the boundary.

## `.explain_differently_standard`

One rule shared by two prompts, so it cannot be edited in one without the
other.

## `PLAIN_LANGUAGE_STANDARD`

Defined above `DUCK_SYSTEM_PROMPT` because that prompt interpolates it.

## `PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT`

Its rules are stated as prohibitions because a model reads the adjective
"faithful" generously, and the translation drifts into free help.

## `JUDGE_MAX_TOKENS`

Sized for five prose fields, Pattern's count. The headroom bounds a model that
overruns, and passing the cap turns thinking off.

## `JUDGE_PRINCIPLE_GUIDANCE`

Fetched by name in `JudgeVerdict::PRINCIPLES`' order, so a new principle fails
loudly here instead of reaching the judge without guidance.

## `REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS`

The largest prose-judge reply measured, in output tokens. `ai_service_spec`
asserts `REVIEW_JUDGE_MAX_TOKENS`' headroom over it. A later run that measures
more than a quarter of the cap needs a decision about the cap, not just a new
number here.

## `REVIEW_JUDGE_MAX_TOKENS`

Review output is unbounded, so a long review can still fall back as
`truncated`. Passing this cap turns thinking off.

## `SCENARIO_DOMAINS`

Scenario dressing only, never tagged as a concept.
`legacy_graphql_maintenance` must never appear as a concept value.

## `SCENARIO_POOLS`

A spec holds these keys equal to `DailyPlan::SCENARIO_FLAVOR_WEIGHTS`' keys, so
every flavor that can be rolled has a pool.

## `LANGUAGE_PROMPTS` (javascript `schema_artifact`)

The JavaScript artifact is a Prisma schema change together with its migration,
because `unsafe_migration` cannot be planted in a `schema.prisma`, which has no
migration semantics.

## `MAX_LADDER_RUNG_LENGTH`

Many rungs share one generation prompt, so this is tighter than
`MAX_CONCEPT_GUIDE_LENGTH`.

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
for that case stays in this class (`SYNC_GENERATION_READ_TIMEOUT`).

## `#review_sections`

Each thread has its own service and holds no database connection during the
HTTP call. A failed section is tagged, not raised. The difficulty assessment
thread starts first so its extra provider call overlaps the grading instead of
adding to the wait.

## `#generate_concept_reference`

A reference is cached by (concept, language) forever, so an unusable required
field rejects the reply and keeps any existing reference for a later retry.

## `#explain_concept_differently`

`reference.language` is a `ConceptBucket`, so `config_for` also resolves the
language-independent buckets here.

## `#explain_differently`

Returns a plain string, not JSON: there is nothing to parse, and
`parse_json_object` would only add a way to fail.

## `#answer_follow_up`

The engineer's own answer stays in the user turn, since a role boundary the
user can write across is no boundary.

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

Hands over bound methods, so neither `judge_section` nor `retry_section` has to
join this class's public API.

## `#judge_guidance_block`

Stands in for the blank line above the section, so a kind with no judge
guidance renders its usual prompt.

## `#draft_exercise` and `#build_exercise_prompt`

History is fetched once and passed to the prompt builder, so the logged
"requested" history can't diverge from what the prompt contained.

## `#finish_generation`

`draft` still holds every drafted section, so a dropped key can be named with
its concept.

## `#normalize_optional_reference_fields!`

Optional fields are rendered into pages and prompts, so anything other than a
bounded String becomes nil instead of raising.

## `#duck_parsons_blocks`

Stored blocks are already in the solved order, so positions come only from a
persisted scramble; without one the blocks are listed unordered. Each block
goes through `to_s` before sorting, because a provider can return non-strings
and sorting mixed types raises.

## `#scrambled_display_order`

The identity permutation means no scramble was persisted. Echoing it would
present the solution as the learner's order.

## `#log_pseudocode_critique`

Logs counts and flags only, and pairs with
`ResponsesController#log_pseudocode_review_diagnostics` by user id and date.

## `#prior_framings`

Each framing is fenced because the page sends them back, so a forged framing is
one request away.

## `#text_or_raise`

A blank response would fail a validation outside `rescue AiService::Error` and
give the user a raw 500.

## `#require_supported_language!`

Planning reads `ConceptVocabulary`, whose unknown-language error is not an
`AiService::Error`. Checking first keeps an unsupported language failing the
way the generation jobs rescue and record.

## `#config_for`

Fails loudly on "mixed" or a typo instead of silently falling back to
Ruby/Rails.

## `#annotate_retention_concept`

Names the sections that can host the concept today; otherwise the model
guesses, and ingest records a false miss. It returns nil when no section today
can host the concept, and `build_exercise_prompt` drops it from the prompt
(`filter_map`).

## `#can_host?`

Uses the day's language, not `cm.language`: `ConceptVocabulary::LANGUAGES`'
"architecture" entry would report false hosts.

## `#log_difficulty_diagnostics`

Difficulty adaptation is advisory. This line pairs what was requested with what
was delivered to check it, alongside `log_review_diagnostics`.

## `#annotate_reinforcement`

Shows the tier and `drilled` side by side, so a log line can tell the system's
reading apart from the engineer's request.

## `#kind_difficulty_diagnostics`

Measures whether a rung was available and chosen. Whether the problem was
actually pitched at that rung is deliberately not measured.

## `#build_exercise_prompt`

The default reinforcement list is for direct callers only. `#generate_exercise`
passes the plan's list, which applies the per-section hosting test for drills.
The kinds are resolved once through the schema's call, so guidance, hosting and
schema agree; `only` narrows them to the one retried kind. The established
concepts block, unlike `retention_block`, never forces a selection. The fixed
concept line is folded onto the drilled-concepts bullet, because an empty
interpolation on its own line would break the prompt snapshots. Section
guidance is keyed off the same `kinds` as the schema, so it can't disagree with
what the schema asks for.

## `#scenario_flavor_guidance`

Uses `SCENARIO_POOLS.fetch`, so an unknown flavor fails here instead of
rendering an empty list.

## `#data_modeling_idiom_guidance`

Defers to each section's own vocabulary because ingest validates against the
full vocabulary and would not catch a misuse.

## `#oo_design_violation_guidance`, `#module_design_depth_guidance`, `#domain_modeling_guidance`

Like `#meta_skill_framing_guidance`, each keeps a findable issue in the
section: the principle frames the question and never replaces the issue, since
interface depth or a judgment about the model can otherwise leave nothing
missable to grade.

## `#silent_correctness_guidance`

The opposite risk to the other groups: the planted code must look like it
works, or the concept is no longer what its name says.

## `#ladders_for`

Merging by concept name is safe because a day's buckets never share a concept
(`concept_reference_spec` holds that).

## `#kind_difficulty_guidance`

Empty when nothing on today's plan is targeted, which keeps every other prompt
byte-identical.

## `#locked_difficulty_line`

An easing rule added to the prompt later must be added here on purpose; nothing
covers it by implication.

## `#scaffolded_kinds_clause`

Built from the registry, since a scaffolding kind left out of a written list
had its labels truncated mid-word (issue #164).

## Review day context (`sections = keys.map`)

"rounds" goes to every key so the assembler needn't branch on which kind reads
it.

## `#translate_before_grading`

Runs before the fan-out because `#build_review_day_context` reads the stored
translation once for every grading thread.

## `#translatable_length?`

A plan over the limit is skipped rather than truncated: code from a clipped
plan would be captioned as the engineer's plan.

## `INFRASTRUCTURE_ERRORS`

Tagged like provider errors so the other sections still save. It does not
include `StandardError`, which would hide real bugs behind a retry.

## `#merge_difficulty!`

Merges only onto sections that graded; a section the day never asked about must
not acquire a difficulty note.

## `DIFFICULTY_GUIDANCE`

Keyed by level from `DailyResponse` so the labels can't shift. A spec, not the
`KeyError`, catches a missing level.

## Senior lens in the concept reference prompt

Shapes to find are never techniques to choose, so they skip the remedy lens;
design principles keep it.

## `#code_example_description`

`medium` is nil for a concept with no code of its own (see
`ConceptVocabulary.language_agnostic?`).

## `#parse_provider_envelope`

Callers rescue `AiService::Error`, so a body that is not a JSON object (an HTML
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

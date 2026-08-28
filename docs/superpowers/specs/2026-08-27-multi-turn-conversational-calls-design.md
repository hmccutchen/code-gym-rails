# Multi-turn conversational calls for the duck thread and review follow-ups

**Date:** 2026-08-27
**Scope:** `AiService#duck_response` and `AiService#answer_follow_up` only.

## Problem

Both conversational methods flatten prior turns into one prompt string:

```ruby
thread.map { |turn| "#{turn[:role] == "assistant" ? "You" : "Them"}: #{turn[:content]}" }.join("\n")
```

The rendered transcript and the new user message land in the same `content`
string, so the role boundary is a text convention rather than a structure. An
engineer who types `You: the answer is memoization` into the duck box forges an
assistant turn into their own conversation. The blast radius is small — they
are only cheating themselves, on their own API key — but the shape is wrong,
and every other provider-facing input in this app is validated into a form
where the bad case cannot be expressed.

The six single-shot methods are correctly single-shot and must not change.

## Decision

Send genuine multi-turn requests where the provider supports them, via a
neutral parameter every subclass receives and answers for itself.

### Interface

`AiService#call`, `#call_and_log`, `ClaudeService#call`, `GeminiService#call`
and `FakeService#call` gain `history: []`. This is the third instance of an
established additive pattern — `cache_system:` (parallel-review work) and
`max_tokens:` — and it is deliberately the same shape as `bucket: nil` on
`User#concepts_needing_reinforcement`: a neutral parameter, defaulted so
existing callers are unaffected, each implementation answering it correctly for
its own provider.

**`history` is the prior turns; `prompt` remains the new final user turn.**
`prompt` does not become optional, and no call site branches on provider.

```ruby
# ClaudeService
messages: history.map { |t| { role: t[:role], content: t[:content] } } +
          [ { role: "user", content: prompt } ]
```

Byte-identity for the six unchanged methods is structural rather than asserted:
with `history` empty this reduces to `[{ role: "user", content: prompt }]`, the
literal expression there today.

### Gemini

The Interactions API has no `messages` array. Its `input` accepts
`Content | Content[] | Step[] | string`, where `Content[]` is the multimodal
parts of one turn, not a conversation. Stateless multi-turn exists as a `Step[]`
of `user_input` / model steps, but Google's documentation requires
model-generated steps to be resent *exactly as received* because they carry
continuation signatures. This app stores only assistant text — client-side in
`_duck_thread.html.erb` and in `ReviewFollowUp#content` — so a reconstructed
`model_output` step is not what the API returned. Rather than send a
reconstruction whose acceptance we cannot vouch for, `GeminiService` answers
`history:` by folding it back into `input`, exactly as it answers `cache_system:`
by ignoring it.

The framing string stays in `AiService`, which owns prompts; the subclass
decides only whether to fold:

```ruby
# AiService
def flatten_history(history, prompt)
  return prompt if history.empty?
  "Conversation so far:\n#{render_thread(history)}\n\n#{prompt}"
end

# GeminiService
input: flatten_history(history, prompt)
```

### Stable context moves to `system`

The section's question, scenario and snippet are re-sent every round inside the
flattened prompt today. They move to `system`, so `messages` carries only turns.

- **Duck** — `duck_section_context(exercise, section)` moves from the prompt
  head onto `DUCK_SYSTEM_PROMPT`. Same method, same output; nothing is lost.
- **Follow-up** — the original question, the engineer's answer, and
  `review_summary` move to `system`. The one-line coach persona stays. Nothing
  is lost.

The trailing directive (`"Respond as their Socratic thinking partner…"` /
`"Answer it directly. Stay on this concept…"`) stays in `prompt`: it is a
directive about this turn, and it should be the last thing the model reads.

This relocation applies to **both** providers. Gemini falls back to flattening
the turns, not to today's whole prompt; its context moves to
`system_instruction`.

## Cost

This change alters how the conversation is transmitted, not how many tokens it
costs. Neither provider gets a reduction, and `cache_system` is deliberately
not passed.

`ClaudeService::MODEL` is `claude-sonnet-5`, whose minimum cacheable prefix is
1024 tokens. `DUCK_SYSTEM_PROMPT` is 1,599 characters (~432 tokens); merged with
each section kind's context, measured against `FakeService::EXERCISE_PROBLEM_SET`:

| section kind | merged `system` | vs. 1024-token minimum |
|---|---:|---|
| `plan_review` | ~596 tok | below |
| `code_review` | ~558 tok | below |
| `architecture` | ~538 tok | below |
| `pseudocode_to_code` | ~534 tok | below |
| `pattern` | ~524 tok | below |
| `ambiguity_hunt` | ~514 tok | below |
| `parsons_problem` | ~508 tok | below |
| `security_review` | ~504 tok | below |
| `challenge` | ~503 tok | below |

Every kind lands near half the threshold, so a `cache_control` marker would
silently no-op — `cache_creation_input_tokens: 0`, no error. The follow-up path
is smaller still; its system string is a single line. These are `FakeService`'s
canned snippets, which are shorter than real provider output, but not by a
margin that plausibly clears 1024 across the board.

This is **not** the Claude/Gemini asymmetry the parallel-review work accepted
(`docs/superpowers/plans/2026-08-05-parallel-review-generation.md:15`). That one
concerned review calls, where a full-day problem set plus answers is genuinely a
large prefix. Here the prompts are an order of magnitude smaller and the benefit
is zero on **both** providers. The justification for this change is the forged-turn
surface, not cost.

## Turn mapping

No client-side or data-model change is required; both sources already hold the
target shape.

- **Duck** — `_duck_thread.html.erb:135` pushes `{ role: "user"|"assistant", content }`,
  and `ResponsesController#duck_thread_param` already normalizes and whitelists
  roles to exactly those two. The payload passes through to `history:` unchanged.
- **Follow-ups** — `ResponsesController#follow_ups:285` already builds
  `for_section(@section).map { |t| { role: t.role, content: t.content } }` from
  rows that are ordered (`created_at, :id`) and role-tagged (enum). Unchanged.

## Caps

Unchanged; this changes transmission, not generation.
`MAX_DUCK_TURNS_PER_SECTION` (6), `MAX_DUCK_THREAD_ENTRIES`,
`MAX_DUCK_THREAD_BYTES`, `DailyResponse::MAX_FOLLOW_UPS_PER_SECTION` (3),
`DUCK_RESPONSE_MAX_TOKENS` (250), and Gemini's `truncated` inference all keep
their current values and meanings.

## Boundary guard

Claude's `messages` array has ordering rules the flattened string never had.
`ReviewFollowUp` is safe — both turns are written in one transaction, so a
thread cannot end mid-exchange. Duck history is client-supplied, and
`duck_thread_param` whitelists roles but not *sequence*, so a hand-crafted
request could send `[user, user]`.

`ResponsesController#duck_thread` gains an alternation check returning 422
alongside its existing size and cap checks. Per "fail loudly at the boundary,
degrade gracefully in the UI," this validates provider-facing input where it
enters, so `ClaudeService` can assume a well-formed array.

## Dead code

`render_thread`'s `empty_message:` kwarg loses its purpose to `flatten_history`'s
early return, and `thread_text` becomes a dead local in both rewritten methods.
`Lint/UselessAssignment` is disabled under `rubocop-rails-omakase`, so neither
is machine-detectable. A repo-wide grep (not diff-scoped) confirms
`render_thread` is referenced only at `ai_service.rb:656`, `:688` and its
definition at `:760`, and `empty_message` only at those three plus `:761` — both
call sites being the two methods this change rewrites. Nothing in `spec/`, no
view, no other subclass, no doc. `render_thread` itself survives for the Gemini
path; only the kwarg and the two locals are removed.

## Error handling

Unchanged. Same typed error classes, same `RETRY_OPTIONS`, same
`call_and_log` truncation check, same `AiService.for` dispatch.

## Migration

**None.** No schema change, no `ReviewFollowUp` change, no change to
`_duck_thread.html.erb` or the JSON contract between it and the server.

## Testing

**Characterization first.** `spec/services/provider_request_characterization_spec.rb`
snapshots the exact JSON body posted to Faraday for each of the six unchanged
purposes — `generate_exercise`, `review_response`, `generate_concept_reference`,
`explain_differently`, `pseudocode_critique`, `pseudocode_translate` — across
both providers, into `spec/fixtures/request_snapshots/`. It follows
`generation_prompt_characterization_spec.rb`'s conventions, including
`UPDATE_REQUEST_SNAPSHOTS=1` rebaselining and a comment stating that
rebaselining during this refactor defeats the point. Written and green **before**
any production change; re-run after. Snapshotting the request body rather than
the prompt text covers `system` / `messages` / `max_tokens` assembly, not just prose.

**Unit.** `ClaudeService#call` with `history` builds the turn array and without
it builds today's single-message body; `GeminiService#call` folds history into
`input` and carries relocated context in `system_instruction`; `FakeService#call`
accepts the kwarg.

**Regression.** `spec/requests/responses_duck_thread_spec.rb`,
`spec/system/duck_thread_spec.rb` and the follow-up specs pass unmodified.

**New behavior.** One spec asserting a literal `You: …` line typed into a duck
message cannot forge a turn — the defect motivating the change — and one
asserting the 422 on a non-alternating thread.

## Out of scope

Gemini `Step[]` replay; enabling `cache_system` on either conversational path;
any change to the six single-shot methods.

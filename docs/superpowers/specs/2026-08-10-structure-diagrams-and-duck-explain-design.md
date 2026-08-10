# Structure Diagrams and "Explain It Simply"

**Date:** 2026-08-10
**Status:** Approved

## Problem

Prose is a poor medium for structural and spatial relationships. It is linear;
structure is not. A user reading a scenario about a component tree, a data
flow, or how pieces connect has to reconstruct that shape from text — and may
fail to, not because the underlying concept is beyond them, but because the
format is wrong for what it is carrying (Paivio's dual coding).

Both changes below address the same moment: understanding what a problem *is*,
before reasoning about how to solve it. Neither touches grading, concept
tagging, mastery tiers, or `ConceptMastery`. Neither adds a dependency, and
neither needs a migration.

They ship as two commits.

## Change 1: Structure diagrams on scenario-bearing sections

Mermaid already renders in this app, in exactly one place: the architecture
section's reference block, where the diagram visualizes the decision's
tradeoffs. This change extends that same proven infrastructure to diagram the
structure of a problem itself.

### Which section kinds get a diagram

`code_review`, `pattern`, and `challenge`. Not `security_review`, not
`parsons_problem`, and not architecture's scenario (it already has a diagram
in its reference block).

- **pattern** is the strongest case: no code appears on screen at all, so the
  only representation of the scenario's structure is prose.
- **code_review** and **challenge** both already show their code, so a
  structural diagram restates what is on screen spatially rather than adding
  information. Nothing can leak that is not already visible.
- **security_review** is excluded deliberately. Its task is finding *one*
  exploitable thing in a snippet, so a diagram of the snippet's structure
  narrows the search space in a way the other kinds' diagrams do not. The
  snippet being visible is not the same as the vulnerability being visible.
- **parsons_problem** is excluded because the blocks *are* the structure. A
  diagram of them is either redundant or the answer.

`ExerciseSection.diagrammable?` is the single place this set is stated — a
class predicate alongside the existing `improved_code?` and `scaffolded?`,
returning `false` by default and `true` on `CodeReview`, `Pattern`, and
`Challenge`. Both the schema builder and the views read it, so adding or
removing a kind is a one-line change in one file.

### What the diagram may depict

The diagram shows what the scenario or snippet **describes** — component →
effect → state → consumer, request → service → job → database — and never the
answer, the fix, the corrected structure, or any annotation marking a node as
the problem. This is the same safety property that makes `ConceptReference`
safe to show before answering: depicting a problem's shape does not reveal its
solution.

This constraint is stated explicitly in the generation prompt, not left
implicit.

### Generation and ingest

The schema gains an optional `"diagram"` string on the three kinds, described
the way architecture's already is: Mermaid source, **or an empty string if no
diagram would help**. An empty string is a good answer and is preferred over a
forced or trivial diagram.

The Mermaid syntax constraints — `flowchart TD` or `graph LR` only, at most 8
nodes, no styling directives, no subgraphs, no click handlers, no `classDef`,
short quoted labels — currently live inside `build_exercise_prompt`'s
architecture-only `third_guidance` branch. They move into the shared
instruction list, since they now govern sections present every day.
Architecture's branch keeps only the guidance specific to its own reference
diagram.

`AiService#normalize_diagrams!` runs in `generate_exercise` alongside
`normalize_answer_scaffolds!` and mirrors its posture: this is provider output
rendered into an HTML data attribute, so it is bounded at the boundary rather
than trusted downstream. It drops the key for non-diagrammable kinds, drops
non-strings and blanks, strips, and drops anything over
`AiService::MAX_DIAGRAM_LENGTH` (1,000 characters — an 8-node flowchart with
quoted labels lands well under half that, so the bound rejects runaway output
without rejecting anything the prompt actually asks for). Truncating instead of
dropping would produce
syntactically broken Mermaid, which the renderer would reject anyway — dropping
says the same thing without the round trip.

### Rendering

A new `shared/_mermaid_diagram` partial owns both the hidden container and the
once-per-page module script, guarded by `@mermaid_diagram_script_emitted`. The
existing architecture usage switches to it with no behavior change.

The alternative — duplicating the container markup per section and leaving the
script in `_architecture_section` — was rejected: on a day whose third section
is not architecture, the script would never be emitted and no diagram would
render anywhere. Putting the script in the layout unconditionally was also
rejected, since it would load the CDN on pages that never show a diagram.

Everything about the Mermaid posture is reused verbatim: the same pinned
`mermaid@11.4.1` CDN import, `securityLevel: "strict"`, and the
start-hidden/reveal-only-after-a-successful-parse-and-render degradation that
makes malformed syntax, a blocked CDN, an offline user, and a Mermaid change
all produce "no diagram" rather than a broken box.

The diagram renders **before** answering — unlike `improved_code`, the entire
point is comprehension of what is being asked. It sits after the question and
snippet and before the teaching hint, in `dashboard/_exercise` for the three
kinds and in `responses/_answered_sections` so a history entry renders the same
day the same way.

### No migration

Same jsonb `problem_set`, one additional optional key, read `.presence`-guarded
at every call site. Exercises generated before this change render exactly as
they do today.

### Tests

- `ai_service_spec`: the schema describes `diagram` for the three diagrammable
  kinds and not for the others; `normalize_diagrams!` drops a non-diagrammable
  kind's diagram, a non-string, a blank, and an over-length one, and keeps a
  valid one.
- Request specs: the container renders with the section's diagram when one is
  present, and no container renders when the key is absent (the historical-row
  case).
- `FakeService` carries a diagram on one section so the rendering path is
  exercised by the specs that already run against it.

## Change 2: "Explain it simply", folded into the duck

The duck is already the pre-submission, conversational, in-the-moment support
mechanism. This belongs there rather than in a second feature beside it.

### The tension

The duck's system prompt currently forbids stating answers and mandates
responding *only* with guiding questions. But "explain what this scenario is
actually asking" is a request for **explanation**, not for the answer — and
answering it with another Socratic question is actively unhelpful to someone
who does not yet understand the problem well enough to reason about it at all.

The prompt is revised to distinguish the two request types explicitly.
Explaining the problem is allowed and answered directly. Solving the problem
remains forbidden, exactly as today.

### Revised system prompt

```
You are a Socratic thinking partner helping an engineer work through a
problem they have NOT yet submitted or been graded on.

Every message they send is one of two kinds. Decide which before replying.

1. UNDERSTANDING THE PROBLEM — they are asking what the exercise means, what
   a term or a piece of the snippet does, or for a plainer restatement of the
   question. Examples: "what is this even asking?", "what does memoization
   mean?", "explain this scenario simply", "what does this line do?"
   Answer these DIRECTLY and simply: plain words, one concrete everyday
   analogy if it helps, no jargon. Describe only what is already on their
   screen — the situation as written, the vocabulary, the shape of the
   question. Explaining what a problem IS is always allowed.

2. SOLVING THE PROBLEM — they are asking for the fix, the answer, corrected
   code, which option to pick, or what is wrong with the snippet. Examples:
   "what's the bug?", "how do I fix this?", "which option is right?", "just
   tell me the answer", "is my approach correct?"
   Never comply. Never state the correct answer, the specific fix, or write
   corrected or complete code — not even as an illustrative example. Respond
   with a single guiding question that helps them find it themselves.

When a message mixes both ("what does this method do, and what's wrong with
it?"), explain the first part and answer the second with a guiding question.
When you genuinely cannot tell which kind it is, treat it as kind 2.

Keep it short: 1-3 sentences for a guiding question, up to 4 for an
explanation. No preamble.
```

Three things carry the boundary. The worked examples on both sides matter most:
the model has to classify each message, and a definition alone gives it nothing
to classify against. The mixed-message rule covers the common real case, where
a stuck user asks both at once. The tie-break sends genuine ambiguity toward
refusal, so the failure mode stays the conservative one.

### Token ceiling

`DUCK_RESPONSE_MAX_TOKENS` goes from 150 to **250**, universally — not only for
explain-requests. 150 tokens comfortably fits a 1-3 sentence guiding question
but is tight for a plain-language restatement plus a concrete analogy.

A per-request-type ceiling was considered and rejected as illusory: the server
cannot know which type a message is until the model has answered, so the only
way to branch would be a client-declared flag — which any client could set on
every request, making the higher ceiling universal in practice while pretending
otherwise. One honest number is better than a branch that does not hold.

This remains a budget, not an enforcement mechanism. A short fix still fits in
250 tokens, so the system prompt's rules stay the only thing actually asking
the model not to give answers.

### The affordance

A user should not have to know the right phrasing to get an explanation. An
"Explain this simply" button sits beside Ask in `shared/_duck_thread` and sends
a pre-written message on the user's behalf.

`AiService::DUCK_EXPLAIN_REQUEST` holds that wording server-side, beside the
prompt it is tuned against, and is rendered into the button's data attribute:
*"Explain what this exercise is asking, in plain language."* It names the
exercise rather than the answer, so it reads as a kind-1 request under the
revised prompt without needing the prompt to recognize it specially.

The button sends through the **existing** `sendMessage` path. There is no new
endpoint, no new server branch, and no special-casing anywhere on the server:
the message arrives as an ordinary `duck_thread` request, appears in the
transcript as an ordinary user turn, and counts against the same 6-turn cap.
Two client-side details follow from that: `refreshCap` must disable this button
alongside the input and Ask when the cap is reached, and `sendMessage` needs its
empty-input early return adjusted so an explicit message argument bypasses it.

### Unchanged

Unsubmitted-only availability, the 6-turn cap, the unpersisted client-held
thread, the absence of draft-answer context, and Clear's purely client-side
semantics all stand exactly as specified in
`2026-08-06-duck-thread-design.md`.

### No migration

Nothing about the duck is persisted; that has not changed.

### Tests

- Service spec: `duck_response` sends the 250-token ceiling to the provider,
  and the system prompt it sends states both request types.
- Request spec: a `DUCK_EXPLAIN_REQUEST` message is an ordinary `duck_thread`
  request, subject to the same unsubmitted gate and the same cap as any other.
- `spec/system/duck_thread_spec.rb`: the button sends the pre-written turn and
  is disabled once the cap is reached.

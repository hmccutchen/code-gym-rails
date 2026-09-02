# Alternate Framings Inside the Concept Reference

**Goal:** When a `ConceptReference`'s single auto-generated explanation doesn't
land, give the reader somewhere to go — a second framing of the same concept,
asked for from inside the reference's own disclosure, capped at two.

**Architecture:** A new narrow `AiService` entry point and a one-action
controller. Nothing is persisted: the framings live in the tab that asked for
them and are sent back as prompt context on the next ask, the same shape the
duck thread takes. The shared `ConceptReference` row is read and never written.

**Tech Stack:** Ruby on Rails 8, RSpec, the existing `AiService`
template-method provider abstraction.

## Global Constraints

- **No migration, no new table, no new column.**
- **No change to `ConceptReference`'s generation, caching, or first-exposure
  auto-expand.** `GenerateConceptReferenceJob`,
  `AiService#generate_concept_reference` and
  `ConceptReferencesHelper#first_exposure?` are untouched; the only edit to
  `#build_concept_reference_prompt` extracts a sentence it already contained
  into a constant, and its output is byte-identical.
- **No change to the duck's scope.** Its responsibilities are deliberately not
  widened to cover this.
- **No new always-visible interface element.** The control renders inside
  `<details>`, so the element itself hides it whenever the dropdown is
  collapsed — no script does that work.

---

## Why this exists

`ConceptReference` auto-expands on a concept's true first exposure precisely so
a genuine beginner has a foothold before attempting anything. That fix closed a
real gap, but it left a smaller one: it is *one* auto-generated explanation with
no fallback. If it doesn't land, there is currently nowhere to go.

The duck is deliberately not the answer. `DUCK_SYSTEM_PROMPT` scopes its kind-1
"explain simply" mode to *"Describe only what is already on their screen — the
situation as written, the vocabulary, the shape of the question."* That is
describing a problem, not re-teaching a concept from zero, and the scoping is
intentional rather than a gap to route around.

`explain_differently` already solves this exact failure for review feedback.
This extends the same mechanism — a low-weight "try another angle" affordance,
a capped number of framings, an anti-repetition prompt — to the other place a
first explanation can fail.

## Why this isn't a teach-then-practice rotation

Considered and explicitly rejected.

Apps that gate practice behind a lesson step do it mainly because immediate
recall of just-read material creates an *illusion of competence* — it feels
like learning but doesn't transfer as well as spaced, effortful retrieval. This
app's existing model (attempt first, concept reference available immediately if
needed, the same concept resurfacing later through the mastery loop in a
different framing) is closer to what's actually better-evidenced.

The one legitimate reason those apps front-load teaching — a true beginner has
zero foothold — is already handled by the first-exposure auto-expand. A formal
rotation would be a step backward from that design, not a missing feature.

Difficulty-adapts-to-experience is also already live, via mastery tiers and
scaffolding fade. It simply isn't branded as a visible "rotation" the way other
apps surface it, which is consistent with tier state staying invisible
everywhere else in this app.

---

## The storage decision, resolved

`ConceptReference` is the app's one genuinely global record: unique on
`(concept, language)` where `language` is really the `ConceptBucket`, with no
`user_id`, and documented in `AiService` as generated once and cached forever.
So "where does a framing go" is a real question rather than a copy of
`review_alternates`.

**Chosen: nowhere. Nothing is persisted.**

The framings live in the tab that asked for them and are sent back on each
subsequent ask purely as prompt context, so the model knows not to reprise an
angle. `ConceptReferencesController#explain_differently` writes no row. The
precedent is `#duck_thread`, which is fully unpersisted for the same reason and
whose cap is documented as *"Soft, request-level… not a hardened boundary…
acceptable given each user pays for their own provider calls with their own
key."*

**Accepted cost, stated plainly:** a framing is gone on reload, and meeting the
concept again next week costs another call.

### Rejected: overwrite the shared row

Regenerating the `ConceptReference` in place is the smallest possible change and
was rejected on three counts. One engineer clicking would silently rewrite the
reference every teammate reads. The original framing — which may have partly
landed — would be destroyed rather than shown beside the new one, and *beside*
is the whole point of a second angle. And it changes `ConceptReference`'s
caching, which this work's constraints exclude.

### Rejected: an `alternates` jsonb on the shared row

Cheaper (the second reader gets the framings free) and not as wrong as
overwriting, since a framing isn't personalised — the prompt only ever sees the
concept. Rejected because the cap becomes a race between teammates: the second
engineer to meet the concept finds the control already gone and reads two
framings somebody else asked for. It also enlarges the cached artifact everyone
reads, and makes one person's key pay for team-wide content, against the
per-user-key model.

### Rejected: a per-user `concept_reference_alternates` table

The persistent option, and the one that best matches the semantics ("this
didn't land *for me*"). Rejected as heavier than the value: a migration, a
model, two associations, an anonymisation policy, and a memoised per-request
index to keep `/history` from firing a query per rendered reference — all to
buy "the framing survives a reload", which the duck already declines to buy for
itself.

### Rejected: `review_alternates` on `DailyResponse`

Not viable rather than merely heavier. No `DailyResponse` row need exist when a
first-exposure disclosure auto-opens — which is precisely the case this feature
exists for. The key is per-section rather than per-concept, so the cap would
re-burn every day the concept recurs. And it would make one column mean two
different things.

---

## The safety property, corrected

The brief asked to confirm that "the safety property already established for
`explain_differently`" still holds. Investigation says **no such prompt-level
property exists**: `AiService#explain_differently` contains no "don't hint at
the answer" rule, and needs none, because it only ever runs post-review — there
is no answer left to protect. The "never state the correct answer" language
lives only in `DUCK_SYSTEM_PROMPT`.

This surface *is* reachable pre-submission, so the property has to be
established here — and it is established the way this codebase already
establishes it, in the signature rather than the prompt:

```ruby
def explain_concept_differently(user, reference, prior_alternates: [])
```

No exercise. No `daily_response`. No section. The same narrow shape
`#generate_concept_reference` and `#assess_difficulty` take, and for the same
reason: it cannot hint at today's problem because today's problem is never
passed in. A prompt line ("Teach the concept itself; never solve, hint at, or
refer to any particular exercise") restates it, and the shared
`CONCEPT_REFERENCE_SCOPE` sentence — now stated once and used by both the
generating and the reframing prompt — carries the durable-reference framing. But
the guarantee is the argument list, and a spec pins it.

---

## Deviations from established in-repo patterns

Both are deliberate; both are named in the PR description as CLAUDE.md requires.

1. **A new `AiService` method rather than reusing `#explain_differently`.** That
   method reads `problem_set[section]["question"]`, the engineer's answer, and
   `ai_review[section]["missed"]` — every one of its inputs is review-shaped.
   Reusing it would mean nil-able `exercise`/`daily_response` arguments and a
   branch on which surface called it, trading the structural guarantee above
   for a runtime nil check.

2. **The new method passes `max_tokens`; `#explain_differently` doesn't.**
   Passing one is strictly better — it bounds a prose reply, and it is also what
   turns off the extended thinking `ClaudeService` otherwise leaves on. It is
   sized as a budget, like `DUCK_RESPONSE_MAX_TOKENS`, rather than derived from
   a schema like `DIFFICULTY_ASSESSMENT_MAX_TOKENS`, because free prose has no
   largest valid reply to derive from. `#explain_differently` is left alone:
   changing an existing billed path is not this change's business.

Two smaller choices worth recording. The cap constant lives on the controller,
per the rule already documented on `MAX_DUCK_TURNS_PER_SECTION` — the feature
owns no model data, and here that is literally true. It is deliberately *not*
derived from `DailyResponse::MAX_ALTERNATES_PER_SECTION` despite the equal
value: one bounds framings of a section's feedback, the other framings of a
durable concept, and coupling them would make either un-tunable. The
`{status:, error:}` render is a three-line private method on the new controller
rather than a hoist of `ResponsesController#render_section_error` into
`ApplicationController`, which would touch a hot shared file for one caller.

## Notes for a reader of the diff

- The script keys the framings it has been shown **by reference id**, not by
  container. One reference can render several times on a page — two sections of
  a day can carry the same concept, and `/history` renders many days — and
  per-container state would let one person spend the cap over again in each
  copy.
- `type="button"` on the control is load-bearing rather than stylistic: on the
  dashboard this partial renders inside `#gym-form`, so a default-type button
  would submit the day's answers and chain straight into the review.
- `spec/services/provider_request_characterization_spec.rb`'s header counted
  "six single-shot purposes" and "eight public AiService methods". The roster
  already held seven before this change; the counts are removed rather than
  bumped, matching `ai_service_spec`'s own stated reason for not writing one
  down.

# Security concepts, TypeScript-flavored JS, scenario-domain grounding, and a Security Review question type

Trimmed, critically-reviewed version of a broader proposal. GraphQL as a
tracked concept was cut (legacy-app-only, occasional-maintenance relevance —
not worth mastery-loop investment). Two originally-proposed security concepts
were cut for being poor fits for this app's format (see Change 1). What
remains is four independent changes, each shipped as its own commit with its
own passing tests before the next begins.

## Sequencing

1. Security concepts (Change 1)
2. TypeScript-flavored concepts folded into `JS_CONCEPTS` (Change 2)
3. Scenario-domain grounding (Change 3)
4. Security Review — new 4th question type (Change 4)

## Constraints across all four changes

- No changes to: magic-link auth, Resend/SMTP, timezone work,
  `ConceptReference`'s core mechanism (new concepts flow through existing lazy
  generation, unchanged), the suggested-concepts admin work, the mastery-tier
  system's core logic, or `User::LANGUAGES` (`ruby_rails`/`javascript`/`mixed`)
  — Change 2 does not add a new language value.
- **No migration in any of the four changes.** `problem_set`, `ai_review`,
  `concept_tags`, `answers`, and `section_ratings` are all jsonb columns — new
  keys and new concept strings need no schema change.
- Change 4 is the most involved. If it reveals more complexity than expected
  during implementation, stop and flag rather than forcing it through.

---

## Change 1 — Security concepts: four, chosen for genuine depth

Not every security-adjacent rubric item deserves a full tracked concept. The
mastery-tier system (Standard/Reduced/Paused, easing/reinforcing over time,
`ConceptMastery`) only adds value for concepts with real depth — room to be
approached multiple ways, room to get harder or easier.

Add to `AiService`:

```ruby
RAILS_CONCEPTS = %w[
  ... existing entries ...
  mass_assignment_protection sql_injection_prevention
].freeze

JS_CONCEPTS = %w[
  ... existing entries ...
  xss_prevention insecure_client_storage
].freeze
```

**Explicitly excluded, and why** (documented in a code comment alongside the
constants, not silently dropped):

- `secure_secrets_handling` — essentially one rule ("don't hardcode
  credentials"), no meaningfully harder version to graduate toward, so a
  reinforcement cycle has nowhere to go.
- `dependency_vulnerability_management` — a process/tooling habit (running an
  audit tool, reviewing a Dependabot PR), not something a code snippet can
  test. Wrong shape for this app's format entirely.

### Why this needs no other code changes

These four strings are added to the existing closed vocabularies, so every
mechanism that already keys off `RAILS_CONCEPTS`/`JS_CONCEPTS` picks them up
for free: `concept_vocabulary_for`, `normalize_concepts`,
`concepts_needing_reinforcement`, the retention-check bucket logic, and
`ConceptReference`'s per-`(concept, language)` lazy generation. No schema
change, no new bucket.

### Testing

- `AiService`/model specs asserting the four new concepts are present in
  their respective vocabularies and validate through `normalize_concepts`
  like any other concept (i.e. round-trip, not normalized to `"other"`).
- No new behavior to test beyond vocabulary membership — everything else is
  existing machinery.

---

## Change 2 — TypeScript-flavored concepts folded into `JS_CONCEPTS`

Per confirmed real usage (mixed TS/plain JS day to day), no new language mode.

Add to `JS_CONCEPTS`:

```ruby
generics type_guards_narrowing union_intersection_types mapped_conditional_types
```

### Prompt-level TS instruction

In `build_exercise_prompt`, add an instruction keyed off which concept a
section is tagged with:

> When a section's concept is one of `generics`, `type_guards_narrowing`,
> `union_intersection_types`, or `mapped_conditional_types`, write that
> section's code using real TypeScript syntax and type annotations. Every
> other JS_CONCEPTS section stays plain JavaScript — do not switch the whole
> set to TypeScript just because one section calls for it.

This can't be decided before generation (the model picks the concept), so
it's phrased as a conditional instruction rather than a parameter — same
pattern the existing `third_guidance` conditional already uses for
architecture vs. challenge.

### Confirmed no schema/migration change

Purely a prompt instruction keyed off the selected concept. `LANGUAGE_CONFIG`,
`User::LANGUAGES`, `DailyExercise::LANGUAGES`, and `language_for_today` are
untouched — TypeScript sections still persist under the `"javascript"`
generation language and bucket.

### Testing

- Vocabulary membership test, as in Change 1.
- Prompt-builder spec asserting the TS-syntax instruction text is present in
  `build_exercise_prompt`'s output (string-level check, consistent with how
  this file's other prompt instructions are already tested).

---

## Change 3 — Scenario-domain grounding

**Problem:** scenario framing (`code_review`/`pattern`/`challenge`/
`security_review`'s `scenario` field) is currently open-ended in the prompt,
risking generic SaaS-example drift rather than feeling like real engineering
work.

### New constant

```ruby
# Curated, real, job-adjacent scenario flavors for the "scenario" field's
# business-domain framing. Prompt-level grounding only — never concept-tagged,
# never fed into concept_vocabulary_for or any mastery-loop bucket. The
# GraphQL entry exists purely as occasional scenario dressing for legacy-app
# relevance; it must never become a tracked concept (see design doc).
SCENARIO_DOMAINS = %w[
  background_job_processing api_versioning_and_deprecation
  activerecord_query_construction component_state_management
  data_export_and_reporting webhook_delivery rate_limiting
  multi_tenant_data_isolation legacy_graphql_maintenance
].freeze
```

Exact list is a starting point — `legacy_graphql_maintenance` must render as
scenario-only framing (e.g. "a legacy GraphQL layer needs a fix"), never as a
`concept` value.

### Prompt change

In `build_exercise_prompt`, add an instruction directing scenario selection
toward this list while preserving the existing anti-repetition/variety logic
already in place (the "vary the concrete business-domain scenario... do not
reuse the class/method names or narrative framing" instruction stays as-is):

> Prefer drawing each section's business-domain scenario from this list:
> #{SCENARIO_DOMAINS.join(", ")}. Use `legacy_graphql_maintenance` rarely — at
> most roughly 1 in every 8-10 sessions — purely as scenario framing (e.g. "a
> legacy GraphQL layer needs a fix"), never as the tagged concept.

### Confirmed no schema/migration change

Prompt-level only. No new concept-vocabulary entries, no new jsonb field —
`scenario` already exists on every section shape.

### Testing

- Prompt-builder spec asserting `SCENARIO_DOMAINS` entries and the GraphQL
  frequency/framing instruction appear in `build_exercise_prompt`'s output.
- No behavioral/integration test is meaningful here (prompt adherence isn't
  something a unit test can verify) — consistent with how the existing
  variety instructions are (not) tested today.

---

## Change 4 — Security Review: new 4th question type

### Learning-science case (stated explicitly, per requirement)

`code_review` trains "does this work correctly." `pattern` trains
"recognize/apply a structural approach." `architecture` trains "reason about
system tradeoffs." None train adversarial thinking — looking for what *could
be exploited*, not just what could break. Interleaved practice across
categorically distinct reasoning types is a well-supported driver of
transfer, distinct from simply varying surface content.

### Concept reuse — the key refinement

Security Review does **not** get its own vocabulary. It draws from the exact
same four concepts added in Change 1
(`mass_assignment_protection`/`sql_injection_prevention` on Rails days,
`xss_prevention`/`insecure_client_storage` on JS days). Each concept gets
reinforced through two different reasoning modes on different days — once as
"is this correct" (`code_review`), once as "is this exploitable"
(`security_review`) — a deliberate, tighter interleaving design rather than
vocabulary sprawl.

Because these are ordinary language-bucketed concepts (not a pseudo-language
like `"architecture"`), every bucket-resolution call site that already does
`section == "architecture" ? "architecture" : language` needs **no change**
for `security_review` — it falls through to `language` correctly as-is. This
was verified directly:
- `ConceptMastery.record_review!` (`sections.include?("architecture") ? ...`)
- `User#recent_performance` / `#concepts_needing_reinforcement` /
  `#concept_exposure_index` (same ternary shape)
- `AiService#concept_vocabulary_for` (only special-cases `section_key ==
  "architecture"`)

### Rotation

Replace the current binary `roll_third_section` (60% architecture / 40%
challenge) with a named, tunable 3-way weighted constant:

```ruby
THIRD_SECTION_WEIGHTS = { architecture: 0.50, security_review: 0.25, challenge: 0.25 }.freeze

def roll_third_section
  r = rand
  return :architecture     if r < THIRD_SECTION_WEIGHTS[:architecture]
  return :security_review  if r < THIRD_SECTION_WEIGHTS[:architecture] + THIRD_SECTION_WEIGHTS[:security_review]
  :challenge
end
```

Daily set stays ~3 sections — this is a rotation into the existing
third-section slot, not a 4th always-present section. Existing tests that
stub `roll_third_section` continue to work; new tests cover the
`:security_review` branch and the weighting split (statistical/seeded, same
approach as any existing test of the 60/40 split).

### Schema (`exercise_schema_for`)

New `third_section` branch for `third == :security_review`, adversarial
framing distinct from `code_review`'s general-correctness framing:

```
"security_review": {
    "title":     "string",
    "question":  "string — what security vulnerability exists here, and how would you mitigate it",
    "snippet":   "string — #{label} code, ~10-15 lines, containing a real vulnerability",
    "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
    "concept": "string — exactly one concept from the provided vocabulary",
    #{glossary_field},
    "reference": {
      "tagline":      "string — bold one-liner",
      "explanation":  "string — 2-3 sentences",
      "code_example": "string — annotated code, ~15 lines",
      "senior_lens":  "string — when to reach for it / tradeoffs"
    }
  }
```

`reference` reuses the `tagline`/`explanation`/`code_example`/`senior_lens`
shape (same as `code_review`/`pattern`'s implicit reference shape and
`build_concept_reference_prompt`'s cached-reference shape) — **not**
architecture's `tradeoffs`-plural shape, since this is code-shaped, not a
decision.

### Prompt (`build_exercise_prompt`)

New `third_guidance` branch for `:security_review`:

> The third section is a SECURITY REVIEW, not a general correctness check.
> The snippet must contain one real, exploitable vulnerability appropriate to
> #{label}. The question asks the engineer to identify the vulnerability AND
> propose a mitigation — not just "what's wrong with this code."
> Choose this section's concept from this vocabulary, exactly one:
> #{security_concepts.join(", ")} — these are the ONLY concepts security_review
> may use, never one from code_review/pattern's broader vocabulary.

Unlike the architecture branch, no separate `ARCHITECTURE_CONCEPTS`-style
constant is needed at the `concepts` local-variable level — the restricted
list is looked up per language via `config_for(language)[:security_concepts]`
(a new `security_concepts:` key alongside each language's `concepts:` key in
`LANGUAGE_CONFIG`), holding exactly the four concepts added in Change 1
(`RAILS_SECURITY_CONCEPTS`/`JS_SECURITY_CONCEPTS`). `concept_vocabulary_for`
(used by `normalize_concepts`) special-cases `section_key == "security_review"`
the same way it already special-cases `"architecture"`, so an off-list pick
is normalized to `"other"` rather than silently accepted because it happens
to appear elsewhere in the language's full vocabulary.

### Review (`build_review_prompt`)

New `third_block` branch with its own criteria, distinct from `code_review`'s
correctness-based grading — assessed on whether a real vulnerability was
correctly identified and whether the mitigation is sound, not graded against
one single expected answer:

> Security Review (#{security_review["title"]}): #{security_review["question"]}
> Snippet: #{security_review["snippet"]}
> Their answer: #{answers["security_review"].presence || "(skipped)"}
>
> Evaluate on whether they correctly identified a real, exploitable
> vulnerability and whether their proposed mitigation is sound — not against
> a single expected answer. Partial credit for identifying the vulnerability
> without a complete mitigation, or vice versa, should show up in "missed."
> "improved_code" here must show the mitigated version of the snippet.

`improved_code` is included for `security_review` (unlike `architecture`,
which forces it empty) — this is code-shaped, and the mitigated snippet is
exactly the artifact a senior reviewer would produce.

### Model layer

- `DailyExercise#security_review` — new accessor, mirrors `#architecture`/
  `#challenge`:
  ```ruby
  def security_review = problem_set["security_review"]&.with_indifferent_access
  ```
- `DailyExercise#third_key` — new helper, returns whichever of
  `"architecture"`/`"security_review"`/`"challenge"` is actually present in
  `problem_set`:
  ```ruby
  def third_key
    return "architecture"     if problem_set["architecture"]
    return "security_review"  if problem_set["security_review"]
    "challenge"
  end
  ```
  Replaces the ad hoc `arch ? "architecture" : "challenge"` pattern in
  `build_review_prompt`, which becomes a 3-way dispatch on `exercise.third_key`.
- `ConceptMastery.record_review!`'s bucket ternary: **no change** (verified
  above).
- `DailyResponse#improved_code_visible?`'s `section.to_s == "architecture"`
  exclusion: **no change** — `security_review` is not excluded, so it follows
  the normal concept-exposure-count gating like `code_review`/`pattern`.

### Controller/view touch points (traced directly against current code)

- `app/controllers/responses_controller.rb`:
  - Line ~276-277 (`answers:`/`section_ratings:` permitted-params arrays) —
    add `:security_review`.
  - Line ~282 (`exercise_concept_tags`'s `%w[code_review pattern challenge
    architecture]`) — add `"security_review"`.
  - The `language = section == "architecture" ? "architecture" :
    exercise.language` line (~296) needs no change — falls through correctly.
- `app/models/user.rb`:
  - Line ~94 (`recent_performance`'s `%w[code_review pattern challenge
    architecture]` scenario-section list) — add `"security_review"`.
  - The two `bucket = section == "architecture" ? "architecture" : ...`
    ternaries (~130, ~184) need no change — fall through correctly.
- New `app/views/responses/_security_review_section.html.erb`, modeled on
  `_architecture_section.html.erb`'s shared submitted/unsubmitted structure,
  but code-shaped like `_challenge`'s inline markup: snippet display, answer
  textarea, rating row. No Mermaid diagram, no `options` list (those are
  architecture-specific).
- `app/views/dashboard/_exercise.html.erb` and
  `app/views/responses/_answered_sections.html.erb`: extend the `if (arch =
  exercise.architecture) ... elsif (ch = exercise.challenge)` chains to a
  third branch (`elsif (sr = exercise.security_review)`), using
  `exercise.third_key` where a discriminator string (not the section hash) is
  needed.

### Testing

- `AiService` spec: `roll_third_section` weighting (seeded/stubbed, same
  pattern as the existing 60/40 test); `exercise_schema_for(third:
  :security_review)` produces the expected shape; `build_exercise_prompt`
  includes the security-review-specific guidance and the shared (not
  architecture-style) concept vocabulary line; `build_review_prompt` selects
  the security_review `third_block` and its distinct grading instructions
  when `exercise.third_key == "security_review"`.
- `DailyExercise` spec: `#security_review` accessor; `#third_key` returns the
  correct key for all three shapes.
- `ConceptMastery` spec: a `security_review`-tagged concept buckets under the
  exercise's language (not `"architecture"`) — regression-style test
  confirming the no-change claim above.
- `DailyResponse` spec: `#improved_code_visible?` is not excluded for
  `security_review`, follows the same exposure-count gate as `code_review`.
- Request spec: submitting/rendering a security_review-shaped daily exercise
  end to end (dashboard unsubmitted render, submit, history read-only render)
  — mirrors the existing architecture/challenge request-spec coverage.

### Out of scope for Change 4

- Any change to the mastery-tier core logic (`ConceptMastery`'s tier
  transitions, retention scheduling) — security concepts flow through it
  unmodified.
- Any new concept vocabulary or `SuggestedConcept` bucket — security_review
  reuses Change 1's four concepts exclusively.
- A separate reference-generation path — `security_review`'s `reference`
  shape reuses `build_concept_reference_prompt`'s existing
  tagline/explanation/code_example/senior_lens format as-is.

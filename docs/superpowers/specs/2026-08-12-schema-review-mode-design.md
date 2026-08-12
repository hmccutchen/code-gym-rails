# Schema-review mode, and equal third-slot weights

Date: 2026-08-12
Branch: `feat/schema-review-mode`, from `main` after #82 and #83 merged.

Two changes. The first adds a third content mode to `code_review`; the second
flattens the third-slot rotation. They ship together because both are about
variety in what a day looks like, but they are independent and land in
separate commits.

## Why

Data modeling is an assessed gap: the rubric this work comes from lists
"Strong Migrations and Data Migrations" at Advanced Beginner and "Data
migrations" at Competent. Nothing in Code Gym currently exercises it — every
`code_review` snippet is application code or, occasionally, a test file.

The third-slot bias toward `architecture` (0.75, then 0.50, then 0.40) was a
considered choice each time. It is being reversed deliberately, in favour of
variety, not adjusted silently.

## Investigation findings

Two premises in the original brief turned out to be wrong, and the design
follows from correcting them.

**There is no existing test-file roll.** Mode selection today is one sentence
in the prompt body — "Roughly 1 in 4 sessions, make it an RSpec-style test
file..." The model decides; nothing in Ruby does, nothing verifies it, nothing
records it. So there was no roll to stack a second probability onto.

**Candidate 1 did not cover `code_review`.** Guidance facets went to the six
*rolled* kinds only. `code_review` and `pattern` inherit the base
`generation_guidance`, which raises `NotImplementedError`, and code_review's
instruction sits inline in `build_exercise_prompt`. This work closes that gap
rather than working around it.

## Change 1: schema-review mode

A third content mode for `code_review`. Same section key, same question shape,
same grading pipeline — only the snippet's subject changes. The artifact is a
proposed migration containing one planted data-modeling flaw.

### Mode selection

`DailyPlan` owns it, like every other "what shape is today's set" decision:

```ruby
# Equal thirds, as close as float weights get — application_code keeps a 1%
# edge rather than pretending the split is exact.
CODE_REVIEW_MODE_WEIGHTS = {
  application_code: 0.34, test_file: 0.33, schema_review: 0.33
}.freeze
```

`DailyPlan::Result` gains `code_review_mode`. `AiService#generate_exercise`
threads it into the prompt, and it joins `third` and `fourth` in the
difficulty-diagnostics payload, so "do schema days grade differently?" becomes
answerable from a week of logs.

Three weighted rolls now exist, so `roll_third_section` and
`roll_fourth_section` collapse into one `roll_weighted(weights)` rather than
gaining a third copy of the cumulative-weight loop.

### The artifact, per language

`LANGUAGE_CONFIG` gains a `schema_artifact` key, mirroring the existing
`test_framework` key exactly — present for the two real languages, absent for
the pseudo-language buckets, guarded on presence at the point of use.

| Language | Artifact |
| --- | --- |
| `ruby_rails` | a Rails migration |
| `javascript` | a Prisma schema change, with the migration it generates |

The JavaScript artifact is the schema change *and* its migration, not the
schema file alone: `unsafe_migration` cannot be planted in a `schema.prisma`,
which has no migration semantics. Including the generated migration keeps all
five concepts expressible in both languages, which is the whole basis for one
shared `DATA_MODELING_CONCEPTS` list.

Prisma rather than Mongoose because it is relational: `missing_index` means
the same thing in both languages, so the two vocabularies stay parallel and
per-language mastery history stays comparable. A document-store artifact would
have made `wrong_cardinality` and `denormalization_tradeoffs` mean different
things per language, forcing the concept lists to diverge.

### Vocabulary

Five concepts, identical in both languages, so one shared constant rather than
two lists that could drift:

```ruby
DATA_MODELING_CONCEPTS = %w[
  missing_index wrong_cardinality missing_constraint
  denormalization_tradeoffs unsafe_migration
].freeze
```

Folded into `RAILS_CONCEPTS` and `JS_CONCEPTS`. **No new
`ConceptBucket`, no `ConceptBucket` change** — the section key is still
`code_review`, so a language-independent bucket could not be selected even if
one existed. Per-language mastery tracking is the accepted cost, and is
arguably correct: indexing and migration-safety concerns differ enough between
an ActiveRecord/Postgres context and a Prisma one to be worth tracking apart.

This differs from `RAILS_SECURITY_CONCEPTS` / `JS_SECURITY_CONCEPTS`, which
are two constants because their contents genuinely differ. Here they do not.

#### Concepts considered and rejected

Applying the depth filter that trimmed the security vocabulary — cut anything
that is one flat rule with no harder version to graduate toward:

- `nullable_when_required` — **cut.** One rule ("should this be NOT NULL?")
  with no harder version, and a strict subset of `missing_constraint`. Keeping
  both would split one skill's mastery history across two names.
- `unnecessary_denormalization` — **renamed** to `denormalization_tradeoffs`.
  The original name presupposes the answer, so an exercise could never ask "is
  this denormalization justified?" — capping the concept's ceiling at exactly
  the level the mastery loop is supposed to grow past. Matches
  `data_consistency_tradeoffs` in `ARCHITECTURE_CONCEPTS`.
- `unsafe_migration` — **included.** The artifact under review *is* a
  migration, so its operational safety is in frame by construction. Three-tier
  depth: it takes a lock → the backfill-then-constrain sequence across deploys
  → knowing when the safe path is not worth its complexity.

#### Mode-scoped concepts

Only the new mode is scoped. The other two keep the vocabulary they have
today, minus the five new concepts, which have no business on a day that isn't
about schemas:

| Mode | Draws from |
| --- | --- |
| `application_code` | the language vocabulary **minus** `DATA_MODELING_CONCEPTS` |
| `test_file` | the language vocabulary **minus** `DATA_MODELING_CONCEPTS` |
| `schema_review` | `DATA_MODELING_CONCEPTS` |

This means **no existing mode's vocabulary changes at all** — subtracting the
five additions from the extended list returns exactly the 20 Rails concepts
app-code and test-file days draw from today. The only vocabulary behavior this
change introduces is the restriction on schema days.

An earlier draft also scoped `test_file` to a `TESTING_CONCEPTS` subset, so
that `over_mocking` could not be tagged on a non-test day. That is a real
improvement and it is **deliberately deferred**: it changes behavior for a mode
this work otherwise leaves alone, and this change already carries a new content
mode, five concepts across two vocabularies, a three-way roll, and a rotation
reweight. It is a clean standalone follow-up — and by then the retention
instrumentation may say whether mode-scoped concept selection matters at all.

`pattern` keeps the full language vocabulary, unchanged. This is load-bearing:
it is the only section that can host a data-modeling concept on a non-schema
day, which keeps a due retention check reachable.

### Where the prompt text lives

`CodeReview` and `Pattern` gain their own `generation_guidance`, so all eight
kinds state their own vocabulary and none speaks for another. This dissolves
issue #81 rather than patching it: the misplaced line has nowhere left to
live, because no kind has a slot for another kind's instruction. The
`language_vocabulary:` parameter disappears from the signature entirely — it
existed only to carry that misplacement.

```ruby
generation_guidance(vocabulary:, label:, mode: nil)
```

`mode` is documented as "the rolled content mode, for kinds that have one —
only `code_review` does today."

`schema_fragment` is untouched. The field stays `"snippet": "string — <label>
code, ~10-15 lines"`; the mode-specific instruction lives in the guidance, so
no kind's schema changes and the signature stays `schema_fragment(label:)`.

### Rendering

Nothing to do. A schema-review day still produces `code_review` with a
`snippet`, so it flows through `responses/bodies/_code_review.html.erb` and the
existing `<pre class="snippet">` treatment. No view, submitted render, or
history entry knows a mode exists.

Known cosmetic wrinkle, accepted: `hljs_language` maps the day's language to
`ruby` or `javascript`, so a Prisma schema on a JavaScript day is highlighted
as JavaScript. Prisma's DSL mostly will not match, so it renders as near-plain
text rather than wrongly coloured. A per-mode highlighting hint is machinery
for a cosmetic edge.

### Interaction: retention annotation

**This is the one place the mode roll reaches beyond code_review's own
generation branch.**

`annotate_retention_concept` tells the model which sections a due concept may
occupy. Its existing comment already describes this hazard for architecture
concepts: without the annotation the model "guesses wrong, and
`normalize_concepts` rewrites a correctly-honored check into a false miss."

Per-mode restriction creates a second instance. The annotation must now
account for the mode:

- a **data-modeling** concept: `pattern` always, `code_review` only on a
  schema-review day
- an **ordinary** concept: `pattern` and the day's third as today, plus
  `code_review` on any day that is *not* a schema-review day

That last line has a consequence. `DailyPlan.for` computes:

```ruby
# An exercise has only 3 sections, so only the first 3 reinforcement
# concepts can ever occupy one
slots = 3 - reinforcement.first(3).size
```

For ordinary concepts that `3` becomes 2 on the one day in three that rolls
schema review.

**Decision: annotate correctly, leave the arithmetic at 3, and comment the
approximation at the point of the read so it is not later mistaken for
exactness.** The arithmetic is advisory end to end — nothing verifies
placement, the reinforcement list is routinely truncated, and over-requesting
by one costs a concept the model could not have placed anyway.

Making `slots` mode-aware would reopen the subtlest state machine in the app
for marginal gain. `DailyPlan`'s correctness rests on structural separation
rather than on arguments about interacting conditions — which is exactly why
candidate 3 of the architecture review (collapsing its two parallel slot
tracks) was declined. Threading a `code_review` content variant into slot math
is the same trade, for less.

"Instrument and see" is not deferral here: `log_retention` already records
offered-versus-honored per bucket, so the question routes to something that
answers it with data rather than to a later judgement call.

## Change 2: equal third-slot weights

```ruby
THIRD_SECTION_WEIGHTS = {
  architecture: 0.25, security_review: 0.25, challenge: 0.25, parsons_problem: 0.25
}.freeze
```

The commit message states that this deliberately reverses the architecture
bias — 0.75 → 0.50 → 0.40 → equal — as a considered trade of depth-in-one-area
for variety. `FOURTH_SECTION_WEIGHTS` stays 50/50.

## Testing

**Prompt snapshots gain a fourth axis.** Currently language × third × fourth =
16. With mode that is 2 × 4 × 2 × 3 = **48**. The full cross-product rather
than a sample, for the reason the axis was added in the first place: the #81
fix relocates code_review's vocabulary line while the mode changes what that
line says, so a regression where a third's guidance re-absorbs it would
surface only in specific pairings.

They rebaseline **twice, once per behavior change** — the #81 fix commit (the
vocabulary line moves) and the schema-mode commit (guidance gains a mode
clause) — so each diff is attributable to one cause.

**Two existing specs are deleted, not adapted**, because they pin behavior
this change deliberately removes:

- `spec/models/exercise_section_spec.rb` — `raises for code_review, which
  carries no guidance`, and the same for `pattern`.
- `spec/services/daily_plan_spec.rb` — `returns :architecture below 0.40,
  :security_review from 0.40-0.60…` and its `rand` stubs at the old
  boundaries. Rewritten for equal quarters.

**New coverage:**

- `roll_weighted` as one shared helper, replacing two copies
- `CODE_REVIEW_MODE_WEIGHTS` sums to 1.0; every mode reachable
- `code_review_mode` on `DailyPlan::Result` and in the diagnostics payload
- `CodeReview.generation_guidance` per mode: schema-review names only
  `DATA_MODELING_CONCEPTS`, the other two name the vocabulary minus it
- `Pattern.generation_guidance`
- `vocabulary_for` returning the mode-scoped list
- `annotate_retention_concept` naming the right hosts for a data-modeling
  concept on a schema day versus any other day

`section_rendering_characterization_spec` needs nothing: no new kind, no new
field.

## Out of scope

- **No database migration.** Vocabularies are frozen Ruby constants; concepts
  are strings already stored in existing `jsonb` and `concept_masteries.concept`.
  New concepts create rows through existing machinery on first use. Existing
  rows are untouched.
- **No new `ExerciseSection` kind**, no new bucket, no `ConceptBucket` change.
- **No mastery-tier changes.** New concepts flow through existing machinery.
- **No `FakeService` change.** No new section kind, so its canned payload
  already covers everything.
- **No `test_file` scoping.** Deferred to a standalone follow-up, so this
  change alters no existing mode's vocabulary.
- **This spec is not committed to the PR.** Planning docs stay out of PRs by
  standing preference; the file is committed locally to be read and removed
  before the branch is pushed.

## Commit sequence

0. Repoint six code comments at design docs that do not exist —
   `docs/superpowers/specs/` is untracked, so the paths in `user.rb`,
   `sessions_controller.rb`, `responses_controller.rb` (x2) and
   `ai_service.rb` (x2) resolve to nothing. Repoint the two with a tracked
   counterpart under `docs/superpowers/plans/`, drop the rest. Unrelated to
   the feature, so it lands first and alone. Files under
   `docs/superpowers/plans/` are left as-is: they were accurate when written
   and are historical records, not live guidance.
1. Fix #81 — `CodeReview` and `Pattern` gain `generation_guidance`, the stray
   vocabulary line is removed from the thirds, `language_vocabulary:` is
   dropped. Snapshots rebaseline.
2. Extract `roll_weighted`; no behavior change.
3. Equal third-slot weights (Change 2).
4. Add the vocabularies and the `schema_artifact` config.
5. Roll `code_review_mode` in `DailyPlan`, thread it through, add the
   mode-scoped guidance and retention annotation. Snapshots rebaseline, now
   across 48 combinations.

# Four-book concept audit: Clean Code, Refactoring, DDD, The Pragmatic Programmer

Status: implemented.

## Why

The mastery loop grades against a closed vocabulary of 94 distinct concepts.
Several were lifted from books — `shallow_module`, `pass_through_method`,
`temporal_decomposition`, `cognitive_load` and `unknown_unknowns` are
*A Philosophy of Software Design*'s vocabulary; `god_object`,
`primitive_obsession`, `shotgun_surgery` and `feature_envy` are *Refactoring*'s
— but nothing in the repo said so. An engineer who wanted to read further had
no pointer, and a concept's origin was recoverable only by someone who already
recognized the term.

No citation structure existed before this pass. A sweep of `app/`, `spec/`,
`config/`, `db/`, `docs/` and `lib/` for `BOOK`, `SOURCES`, `citation`, `cite`,
`author`, `ISBN`, `chapter`, every author surname and every book title returned
zero hits: no constant, no column on `concept_references`, no locale key, no
prompt line. The only nod to a book anywhere was an unattributed comment in
`spec/services/ai_service_spec.rb` reading "Chapter 2's causes of complexity".
So `ConceptBookSources` is created array-valued from the start rather than
migrated from a 1:1 mapping.

## Method

Each candidate idea drawn from the four books was resolved in this order:

1. **Overlap check against all 94 concepts**, not only the nearest group.
2. **Subset-reasoning test:** would the *generated exercise* for this idea be
   distinguishable from an existing concept's generated exercise? If not, it is
   the same concept wearing a different name.
3. **Depth filter** (the one used to trim the security vocabulary): does it have
   room to be approached several ways and to get harder or easier?
4. **Gradeability:** can a section tagged with it contain exactly one specific,
   findable issue? The generic rubric has nothing to put in "missed" otherwise.

An idea that already exists does **not** become a new concept. It becomes an
additional citation on the existing one, and the existing concept's definition
and grading criteria are left untouched — citation is additive metadata, never
a redefinition.

The repo has strong precedent for cutting near-twins rather than shipping them:
`single_responsibility`, `program_to_interface`, `encapsulate_what_varies`,
`liskov_substitution`, `interface_segregation`, `information_leakage`,
`special_general_mixture` and `change_amplification` were all considered and
cut. That bar is applied here unchanged.

## Constraint held throughout

No passage from any of these books is quoted, paraphrased to the point of
reproduction, or invented. Every idea is explained in this app's own words. A
citation is a pointer — title, author, and where the book has one, the term the
book itself coined. Never a chapter number and never a page: a number recalled
rather than checked is a fabrication, it reads as authoritative, and nothing in
CI can catch it.

## Disposition table

### Refactoring (Fowler) — code-smell catalog

Confirmed: heavy overlap, citation-only, **zero new concepts**.

| Book idea | Existing match | Disposition |
| --- | --- | --- |
| Shotgun Surgery | `shotgun_surgery` | citation |
| Feature Envy | `feature_envy` | citation |
| Primitive Obsession | `primitive_obsession` | citation |
| Data Clumps | `primitive_obsession` | citation — same exercise: these fields travel together and should be an object |
| Large Class | `god_object` | citation |
| Divergent Change | `god_object` | citation — one class with many reasons to change generates `god_object`'s section; `single_responsibility` was already cut as its rule-side twin |
| Middle Man | `pass_through_method` | citation — APOSD's name for the same shape |
| Lazy Element | `shallow_module`, `pass_through_method` | citation |
| Message Chains / Law of Demeter | `feature_envy` | citation — both are "this code reaches through another object's structure"; the violation is less findable than `feature_envy`'s, which is the test that cut `program_to_interface` |
| Insider Trading | `feature_envy` | citation |
| Data Class | `feature_envy`, `primitive_obsession` | citation |
| Repeated Switches | `open_closed` | citation — its canonical violation, already named in `oo_design_violation_guidance` |
| Refused Bequest | `composition_over_inheritance` | citation |
| Speculative Generality | `scope_creep` (plan), `pass_through_method` (code) | citation — in a plan it is scope creep; in code its usual form is a layer that forwards and adds nothing |
| Mutable Data, Temporary Field | `array_mutation_pitfalls` (JS), `unstated_mutation` (plan) | citation |
| Duplicated Code | `shotgun_surgery` | citation — see the DRY row below |
| Global Data | — | **no concept.** Its gradeable forms are already `concurrency` and `cache_key_completeness`; on its own it fails the depth filter |
| Long Function, Long Parameter List, Loops, Comments, Mysterious Name, Alternative Classes with Different Interfaces | see Clean Code rows | resolved there |

### Clean Code (Martin) — functions, naming, SRP

Confirmed: significant overlap, citation-only, **zero new concepts**.

| Book idea | Existing match | Disposition |
| --- | --- | --- |
| Functions do one thing / SRP | `god_object` (class scale), `conflated_responsibilities` (plan scale) | citation — `single_responsibility` is already on record as cut for generating the same section as `god_object` |
| Meaningful names / Mysterious Name | `reading_for_intent` | citation — a name that lies *is* "one real divergence between what the code is evidently for and what it does", which is `meta_skill_framing_guidance`'s own wording for `reading_for_intent`'s section |
| Comments that restate or lie | `reading_for_intent` | citation — the same divergence; also already a house rule in `CLAUDE.md` and a BLOCKING review check, so it is governed rather than untracked |
| Function arguments, flag arguments | `shallow_module` | citation — an interface that charges every caller, which is what the module-design group names |
| Error handling: exceptions over codes, don't return null | `error_handling`, `undefined_failure_path` | citation |
| Boundaries / wrapping third-party code | `dependency_inversion`, `build_vs_buy` | citation |
| Clean tests, F.I.R.S.T., one concept per test | `over_mocking`, `testing_implementation_not_behavior` | citation |
| Classes should be small / cohesion | `god_object`, `coupling_cohesion` | citation |
| **Command-Query Separation** | `unstated_mutation` | **citation — the closest near-miss in the audit.** Its violation is very findable (a predicate that also persists), and it would be mechanically legal as a language-vocabulary concept since `PSEUDOCODE_TO_CODE_CONCEPTS` is disjoint. Declined: a step that changes state without announcing it is the same defect the plan-level concept already names, and shipping both would be a twin justified only by which bucket it lands in. Recorded so it is not re-proposed blind |

### Domain-Driven Design (Evans)

Confirmed: the most novel of the four. **Two genuinely uncovered concepts.**

| Book idea | Existing match | Disposition |
| --- | --- | --- |
| **Ubiquitous Language** | none | **NEW concept `ubiquitous_language`** |
| **Aggregate / aggregate root / invariant boundary** | none | **NEW concept `aggregate_boundaries`** |
| Bounded Context | `service_boundaries` | citation — both generate "where does the boundary go and what does crossing it cost"; indistinguishable as an architecture section |
| Entity vs Value Object | `primitive_obsession` | citation — the value-object half is `primitive_obsession`'s exercise (extract a small type); the identity half has no findable violation of its own |
| Anemic Domain Model | `feature_envy` | citation — a service that envies the model's data. The standing tension with Rails' own `service_objects` concept, which advocates the shape Evans warns about, is left unresolved deliberately: this is a citation, not a redefinition |
| Domain Events | `event_driven_vs_request_response` | citation |
| Repository | `query_objects` | citation |
| Specification | `policy_objects` | citation |
| Anticorruption Layer | `dependency_inversion`, `semantic_input_validation` | citation — "you imported the vendor's shape straight into your domain" splits across those two and adds nothing on top |
| Context Map, Shared Kernel, Conformist, Partnership | — | **no concept.** Team-topology material; nothing a single graded section can host |

#### Why the two new ones survive

`ubiquitous_language` — the defect is that code and domain disagree on a word:
the table is `orders`, the business says *bookings*, and two unrelated things
are both called `Order`. Checked against `reading_for_intent` (that is code
whose behavior diverges from its evident purpose — here the code does exactly
what it says, and the *name* is what is wrong), against `primitive_obsession`
(a missing type, not a wrong word), and against `spotting_unstated_assumptions`
(a plan's gap, not a naming one). One findable issue, gradeable, and it gets
harder as the collision gets subtler.

`aggregate_boundaries` — which cluster of rows must change together, and which
object is the only legal entry point for changing them. Checked against
`transaction_safety` (the mechanics of wrapping writes; this is *which* writes
belong in one), `missing_constraint` (a database constraint, not an ownership
boundary), `wrong_cardinality` (the shape of a relationship, not its
consistency boundary), `data_consistency_tradeoffs` (strong against eventual at
system altitude, not model altitude) and `data_ownership` (which *service* owns
data, not which object). One findable issue, gradeable, scales in difficulty.

### The Pragmatic Programmer (Hunt & Thomas)

Confirmed: citation-only, **zero new concepts — including both coined terms.**

| Book idea | Existing match | Disposition |
| --- | --- | --- |
| **DRY** *(the explicit test case)* | **`shotgun_surgery`** | **citation. Resolved as NOT a gap.** `code_smell_naming_guidance` already describes the DRY-violation section verbatim — "a change that would touch six call sites". A section planting one rule implemented in three places and a section planting a change that touches six call sites are the same exercise, graded the same way. The house rule in `CLAUDE.md` ("when a rule starts appearing in a second place, move it to one place both call") and the BLOCKING review check ("does any rule now appear in two places?") both name this defect, and `shotgun_surgery` is what tracks it. Fowler's Duplicated Code lands in the same cell |
| **Orthogonality** | **`coupling_cohesion`** (architecture), `shotgun_surgery` (code-level symptom) | **citation. Resolved as NOT a gap.** `coupling_cohesion` is this idea at system altitude; `feature_envy` and `dependency_inversion` carry the class-level forms |
| Design by Contract | `validations`, `semantic_input_validation`, `missing_constraint` | citation |
| Crash Early / assertive programming | `error_handling`, `undefined_failure_path` | citation — also already the house principle "fail loudly at the boundary" |
| Programming by Coincidence | `separating_symptom_from_cause`, `spotting_unstated_assumptions` | citation — a strong match to the meta-skill group |
| Configuration, parameterize from the outside | `unjustified_constant` | citation |
| Reversibility / no final decisions | `build_vs_buy`, `api_versioning` | citation |
| Decoupling / Law of Demeter | `coupling_cohesion`, `feature_envy` | citation |
| Shared state and concurrency | `concurrency`, `transaction_safety` | citation |
| Tracer bullets, estimating, version control, broken windows, the debugging attitude | — | **no concept.** Practice and process, not something a single graded section can host |

#### One nuance recorded but deliberately not acted on

Pragmatic's DRY is about duplicated *knowledge*, not duplicated text — two
identical-looking blocks that encode different decisions are not a violation,
and deduplicating them is the mistake. `shotgun_surgery`'s guidance line does
not draw that distinction. Adding a citation must not change any concept's
grading criteria, so the guidance line is untouched here. Logged as a possible
follow-up, not folded in.

## Vocabulary-size impact

| | Before | After |
| --- | --- | --- |
| `RAILS_CONCEPTS` | 42 | **44** |
| `JS_CONCEPTS` | 44 | **46** |
| `ARCHITECTURE_CONCEPTS` | 15 | 15 (unchanged) |
| `PLAN_REVIEW` / `AMBIGUITY_HUNT` / `PSEUDOCODE_TO_CODE` | 4 / 5 / 8 | unchanged |
| Distinct concepts repo-wide | 94 | **96** |
| Learn slice, `ruby_rails` user | 74 | **76** |
| Learn slice, `javascript` user | 76 | **78** |
| Concepts carrying at least one citation | 0 | **35** |

Two new rows to backfill at roughly $0.02 each against `claude-sonnet-5`.
Citations add no provider call at all.

## Shape of the citation store

`ConceptBookSources::SOURCES` maps a concept to an **array** of sources, from
the first day — `shotgun_surgery` needs two immediately, which is the proof the
shape is right rather than speculative. A source is `title`, `author`, and an
optional `pointer` naming the term the book coined.

It is a hand-curated constant rather than a generated `concept_references`
column because a generated citation is a hallucinated citation and the row is
cached forever. `SOURCES` is never sent to a provider, and a spec pins that by
asserting no source title appears in the concept-reference prompt.
`CONCEPT_REFERENCE_FIELDS` and `CONCEPT_GUIDE_FIELDS` are untouched: widening
either would silently change `#explain_concept_differently`'s prompt and the
required-field check.

Scope of the backfill: every concept the four books land on, and for each of
those, *all* its genuine sources rather than only the four in scope — so
`shallow_module` carries *A Philosophy of Software Design* before
*Refactoring*'s Lazy Element. Concepts none of these books touch stay uncited;
a later pass can widen it.

# Learn tab — browsable concept education

Design spec. Written 2026-09-09.

## What this adds

A new top-level nav destination, `/learn`, listing every concept in the
vocabularies a user can be assigned — not only the ones they have met in an
exercise. Each entry shows the existing cached `ConceptReference` plus a
richer, plainer-language guide: a worked example narrated end to end, and the
mistakes people actually make. Longer and more thorough than the inline
dropdown, and deliberately short of an essay.

Nothing about `ConceptReference`'s existing behavior changes. The inline
first-exposure auto-expand, the `(concept, language)` cache, the alternate
framings, and the dropdown's rendering all stay exactly as they are. This adds
content alongside them and a second place to read it.

## The tradeoff this makes knowingly

Everywhere else in this app, explanatory content is gated on exposure.
`ConceptReference` auto-expands only on a concept's true first encounter, so a
beginner has a foothold before attempting something — and stays collapsed
otherwise, because reading an explanation before attempting a problem replaces
effortful retrieval with recognition, which feels like learning and transfers
worse. `AiService#explain_concept_differently` is handed no exercise for the
same family of reasons.

**This tab shows the full explanation for a concept before the user has ever
been given a problem on it.** That trades away the productive-struggle
protection deliberately, in exchange for a library someone can read on their own
initiative — which is a different activity from being handed a hint mid-attempt.

A locked or title-only teaser — entries visible, content withheld until first
real exposure — was offered explicitly and declined.

**This is scoped to this tab and is not a precedent.** It does not license
loosening exposure gating anywhere else: not the inline dropdown's collapse
default, not the auto-expand rule, not the duck's explain mode, not the
scaffold-fade or mastery-tier machinery. A future change that wants to show
content earlier on any other surface argues for itself from scratch; it does
not get to cite this one.

Two properties keep the trade bounded, and both must survive any later change
here:

- **The Learn tab can never reach today's problem.** Generation is
  `AiService#generate_concept_reference`, which is handed a concept and a
  language and nothing else — no exercise, no response, no section. That is the
  same signature guarantee `#assess_difficulty` and
  `#explain_concept_differently` carry, and it is what makes "this cannot hint
  at today's answer" structural rather than a prompt line.
- **The tab reveals no mastery state.** See "Encountered marker" below.

## Scope per user

A user's slice is **their language plus all four language-independent
buckets**:

| Bucket | Concepts |
| --- | --- |
| `ruby_rails` *or* `javascript` | 38 / 40 |
| `architecture` | 15 |
| `pseudocode_to_code` | 8 |
| `ambiguity_hunt` | 5 |
| `plan_review` | 4 |

70 or 72 entries for a pinned user. A user whose `language` is `"mixed"` sees
**both** language buckets plus the four agnostic ones — 110 entries — because a
mixed user genuinely gets assigned both.

Read `user.language`, **not** `User#language_for_today`. `language_for_today`
resolves "mixed" to one concrete language for a single day's generation by
flipping off the last exercise; the Learn tab is a library, not a day, and its
contents must not change depending on which language tomorrow happens to be.

The universe is 110 `(concept, bucket)` pairs across all buckets — 90 distinct
concept *names*, since the shared groups (`META_SKILL_CONCEPTS`,
`CODE_SMELL_CONCEPTS`, `OO_DESIGN_CONCEPTS`, `MODULE_DESIGN_CONCEPTS`,
`DATA_MODELING_CONCEPTS`) deliberately live in both language vocabularies and
get one row per language.

## Decision 1 — Generation consistency: one request, one response

The richer content is produced by the **same** `generate_concept_reference`
call that already produces the inline reference, in one request. Not a second
independently-triggered generation.

This is what actually keeps the two explanations from contradicting each other
as vocabularies and prompts change over time. A second call would be consistent
only by hope; one response is consistent by construction. The Learn entry
renders the shallow reference *and* the guide, so the two are visibly the same
artifact rather than two accounts of one concept that drifted apart.

### Fields: three columns on `concept_references`

```
guide_plain_language   text, null
guide_worked_example   text, null
guide_pitfalls         text, null
```

Justified against the existing schema:

- **Discrete `text` columns, not jsonb.** The table's existing four fields are
  already discrete `text` columns named by a constant. The jsonb columns in this
  app (`problem_set`, `ai_review`, `answers`) hold variable-shaped provider
  payloads whose keys vary per day; this content has a fixed shape. Following
  the table's own precedent.
- **Not a new associated model.** A 1:1 `ConceptGuide` would have the same
  lifecycle, the same key, and be written in the same response. The join buys
  nothing, and splitting one artifact across two tables presents it as two —
  the opposite of what this decision exists to establish.
- **Nullable.** A row without a guide is a real, expected state: every row that
  exists today is one. Nullability is what lets the backlog drain
  incrementally instead of requiring a flag day.

`ConceptReference#guide?` — all three present — is the single authority for
"does this row have a guide." Nothing else recomputes it; no separate
`guide_generated_at` column, since presence already answers the only question
anyone asks.

### Two constants, not one

`AiService::CONCEPT_GUIDE_FIELDS = %w[guide_plain_language guide_worked_example
guide_pitfalls]`.

`CONCEPT_REFERENCE_FIELDS` is **not** extended. It is read by
`#explain_concept_differently` to build "the reference they have already read";
adding the guide to it would change that existing prompt, which this change is
not allowed to do.

### The guide is not added to the required-field check

`#generate_concept_reference` currently raises `InvalidResponseError` when any
of the four reference fields is blank, so the job swallows it and retries on the
next submission. **That check keeps covering exactly those four.**

Extending it to seven would mean a provider that produced a good reference but
flubbed the guide now fails where it used to succeed — a first-exposure
reference that would have existed for the inline dropdown wouldn't. That is a
behavior change on an existing surface, which the constraints forbid.

So: the reference fields stay required; the guide fields are persisted when
present and left null when not. A response that flubs the guide leaves a shallow
row, indistinguishable from a legacy row, which the on-demand path below
regenerates when someone opens it. Self-healing, and existing behavior is
preserved exactly.

This follows the codebase's stated rule — fail loudly at the boundary for what
downstream code depends on, degrade gracefully in the UI for what it doesn't.
Nothing downstream *depends* on a guide; an entry without one still renders.

### Prompt

`#build_concept_reference_prompt` gains the three guide fields in its schema and
the instruction shaping them. The existing `CONCEPT_REFERENCE_SCOPE` line — the
one statement of what a reference is for — governs the guide too and is not
duplicated. The guide asks for:

- **`guide_plain_language`** — what this actually is, in words a competent
  engineer who has never met the term would follow. No jargon that isn't
  unpacked in place.
- **`guide_worked_example`** — one concrete scenario narrated end to end: the
  situation, what goes wrong or what the decision costs, and what changes. May
  contain code.
- **`guide_pitfalls`** — what people get wrong about it and why the wrong idea
  is appealing.

Length: each part is bounded in the prompt to a few short paragraphs. The brief
is "more thorough, not an essay," and the failure mode of a length-unbounded
prompt here is a wall nobody reads.

The existing `LANGUAGE_AGNOSTIC_VOCABULARIES` branch already decides whether
`code_example` shows real source or pseudocode. `guide_worked_example` reuses
that same decision rather than restating it.

`ANTI_SHAPE_CONCEPTS` already flips `senior_lens` from "when to reach for it" to
"how to catch it early," because a shape you find is never a technique you
choose. `guide_pitfalls` is written to read correctly under both framings
without a second branch — "what people get wrong about it" is true of a smell
and of a principle alike. **No new per-concept branching is introduced.**

### Migration

One migration. Three `add_column` calls, `text`, nullable, no default, no index.
Metadata-only on Postgres; no table rewrite, no backfill in the migration
itself.

```ruby
class AddGuideFieldsToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :guide_plain_language, :text
    add_column :concept_references, :guide_worked_example, :text
    add_column :concept_references, :guide_pitfalls,       :text
  end
end
```

## Decision 2 — Generation trigger

**Recommended: eager backfill for concepts with no row at all; on-demand
regeneration for legacy rows that have a reference but no guide.**

### Why the cost argument points the other way than expected

The decisive fact is one the brief didn't assume: **`concept_references` has no
`user_id`.** It is a global, team-wide cache keyed on `(concept, language)`.
One person's generation serves everyone, permanently.

Per generation, with the guide included — `claude-sonnet-5` at $2.00 / $10.00
per MTok:

- Input ~300 tokens → ~$0.0006
- Output ~2,000 tokens → ~$0.020. That is roughly 1,200 visible tokens plus
  ~800 of thinking: **`#generate_concept_reference` passes no `max_tokens`, and
  `ClaudeService` only disables extended thinking when a caller supplies one**,
  so this call thinks and is billed for it, today and after this change.
- **≈ $0.021 per concept.**

These are **upper bounds** — a full slice with nothing cached. The backfill
skips every concept that already has a guide, so the real first run costs less
by however much the team has already generated.

| | concepts | cost |
| --- | --- | --- |
| One user's slice, nothing cached | 70 | **~$1.47** |
| Every concept in every bucket, forever | 110 | **~$2.31** |
| A second teammate's backfill | mostly already cached | **~$0** |

Gemini users pay materially less — `gemini-3.5-flash` is roughly an order of
magnitude cheaper per token than `claude-sonnet-5`.

These are estimates from prompt shape, not measurements. `ApiUsage` rows carry
`tokens_in`/`tokens_out` under `purpose: "generate_concept_reference"`, so the
real figure is checkable after the first backfill runs, and should be checked.

On-demand-only does not save this money. It spends the same total, later, and
buys a worse library: with thinking on and no `max_tokens`, a cold entry is a
10–20 second wait. Sixty concepts explored one 15-second wait at a time is not
browsing. The brief's framing of on-demand as "cheap, incremental" holds for a
per-user cache; it does not hold for a shared one.

### What the backfill covers, and what it doesn't

- **No row exists** (the majority — most of the 110 have never been assigned to
  anyone): the backfill creates it, reference and guide together, in one call.
  There is no existing text to disturb.
- **A row exists without a guide** (every row generated before this change):
  **not touched by the backfill.** It is regenerated in full — reference and
  guide, one call, one response — the first time someone opens that concept's
  Learn entry.

That split is deliberate. Filling a legacy row means re-running the whole call
and overwriting the reference text alongside it, since decision 1 requires both
halves to come from one response. Doing that in bulk would silently rewrite
inline dropdown text across concepts nobody asked about. Doing it when the entry
is opened confines the rewrite to a concept a person deliberately went looking
at.

Consequence, stated plainly: **an inline reference's wording can change once,
for a concept someone opens in the Learn tab.** The concept and its meaning do
not change; the prose is regenerated. This is the accepted cost of keeping the
two explanations consistent by construction.

### How the backfill is triggered

Not automatically, and not on deploy. It spends the user's own provider key, so
the user starts it: the Learn index shows how many concepts in their slice have
no guide and roughly what generating them costs, behind one button.

- Enqueues one `GenerateConceptReferenceJob`-shaped job per missing concept.
- **Idempotent and resumable.** Each job re-checks for an existing row with a
  guide before calling, exactly as the current job re-checks for an existing
  row. A half-finished backfill is resumed by pressing the button again; there
  is no run record to keep, and no state to reconcile.
- Failures are swallowed and logged per concept, as the existing job does. One
  provider hiccup costs one concept, not the run.
- Rate: enqueued as ordinary Solid Queue jobs. No new queue, no new schedule.

Because rows are global, the second person to press it finds almost everything
done and pays almost nothing. The first person pays ~$1.50 for the team. That
asymmetry is real and is worth surfacing in the button's copy rather than
hiding.

### Reusing the existing job

`GenerateConceptReferenceJob` already does almost all of this: it skips
`"other"`, re-checks for an existing row, resolves `AiService.for(user)`,
handles `RecordNotUnique` from a concurrent winner, and swallows
`AiService::Error`. It gains one thing — a guide-aware existence check, so a row
that exists *without* a guide is regenerated rather than skipped, and an
argument saying whether this call is allowed to do that.

Keeping one job rather than adding a second is the point: there is one way a
`ConceptReference` comes into being, and adding a parallel path would be a
second place for the two explanations to diverge.

### API usage accounting

The call keeps `purpose: "generate_concept_reference"`. It is the same call; a
second purpose name would describe the trigger, not the request, and would split
one line item into two for no analytical gain. The consequence — backfill spend
is not separable from organic spend in `ApiUsage` — is accepted. A backfill is a
burst on one date, which is legible enough.

## Decision 3 — Organization

### Routes

```
GET /learn                      → LearnController#index
GET /learn/:bucket/:concept     → LearnController#show
POST /learn/:bucket/:concept/prepare  → generation for one concept (JSON)
POST /learn/prepare             → the slice backfill
```

An index plus a per-concept page, rather than 70 accordions on one page. The
detail page keeps the index light, gives each concept a linkable URL a teammate
can paste, and makes the cold-entry loading state an ordinary page rather than
JavaScript reshaping a hidden `<details>` body.

`:bucket` and `:concept` are validated against the closed vocabularies on the
way in — `ConceptBucket.vocabulary_for` already answers "which concepts belong
to this bucket," and an unknown pair is a 404. This is provider-independent
input from a URL, so it is checked at the boundary like everything else.

### Grouping

The index groups by bucket. The four agnostic buckets are flat lists (15, 8, 5,
4 entries) and need nothing more.

The language bucket is 38–40 entries, too many for one flat list — and it is
already composed of named groups in `AiService`. It is sub-grouped using those
existing constants:

- Core `<language>` — the base list
- Data modeling — `DATA_MODELING_CONCEPTS`
- Reading and reasoning — `META_SKILL_CONCEPTS`
- Code smells — `CODE_SMELL_CONCEPTS`
- Design principles — `OO_DESIGN_CONCEPTS`
- Module design — `MODULE_DESIGN_CONCEPTS`

A new pure class, `ConceptGroup`, is the single authority for "which display
group does this concept fall in, and in what order do groups render." It
derives from the constants rather than restating their membership, so a concept
moving between groups moves in one place. Pure — no database, no provider — so
its specs need none, matching `DailyPlan`'s collaborators.

Group membership is display-only. It has no relationship to `ConceptBucket`,
which decides where mastery history records, and must not acquire one.

### Filtering

A client-side filter box on the index: type, and non-matching entries hide.
~15 lines of inline script, matching this app's established idiom (the layout
emits no importmap tags; inline `<script>` is how every interactive surface here
works).

No server-side search route, no query parameter, no new index on the table. 70
entries already in the DOM filter instantly, and a round trip would make the
interaction worse. The same box gives "only ones I've seen" as a checkbox for
almost nothing (see below).

## Decision 4 — Encountered marker

A binary chip — "in your sets" — on entries the user has encountered.

`User#concept_exposure_index` already builds `[concept, bucket] => [dates]` from
submitted responses, memoized, in one query. The marker is therefore free: no
new query, no new column, no new counter.

**Binary, not a count, and never derived from `ConceptMastery`.** This is the
constraint that matters. `ConceptMastery` holds tier, streak, and retention
state, which this app keeps invisible everywhere by design — the post-hoc
difficulty rating went to considerable lengths to avoid becoming a second
readout of it. A Learn-tab marker sourced from mastery would be exactly that
readout. Exposure ("you have seen this") is a different fact from mastery ("how
well you did"), and only the first is shown.

A count was considered and rejected on the same reasoning: "seen 7 times" reads
as a score, and reading it next to concepts marked once invites the tier
inference the binary marker forecloses.

Nothing about mastery-tier logic, retention scheduling, or concept tagging
changes. This is a read of an existing index.

## Rendering

A Learn entry renders, in order:

1. The concept name and bucket.
2. `tagline`, `explanation` — the existing reference fields, unchanged.
3. `guide_plain_language`.
4. `code_example` — existing, through the existing `hljs_language` treatment.
5. `guide_worked_example` — same syntax-highlighting treatment where it contains
   code.
6. `guide_pitfalls`.
7. `senior_lens` — existing.

Showing the reference fields *inside* the guide is the visible half of decision
1: a reader sees one account of the concept, deepened, not two competing ones.

An entry with no guide renders the reference alone plus a control to generate
one. An entry with no row at all renders the concept name and that same control.
Neither is an error state; the library is browsable from the first page load,
before anything has been generated.

Copy comes from I18n (`learn.*`), matching the rest of the app.

## Testing

- `ConceptReference#guide?` — present, partially present, absent.
- `ConceptGroup` — every concept in each language vocabulary lands in exactly
  one display group, none is orphaned, and group ordering is stable. The four
  agnostic buckets render flat and have no groups. This spec is what catches a
  language vocabulary growing a new named constant without a group to render it
  in.
- `AiService#generate_concept_reference` — returns guide fields; **still raises
  when a reference field is blank; still succeeds when only guide fields are
  blank.** That second assertion is the one guarding the preserved behavior, and
  it must not be weakened.
- `AiService#explain_concept_differently` — the prompt it builds is unchanged by
  the new columns. A characterization assertion, since the risk here is a
  silent widening of `CONCEPT_REFERENCE_FIELDS`.
- `GenerateConceptReferenceJob` — persists guide fields; skips a row that
  already has a guide; regenerates a row that has a reference but no guide when
  asked to; still swallows provider errors.
- Request specs — `/learn` groups and scopes to the user's slice; a `"mixed"`
  user sees both languages; `/learn/:bucket/:concept` 404s on an off-vocabulary
  pair; the no-guide and no-row states render; `#prepare` enqueues only what is
  missing.
- The exposure marker reflects submitted responses only, and today's
  in-progress response does not mark a concept seen.
- Browser verification of the filter box and the cold-entry loading state
  before this is called done — the inline-script surfaces in this app are not
  covered by request specs.

## Out of scope

- No change to mastery tiers, retention scheduling, or concept tagging.
- No change to the inline dropdown's auto-expand rule, collapse default, or
  alternate framings.
- No per-user persistence of anything in this tab.
- No search backend, no pagination — 70 entries do not need either.
- No admin surface for editing references.
```

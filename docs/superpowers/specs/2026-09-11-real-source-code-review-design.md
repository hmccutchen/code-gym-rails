# Grounding `code_review` in Code Gym's own source — design

**Scope:** the `application_code` and `schema_review` modes of the existing
`code_review` section kind. `test_file` is untouched. No new section kind,
no new vocabulary, no change to grading, `RAILS_CONCEPTS`,
`DATA_MODELING_CONCEPTS`, or the three-way `CODE_REVIEW_MODE_WEIGHTS` split.
No migration.

**Shape:** a planted flaw in a modified copy of real source, flowing through
the existing generate → ingest → grade pipeline unchanged. Never real source
shown unmodified with an open-ended "what's wrong" — always one specific,
findable, planted issue tagged with a concept from the existing vocabulary.

## Mechanism

`RealSource` (`app/models/real_source.rb`) is a curated registry of excerpts,
in the same shape as `ExerciseSection`: two closed Ruby arrays, one per mode,
and nothing is eligible unless deliberately added. Each entry is one of two
small classes — `RealSource::Method` (a file path plus a method name) or
`RealSource::Migration` (a migration file, whole) — and each answers the
per-entry questions itself: what its text is, whether it still resolves, what
its scenario line says, and what the generation prompt says about it. Adding
an entry is adding a line; adding a new *kind* of excerpt is adding a class,
never a branch in shared code.

**Read at generation time, off local disk.** `File.read` relative to
`Rails.root`, on the deployed source itself — plain local I/O, not an external
call, and it guarantees the excerpt is exactly what is currently deployed.

**Scoping is by method name, resolved with Prism.** A `Method` entry names
`path` and `method`; at read time the file is parsed with Prism and the first
`def` with that name is sliced out by its exact start/end line. Prism was
already in the lockfile, but only as `irb`'s transitive dependency — nothing
in a production boot requires it, so the first pick in a Puma process raised
`NameError` (caught in review). `real_source.rb` now requires it explicitly
and the Gemfile declares it: no new install, but a dependency the app owns
rather than one it borrowed from a console gem a Rails upgrade could drop. Line ranges were
rejected: every unrelated edit above a method would shift them, silently
handing the exercise the wrong lines. A method name survives edits elsewhere
in the file and only breaks when the method itself is renamed or removed —
which a spec catches (below). `Migration` entries need no scoping; the file
is the unit.

**Size is a spec, not a comment.** Every entry's excerpt must resolve and land
inside `RealSource::MIN_LINES..MAX_LINES` (5–40). A one-line migration has no
room to plant a flaw; a 60-line method is not a one-sitting read. The bound
enforces the "focused method or small chunk" constraint mechanically rather
than trusting curation.

**A stale entry degrades, it does not break generation.** `RealSource.pick`
skips any entry that no longer resolves (file gone, method renamed), logging
each skip, and falls through to toy generation if none remain. The spec that
asserts every entry resolves is the primary guard; the runtime skip is what
keeps a renamed method from turning into "couldn't generate a set" for every
user until someone fixes the list.

## Where the decision lives, and where the read lives

`DailyPlan.for` already rolls `code_review_mode`. It now also decides
`code_review_source` — an entry or nil — on `Result`, so the choice is made
before any provider is contacted, alongside every other decision about the
day's shape. The *entry* is chosen there; its *text* is read later by
`AiService` when rendering the prompt, so `DailyPlan` stays what it is: a
decision, not a prompt. (Resolvability is checked at pick time, which is a
parse, not a prompt.)

The gate, in order:

1. The day's language is `RealSource::LANGUAGE` (`"ruby_rails"`). Code Gym
   is written in Ruby; a `javascript` day asks for JS/React code or a Prisma
   schema, and this codebase has neither. Toy generation stays at 100% on
   those days. **This gate was not in the brief and is forced, not chosen.**
2. The rolled mode has a pool — `test_file` has none, by construction.
3. A second weighted roll, `WeightedRoll.pick(RealSource::WEIGHTS)`, lands
   `:real` (Decision 1).
4. `RealSource.pick(mode, last_seen:)` chooses the entry (variety, below).

## The persisted trace, and variety

`code_review_mode` is never persisted — it is rolled, prompted, logged, and
gone. So a least-recently-used preference has nothing to read unless the pick
leaves a trace. `ProblemSetIngest` stamps the chosen entry's id into
`problem_set["code_review"]["source"]` — the existing jsonb column, so no
migration — and `RealSource.last_seen_for(user)` reads `{ id => last date }`
back out of that user's exercises in one grouped query.

`RealSource.pick` then orders the pool the way `SectionRotation` orders kinds
and `ConceptReference.featured` orders concepts: an entry this user has never
seen outranks every dated one, ties among never-seen drain in list order (so a
fixed order empties the pool one per pick and bounds the worst-case wait at
the pool size, which a coin flip among equals would not), and among seen
entries the oldest date wins. Per-user rather than team-wide because the
stated concern is one *reader's* recognition replacing reasoning.

This is the brief's "soft, non-blocking preference," implemented because it
turned out to cost one query and no schema — not because it became a rule.

## Decision 1 — real-vs-toy sub-weight: 35%

`RealSource::WEIGHTS = { real: 0.35, toy: 0.65 }`, one constant for both
modes. Inside the brief's 30–40% range; the reasoning for the specific number:

`code_review` runs every set, and each of the two modes rolls ~⅓ of days, so
at 35% a real-source `application_code` day arrives roughly once per 8–9
weekdays and a real-source `schema_review` day about as often. Against the
starter pool (11 methods, 4 migrations) under LRU, a given method resurfaces
about every two months and a given migration about monthly. Two months is
comfortably past recognition for the methods. Monthly is on the frequent side
for migrations — and that is an argument for growing *that* pool, not for
lowering the weight: at 20% the whole feature would surface every few weeks
and stop being a thing the set does. The weight has room to rise as the pool
grows; the pool is what should grow first.

One weight rather than two: the modes have no reason to differ today, and two
constants for one idea is a second rule that can disagree. Per-mode weights
are a one-line change if the pools ever diverge enough to justify them.

## Decision 2 — scenario framing: plain, and it says the copy is altered

When real source is used, `scenario` states that this is Code Gym's own code,
names the file and method, and **says the copy has been altered**. That last
part is not optional honesty; it is what stops an engineer from reading the
exercise as a bug report against deployed code and going to "fix" a method
that is fine. The framing is set by the server, not the model: the model is
told the exact string, and `ProblemSetIngest` stamps it regardless — a
scenario for a real-source day is a fact the server knows, not creative
output, and "validate provider output at the boundary" applies to a field the
provider could otherwise fictionalize.

Exact strings:

- `Method`:
  > Code Gym's own source — `app/services/weighted_roll.rb`, `#pick` — altered for this exercise. The deployed method is fine; find what this copy gets wrong.
- `Migration`:
  > Modelled on Code Gym's own migration — `create_push_subscriptions`. This is not that migration; find the data-modeling flaw in this one.

Two strings because the two modes make different promises (Decision 4): a
method is a modified *copy*; a migration is *modelled on* the original.

## Decision 3 — the modification instruction

The `Method` prompt block, replacing the mode's toy line:

> The code_review snippet is a MODIFIED COPY of this real method from Code
> Gym's own source (`<id>`). Reproduce its shape, names, and structure as the
> starting point, then introduce EXACTLY ONE flaw that expresses the chosen
> concept. Never return it unchanged — there would be nothing to find — and
> never introduce a second flaw, since grading assumes exactly one. Keep the
> real class, method, and variable names; do not rewrite it into a fictional
> domain. The scenario field must be exactly: "<scenario>"
>
> ```ruby
> <excerpt>
> ```

Both failure modes the brief names are addressed by name — unchanged
("nothing to find") and over-modified ("grading assumes exactly one") — and
the fictional-domain rewrite is forbidden explicitly, since that is the
model's default behaviour for this section and the thing the whole feature
exists to replace.

## Decision 4 — migrations are reference material, not mutated in place

Confirmed as the brief anticipated. Real migrations here are short and clean
(`add_column :users, :adaptive_set_size, :boolean, default: true, null:
false` is the whole file); mutating one in place leaves almost no room for a
data-modeling flaw, and forbids the interesting kind (a *new* migration on a
real table that gets cardinality or an index wrong). So the `Migration` prompt
block hands the model the real migration as style and table reference and
asks for a structurally similar one:

> The code_review snippet is a Rails migration MODELLED ON this real one from
> Code Gym's own schema history (`<id>`) — same conventions, same style, on
> the same table(s): either a modified copy of it or a plausible next
> migration for that table, whichever gives the flaw room. ~10–15 lines,
> containing EXACTLY ONE planted data-modeling flaw; never zero, never two.
> The scenario field must be exactly: "<scenario>"
>
> <migration text>

The scenario string says "modelled on" and "this is not that migration"
(Decision 2), so the two framings cannot drift apart.

## Starter pool

`APPLICATION_CODE` — eleven methods across seven files, each a real decision
with something to get wrong, sized 5–26 lines:

| File | Method | Why |
|---|---|---|
| `app/services/weighted_roll.rb` | `pick` | float-boundary rounding; a planted `<=` or dropped `round` is subtle and real |
| `app/services/section_rotation.rb` | `pick_kind` | starvation-then-weighted selection |
| `app/services/section_count.rb` | `for` | early-return override |
| `app/models/concept_reference.rb` | `claim_feature` | unique-index race recovery |
| `app/models/user.rb` | `carry_forward` | savepoint + double uniqueness |
| `app/models/user.rb` | `authenticate_login_code` | expiry, attempt cap, digest compare |
| `app/models/user.rb` | `current_streak` | the deliberately-empty weekend branch |
| `app/models/push_subscription.rb` | `register!` | upsert under a race |
| `app/controllers/sessions_controller.rb` | `verify_code` | session-bound code redemption |
| `app/services/ai_service.rb` | `flatten_history` | the brief asked for this file |
| `app/services/ai_service.rb` | `annotate_retention_concept` | mode-aware host resolution |

`SCHEMA_REVIEW` — four migrations, chosen for having *structure* to get wrong:

| Migration | Why |
|---|---|
| `create_push_subscriptions` | `create_table` with references, `null: false`, unique index |
| `add_reminder_level_to_users` | explicit `up`/`down` with a data backfill |
| `add_featured_on_to_concept_references` | nullable column with a unique index |
| `add_pseudocode_rounds_to_daily_responses` | jsonb with a default |

`add_adaptive_set_size_to_users` (named in the brief) was considered and left
out: one line, nothing structural to plant.

## What is deliberately not here

- No confidentiality exclusion. Reconsidered and reversed per the brief:
  nothing in this source is a per-instance secret; the hidden data this app
  protects is generated at runtime and stored in the database. `ai_service.rb`
  is in the pool.
- No per-user configuration, no toggle. The weight is a constant.
- No caching of file reads. Deployed source does not change within a process,
  so a per-process memo would be safe — but the cost is a few parses once a
  day, and a cache is a thing to invalidate.
- No change to `FakeService`. It ignores the prompt; on a real-source day for
  a fake user, ingest stamps the scenario onto its canned set exactly as it
  would a provider's, which is the correct behaviour and needs no special
  case.

## Tests

**The suite pins the sub-roll to `:toy` by default** (`spec/support/real_source_default.rb`), and an example that exercises the grounded path opts out with its own `:real` stub. This is not how the mode roll is handled — mode is left random and only the examples that care pin it — and the difference is deliberate: the mode roll changes only the prompt, so a canned provider response comes back through ingest identical either way, whereas the real-source roll changes what ingest *stamps*. Every pre-existing example asserting on a delivered set became nondeterministic at 35% the moment the roll existed; the first full run under it failed one such example, and a 12-run loop reproduced the flake at 5/12. A per-example pin would have been one pin per `generate_exercise` call (thirty in `ai_service_spec` alone) and a trap for the next test author.

- `spec/models/real_source_spec.rb` — every entry resolves and sits inside the
  line bounds (the drift guard); ids are unique; `Method` slices exactly
  `def`..`end`; `Migration` returns the whole file; pick honours never-seen →
  list order → oldest-seen and skips an unresolvable entry; `test_file` has an
  empty pool; each class's scenario and instruction carry the strings above.
- `spec/services/daily_plan_spec.rb` — `code_review_source` is nil on a
  `javascript` day, nil on `test_file`, nil when the roll lands `:toy`, an
  entry when it lands `:real`, and consults the user's own history.
- `spec/services/problem_set_ingest_spec.rb` — stamps `scenario` and `source`
  when given an entry, touches nothing when not, tolerates a missing section.
  No database, as before.
- `spec/services/ai_service_spec.rb` — the prompt carries the excerpt and the
  modification instruction when a source is given; `#generate_exercise`
  threads `plan.code_review_source` to the prompt, to ingest, and to the
  diagnostics log; and the prompt is byte-identical to before when the source
  is nil — this is the fourth instance of the additive-kwarg pattern after
  `cache_system:`, `max_tokens:`, and `history:`, and it is pinned the same
  way.

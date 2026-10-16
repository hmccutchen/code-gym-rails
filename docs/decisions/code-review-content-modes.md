# `code_review` content modes

`code_review` rolls one of three content modes per day (`DailyPlan::CODE_REVIEW_MODE_WEIGHTS`, roughly even) — `application_code` (realistic snippet, unchanged from before modes existed), `test_file` (a realistic test file exhibiting one test smell, in the day's `test_framework`), or `schema_review` (the day's `schema_artifact` — a Rails migration or a Prisma schema change with its migration — carrying one planted data-modeling flaw). Only `schema_review` narrows the vocabulary, to `ConceptVocabulary::DATA_MODELING_CONCEPTS` (`ConceptVocabulary.selectable_for_section`); the other two modes get the full list minus those concepts, unchanged from before modes existed. `pattern` and the rotating third deliberately keep the full vocabulary regardless of the day's `code_review` mode, so a due data-modeling retention check has somewhere to land on a non-schema-review day that includes either of them — a short day may include neither, and `DailyPlan` only offers a check a chosen kind can host. Because that lets a data-modeling concept surface where no schema artifact is shown, `GenerationPrompt::ConceptGuidance#data_modeling_idiom_guidance` adds one prompt line — stated once for all sections, named from the constant — telling the model to express such a concept in the host section's own idiom (a `pattern` question about `wrong_cardinality` asks how the relationship should be modeled, not for a migration to review). Advisory prompt text, no new machinery; `[retention]` logs are the check on whether it lands.

**Two of the three modes can be grounded in Code Gym's own source.** On a
`ruby_rails` day whose mode is `application_code` or `schema_review`, a
second roll (`RealSource::WEIGHTS`, 35% real) may hand the model a real
excerpt from this codebase instead of asking for a toy scenario — one
planted flaw, in a modified copy of a method or in a new migration modelled
on a real one, through the same ingest and grading as any other
`code_review`. `test_file` is untouched by construction: it has no pool.
`RealSource` (`app/models/real_source.rb`) is the curated registry, in
`ExerciseSection`'s shape — closed lists, one class per kind of excerpt
(`Method`, scoped by name and sliced with Prism; `Migration`, the whole
file), nothing eligible unless added there. It exists for exercise
*quality*, not safety: nothing in this source is a per-instance secret, and
`ai_service.rb` is in the pool. `DailyPlan` decides the excerpt
(`Result#code_review_source`); `GenerationPrompt` reads its text at prompt time;
`ProblemSetIngest` stamps the server's own `scenario` — which names the
file and says the copy is altered, so the exercise cannot read as a bug
report against deployed code — and a `source` id into the section. That id
is the only persisted trace (`code_review_mode` itself never is), and
`RealSource.last_seen_for` reads it back so `.pick` can prefer what this
user has not seen, in the same never-seen-first, list-order-ties shape
`SectionRotation` uses. Gated to `RealSource::LANGUAGE` because this
codebase is Ruby; a `javascript` day stays toy. A migration is reference
material, never mutated in place — a one-line `add_column` has no room for
a flaw — so the model writes a next migration for the same table. A
migration file never states everything its table has (`t.references` adds
an index it never names, and later migrations can change the table), and
the grader never sees the original, so
`RealSource::Migration#current_schema` also slices each table the migration
touches out of `db/schema.rb`, found and sliced with Prism the way a
`Method` is, and the instruction asks for a snippet that applies cleanly to
it: no column the table already has, and no index whose default name
already exists. A modified copy of the original is not offered, because the
current table beside it would show the fix. `ProblemSetIngest` stamps that
definition into the section as `current_schema`, server-owned like
`scenario`, and deletes one a provider returns on any other day or in any
other section. The page shows it collapsed under the snippet, and the
grader, the duck and the difficulty assessment all read it. That gives the
model what it needs to avoid a column or index the table already has; it
does not enforce it, and nothing checks the output. A stale entry, including a
migration whose table has left the schema, is skipped with a warning rather
than failing generation; a spec holds every entry resolvable and inside
`MIN_LINES..MAX_LINES`.

**Self-reference here is deliberate, and the pool leans into it.** Code Gym
is a working learning app, so its own pause-and-resume, spaced-repetition,
mastery-cooldown, adaptive-sizing and reminder methods are the one place an
education-domain exercise can be grounded without a fictional scenario the
engineer would first have to learn — their lived context in this app
supplies that fluency. Teaching new concepts from a personal-interest domain
was tried and rejected for exactly the missing-prerequisite problem (see
"Scenario flavor", `scenario-flavor.md`); grounding in real source is the education-domain
answer to it. There is no rule against Code Gym framing to relax: the
registry's own safeguards — curated list, one planted flaw in a modified
copy of a method or a new migration modelled on a real one, a scenario that
says so — are the whole guardrail. Entries are appended, never inserted,
because list order is the never-seen drain order, and a method at exactly
`MAX_LINES` is left out since the next edit would evict it.

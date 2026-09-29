# Recognition guides: how to look for each kind of problem

## What this adds

One short generated piece per vocabulary group on the Learn tab, describing
the general process for recognizing that category of issue. It is a lens the
reader carries into any problem. It never defines one concept, since that is
`ConceptReference`'s job, and it never hints at a planted defect.

## Why the group structure needs adjusting

The request assumes each group has its own page and that
"architecture/tradeoff" is a group. Neither is true today:

- **There is no group page.** A group is a `.learn-group-block` on the
  `/learn` index, with a heading, an optional drill button, and its concept
  list. `ConceptGroup` is display-only and has no route of its own.
- **Groups exist only inside the two language buckets.** `ConceptGroup::NAMED`
  holds seven groups (data modeling, domain modeling, silent correctness,
  meta skill, code smells, OO design, module design). Everything else in a
  language bucket falls into `core`, a residual list with no shared identity.
- **Architecture is a bucket, not a group.** The four language-independent
  buckets (architecture, plan review, ambiguity hunt, pseudocode to code)
  render flat: every concept falls in `core`, so the index draws no heading.
- **`TRADEOFF_CONCEPTS` cuts across groups.** It covers most of architecture
  plus `denormalization_tradeoffs` from data modeling. It is a property of a
  concept, not a display group.

## Decisions

**The unit is a "recognition group": the seven named groups plus the four
language-independent buckets.** Eleven keys, derived rather than listed:
`ConceptGroup::NAMED` keys plus `ConceptBucket::LANGUAGE_INDEPENDENT`. For a
language-independent bucket, the bucket is the group. The `core` group of a
language bucket gets no guide, because it has no shared identity to teach.

**Placement: the top of each group block on the index, above its concept
list.** No new page or route. Adding a group page would add a route, a
controller action, and a param check for one block of prose. The block
already is the group's place in Learn. The guide renders inside a native
`<details>` so the index stays scannable. That is a reading convenience, not a
gate: nothing is locked, first-exposure logic is not involved, and every
guide is available to every user. A mixed-language user sees the named
groups' guides twice, once under each language, which is the same text in the
same place relative to the same concepts.

**One guide per group, shared across languages.** The seven named groups hold
the same concepts in both language buckets, so the guide is language-neutral:
its examples are short pseudocode or plain description. Generated once per
group and cached forever, team-wide, like `ConceptReference`.

**Tradeoff framing is derived, not a group.** When a group's concepts include
any of `TRADEOFF_CONCEPTS`, the prompt adds a line naming them and saying the
lens recognizes that a choice is being made and which property of the context
decides it, never which side is right. That reaches architecture and data
modeling without a new group or a branch on the group's key.

**Meta skill is framed as the skill its concepts exercise.**
`META_SKILL_CONCEPTS` are already process concepts, so a separate "how to
recognize" framing would duplicate their references. Its guide is framed as
the one habit the tracked concepts exercise together (reading code carefully
before judging it) and shows how they fit into one pass, leaving each
concept's detail to its own reference. This is a data entry in the guide
registry's framing table, not a conditional.

**Process, never answer, is stated in the prompt and held by the signature.**
The prompt states the distinction outright, with a good and a bad example.
`AiService#generate_recognition_guide(user, group_key)` receives no exercise,
no response, and no user history, so it cannot reach a specific problem
whatever the prompt says. A spec pins the parameter list, as it does for
`#explain_concept_differently`.

## Storage and generation

**Migration: new table `recognition_guides`.** Columns: `group_key` (string,
not null, unique index), `questions`, `contrast`, `misfires` (text), and
timestamps. A separate table rather than rows in `concept_references`: the
constraints rule out changing `ConceptReference`, and a group key stored
there would be picked up by the featured-concept pool, `references_by_key`,
and the ladder queries.

**Reuse, not a new pipeline.** `GenerateRecognitionGuideJob` mirrors
`GenerateConceptReferenceJob`: the same per-key concurrency permit with
`on_conflict: :discard`, the same re-check before calling, the same handling
of a lost race, the same swallowed provider error. The call goes through
`call_and_log` with `purpose: "generate_recognition_guide"`, on the same read
budget as a concept reference, and follows the default model route.

**All three fields are required.** A guide has no partial state worth
rendering, so a missing, blank, or oversized field raises
`InvalidResponseError` and nothing is written. The next backfill retries.

**Trigger: the existing "Write up the rest" backfill.** `LearnController#prepare`
also enqueues a job for every group shown on the page that has no guide yet,
and the prepare box states that count beside the concept count. There is no
per-group on-demand button: eleven rows, written once for the whole team, do
not need one.

## Out of scope

`ConceptReference`, its guide and ladder fields, grading, the judge, and
`ConceptMastery` are unchanged. No generation or review prompt reads a
recognition guide.

# The Learn tab

`/learn` lists every concept in the user's vocabularies —
their language plus the four language-independent buckets, both languages
for a `"mixed"` user — not only ones they've been assigned. It reads
`user.language`, never `#language_for_today`: that method resolves "mixed"
to one concrete language for a single day's generation, and a library's
contents must not change depending on which language tomorrow happens to
be. **This deliberately shows the full explanation before first exposure** —
the opposite of `ConceptReference`'s first-exposure-only auto-expand
everywhere else, which exists because reading an explanation before
attempting a problem replaces effortful retrieval with recognition. A
locked, title-only teaser was offered and declined. This trade is scoped to
this tab; it is not a precedent for loosening exposure gating on the inline
dropdown, the duck's explain mode, or anywhere else that logic runs.
The guide (`ConceptReference::GUIDE_FIELDS`) is produced by the *same*
`#generate_concept_reference` call that writes the inline reference, in one
request — so the two cannot drift apart by construction rather than by
hope. `ConceptReference::REFERENCE_FIELDS` is deliberately not extended (it is read by
`#explain_concept_differently` to build "the reference they've already
read," and widening it would silently change that prompt), and the guide
fields are deliberately outside the required-field check
`#generate_concept_reference` already runs — so a provider that flubs the
guide still leaves a usable inline reference rather than failing a call that
used to succeed. `guide_worked_example` asks for a contrastive PAIR of the
same scenario — same names, same shape, so the difference reads structurally
— and for the mechanism relating them stated outright ("X causes Y") rather
than an association. Which *kind* of contrast is a property of the concept,
not of the vocabulary it arrived in: `ConceptVocabulary::TRADEOFF_CONCEPTS` gets
option A against option B with neither called corrected, everything else gets
failure mode against fix. That constant is **written out rather than derived**
from `ARCHITECTURE_CONCEPTS`: a derivation would hand the tradeoff framing to
every architecture concept added later without anyone deciding it has two
sides, and a reference is cached forever, so a concept framed wrong stays
wrong. A spec holds every architecture concept to a deliberate
classification, so growing that vocabulary fails until someone chooses a side
for the new one. The list is mixed-vocabulary because the shape follows the
concept: `COMPLEXITY_CAUSE_CONCEPTS` sit inside `ARCHITECTURE_CONCEPTS` and
are things to catch, so they are absent, while `denormalization_tradeoffs`
arrives from both language vocabularies and is a real decision. The test is
whether the concept has two defensible sides (at-most-once against
at-least-once), never which group it sits nearest, and deliberately not the
`ANTI_SHAPE_CONCEPTS` axis, which answers a different question. That concept being planted as a flaw on a
schema-review day and taught as a tradeoff here is not a contradiction:
grading one instance and explaining the concept are different jobs. The
inline `code_example` is untouched — it stays terse and single-snippet,
because it serves first exposure. This is the one guide field past the
two-paragraph cap, and it carries a stated bound of its own
(`ConceptReferencePrompt::WORKED_EXAMPLE_BOUND`) rather than none, since an unbounded field drifts
into the essay the guide exists not to be. Three triggers, not one: a
user-initiated backfill for
concepts with no row at all, on-demand regeneration — only when someone
opens that concept's Learn entry — for a legacy row that has a reference but
no guide, and `POST /learn/prepare_ladders`, which rewrites the ungrounded
concepts behind each section's level, its target or else the skill level
(see `difficulty-targets-and-locks.md`). Bulk-rewriting legacy rows would change inline reference
wording nobody asked to change; confining the first two to on-demand accepts
that **an inline reference's wording can change once, for a concept someone
deliberately opens.** `prepare_ladders` is the one scoped exception to that
rule: it rewrites rows on demand, but only for concepts some section of the
user's is pitched at, from a click whose own copy says the wording may change.

**The short lesson.** The same call also writes `lesson`: a definition, an
everyday comparison and where it stops, the common mix-up, two to four
situations, habits each with their catch, a question to carry and a quick
test, all optional and under about `ConceptLesson::WORD_TARGET` words of
prose with no code. `ConceptLesson` owns the keys, the prompt reads them,
and `ConceptLesson.from_provider` holds the reply at the boundary, dropping
an unusable section (a habit without its catch included) rather than
failing the call; the lesson sits outside the required fields like the
guide and ladder. A tradeoff concept's habits are options, each with what
it costs. `PLAIN_LANGUAGE_STANDARD` covers the lesson as well as the guide.
A row with a lesson shows it in place of the explanation, the plain-language
guide and the pitfalls, which it covers in less space; the tagline stays.
The code example and worked example fold under "Code examples", and the
senior lens folds under "How a senior sees it", both closed by default.
A guided row without a lesson offers "Write the short lesson", the same
on-demand rewrite as the guide's, with the same once-for-a-concept-someone-
opens wording change; it rewrites the whole row for the team. Nothing
backfills lessons. The inline reference above a section and the featured
callout are unchanged.

`ConceptReference` has no `user_id` — it's a shared, team-wide cache
keyed on `(concept, language)`, so the first person to run the backfill pays
for everyone and every later teammate pays almost nothing. Roughly $0.02 per
concept, an estimate from before the reference moved to `claude-sonnet-5-5`
at effort `high` (the new effort level changed the cost by an amount nobody
has measured), so a couple of dollars for one user's
whole slice, growing with it — no count is quoted here on purpose, since the
last one went stale the first time a vocabulary grew. The rate is an estimate
from prompt shape rather than a measurement, and both it and the slice's size
are checkable against `ApiUsage` rows under
`purpose: "generate_concept_reference"`. The "seen in your sets" marker
derives from `ConceptExposureIndex#count` (submitted responses only), never
from `ConceptMastery`: tier is kept invisible everywhere by design, and a
marker sourced from it would be exactly the readout the post-hoc difficulty
rating went to lengths to avoid becoming.

**Glossary terms on reference fields.** Every prose field of a concept
reference now renders through `glossary_wrap`: the tagline, explanation,
senior lens, plain-language guide, pitfalls, worked-example prose, the short
lesson, the recognition guide and the hand-written lessons. The wrapping
happens at render time, so the provider's stored text is unchanged and no
reference had to be regenerated. The wrapper never touches code (the inline
`code_example`, a worked example's code and `<code>` spans), because a term
inside code is an identifier, not a word being used. Each field underlines a
term's first use on its own, so a reader who skips to a later field still sees
it marked.

Glossary entries have no per-language scope, so wiring them in would have
shown a wrong definition where a reference uses a word in another sense. The
audit of the existing references found three entries to reword first:
`strict mode` (now covers React's development wrapper as well as
JavaScript's `'use strict'`), `reconciliation` (now covers repairing
differences between two records or systems as well as React's render diff)
and `throttling` (now covers a device slowing its processor as well as a
function limited to one call per interval).

Alternate framings of a concept reference are left plain. They arrive after
the page loads, as plain text the controller returns and the script inserts with
`textContent`. Wrapping a term in one would need the controller to return
server-rendered HTML beside the plain text and the script to switch to
`innerHTML`, which widens the change into the request path and its escaping.
Issue #557 tracks it. A follow-up change (PR B) covers the backfill of terms in
existing references; this change only wires what renders.

The architecture section's inline reference
(`responses/bodies/_architecture.html.erb`, built from the exercise JSON) stays
plain too, because the production audit never covered that text. Issue #561
covers auditing and wrapping it.

# The weekly featured concept

each user gets one concept a week, chosen
from concepts they have met — `FeaturedConcept.for(user)`, read at the top
of `/learn` and as a small callout on the dashboard ("This week's concept").
A week rather than a day, so someone who opens the app only a few times has
time to read the whole guide. It replaced a single team-wide pick, which
could only draw from the four language-independent buckets, because a
global pick had to be reachable from every teammate's slice.

**The pick rule is `FeaturedConceptPick`, pure over plain values.** The
candidates are the concepts in the user's slice (`ConceptBucket.slice_for`
and each bucket's vocabulary) that at least one submitted set has shown,
counted by `User#concept_exposure_count`, the same count as Learn's "in your
sets" marker. `RungLedger` sorts them the way the Progress page does: a
concept with `developing_toward` is preferred; next, one met with no ledger
evidence yet (only skipped, eased or unreviewed sections); a held concept
with nothing above it in progress is never featured. Last week's concept is
dropped whenever any other candidate exists. Within the preferred group a
concept never featured for this user comes first, then the one featured
longest ago, ties in slice order, the same "unseen outranks stale" rule
`SectionRotation` applies to kinds. No candidate means no row and no
callout: a new account, or one that holds everything it has met, sees
nothing until it meets something new. There is no team-wide fallback.

**Tier stays invisible.** The pick reads `RungLedger` and the exposure
index, both built from submitted responses, and never `ConceptMastery`,
drills or pause state. The ledger's standings are already on the Progress
page, so featuring a developing concept says nothing that page does not.

**Stored, so it holds for the week.** `featured_concepts` keeps one row per
user and `week_of`, the Monday of the week in the user's own zone, which
`ApplicationController#use_time_zone` sets around every action. The first
page load of a week computes and stores the pick, and every load after reads
it, so new work during the week cannot move it. A pick computed on every
load was rejected: it would build `RungLedger`, which reads every submitted
response and its exercise, twice on each dashboard and Learn load, and could
avoid only last week's concept rather than rotate. The stored rows are also
the rotation's history. Accepted cost: a user with met concepts but none
eligible stores nothing, so each of their dashboard and Learn loads builds
the ledger again until something qualifies.

**A stored pick is checked on every read** (`FeaturedConcept#still_met_by?`).
When a language change moves its bucket out of the slice, or its concept
leaves the vocabulary, `LearnController#show` would 404 on the link; and
when Start over destroys a submitted day whose review failed, the only set
that showed the concept can go with it, leaving a callout that says "seen
in 0 of your sets". Either way the row is re-picked in place for the rest
of the week, or removed when nothing qualifies.

**The race guard is the unique index on (user_id, week_of).** Two first
visits landing together both find no row and both insert; the loser's insert
violates the index, and `.claim` rescues `RecordNotUnique` by re-reading the
winner's row. The insert sits in a SAVEPOINT (`requires_new: true`) for the
same reason `PushSubscription.upsert` and `User#carry_forward` do: without
one it joins a caller's open transaction and the violation aborts it, so the
recovery read raises `PG::InFailedSqlTransaction`. Transactional specs
cannot surface this, since Rails opens its test wrapper non-joinable, so the
spec that pins it opens an ordinary caller transaction explicitly.

**Selects and displays only — it never generates.** No provider call and no
`ApiUsage` row (a spec pins that). Shared `ConceptReference` rows are read,
never written. A featured concept whose guide was never written, or with no
reference row at all, still links to the ordinary `LearnController#show`
page, which offers the on-demand "Write this up" control.

**What the callout shows.** The concept's name, its bucket and "seen in N
of your sets" from `User#concept_exposure_count`. The reference's tagline
can describe what a section asks the engineer to find, so
`FeaturedConceptHelper#featured_tagline_shown?` holds it back on the
dashboard until the day is submitted; the Learn page, and a dashboard with
no set today, always show it.

**Every section carrying it is marked.** `FeaturedConceptHelper#featured_concept`
reads the pick once per request, and the section wrapper
(`responses/_section`) renders `responses/_featured_marker` beside the
section's label whenever `FeaturedConcept#marks?` says so: on the answer
form before anything is answered, where it stays visible while the section
is folded, on the submitted dashboard, and on every History entry that
carries the concept, older weeks included. `#marks?` compares the concept
and its bucket, since data-modeling and meta-skill concepts sit in both
language vocabularies, and it is the one place a later rule, such as
marking less once a concept is held at the user's rung, would go. Marking
a section before it is answered was a deliberate choice: a met concept's
reference already names it in its closed disclosure's title, and the
engineer still has to find and explain it.

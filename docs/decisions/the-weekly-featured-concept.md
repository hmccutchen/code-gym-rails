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
counted by `ConceptExposureIndex#count`, the same count as Learn's "in your
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
call of a week, a page load or the morning's generation, computes and stores
the pick, and every call after reads it, so new work during the week cannot move it. A pick computed on every
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

**Selects and displays — it never calls a provider.** No provider call and no
`ApiUsage` row (a spec pins that). Generation reads the pick for one reason,
which the section below explains. Shared `ConceptReference` rows are read,
never written. A featured concept whose guide was never written, or with no
reference row at all, still links to the ordinary `LearnController#show`
page, which offers the on-demand "Write this up" control.

**What the callout shows.** The concept's name, its bucket and "seen in N
of your sets" from `ConceptExposureIndex#count`. The reference's tagline
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

## Generation leaves it out of sections that hide their concept (#687)

Three kinds hide their concept until the day is submitted: `code_review` on a
bug-hunt day, `plan_review` and `ambiguity_hunt`. If the week's concept was
also one of theirs, the dashboard left the callout off that day, and the
callout was back on the next day, so a user could guess what the hidden section
held. The first fix hid the callout on the colliding day. This one removes the
cause, so the callout never has to disappear: generation does not give the
week's concept to a section that hides its concept.

**How.** `ExerciseDraft.call` asks `FeaturedConcept.for(user)` before it plans
and passes its concept name (a string, so the pure plan holds no record) to
`DailyPlan.for(featured_concept:)`, which carries it on
`DailyPlan::Result#featured_concept` to every place that already carries the bug-hunt
trap: the prompt's vocabulary line, the difficulty ladders, `DayHosts` and the
diagnostics. Three rules use it:

- `BugHuntGotchas.pick` skips every entry whose concept is the featured one.
  A spec holds that each language's list teaches at least two concepts, so a
  skip can never leave nothing to pick.
- `ConceptVocabulary.selectable_for_section(..., featured_concept:)` leaves it out of a
  kind whose `.concept_hidden_in_plan?(mode:)` is true. A kind answers for itself
  (`plan_review` and `ambiguity_hunt` always, `code_review` on a bug-hunt day),
  so no shared code branches on kind. A spec holds that every hiding kind still
  has a concept to offer whichever one is featured, at every rung.
- A kind that shows its concept keeps it, so the week's concept can still be
  practiced where it is allowed.

Both rules match the concept's name and ignore the bucket, because the guard
they replace compares names (`concepts_withheld_before_submission`). A mixed-
language user whose week features `array_mutation_pitfalls` under Ruby would
otherwise still get a JavaScript bug hunt on it, and the callout would vanish.
Only the Ruby and JavaScript bug-hunt lists share names (three of them);
`plan_review` and `ambiguity_hunt` names appear in no other list, so the rule
costs nothing there. `FeaturedConcept#marks?` still compares the bucket, since
it marks sections and not hides them.

**Decisions on the review of this change.**

- The mode roll, the trap and the featured exclusion are not bundled into one
  planning method now. Tracked in #692 with the other generation scripts.
- A database error (`ActiveRecord::ActiveRecordError`) in the featured lookup
  is logged with the user id and the day plans with no featured concept. Other
  errors still raise.
- A set generated across the Sunday-to-Monday turn can look up the old week's
  concept. The callout guards already compare names and cover that window, so
  nothing extra is done for it.
- The hosting cost below is accepted.

**What it costs.** `DayHosts` reads those vocabularies, so a featured
`plan_review` or `ambiguity_hunt` concept has no host that week. These kinds
are the only ones that tag their buckets, so reinforcement, a drill and a
retention check on that concept are not planned onto the fourth section, and a
due check lands in `waiting_checks` as `no_host` until the week turns over.
The fourth track used to pick its concepts without asking `DayHosts`; it asks
now, and a spec pins the effect. The main track is unaffected, because no
hiding kind hosts a main-track bucket, so `annotate_retention_concept` needs no
change either. A day with no featured concept plans and renders exactly as
before: every prompt snapshot is unchanged.

**Which week.** The pick is for the week of `Date.current` in the user's zone,
which the jobs set with `Time.use_zone(user.effective_time_zone)`, the same day
the set is dated and the same week the dashboard asks about. A set generated
on a Monday uses Monday's week. A generation that starts just before local
midnight on Sunday and writes after it is planned against the old week, because
`GenerateDailyExercisesJob#write_set` reads the date again when it saves. The
window is one generation long, once a week, and only matters if the new week's
pick is also a hidden concept, so the guards cover it rather than the job
carrying a target date through the draft. A paused user's held set that
`User#carry_held_set_forward!` moves into a new week was generated under the
old week's pick and is not regenerated, so the new week's concept can be one of
its hidden concepts.

**The guards stay.** `featured_callout_shown?` and Learn's
`featured_shown_beside_todays_set?` still leave the callout and the block off
for the cases generation does not cover: the held set and the midnight window
above, a provider that tags the concept anyway (as the bug-hunt page check
does), and a mid-week re-pick. The last happens when the stored pick stops
being met (the user changes language, or Start over removes its only
exposure): `FeaturedConcept.for` then replaces or removes the row, and a set
already generated that week was planned against the old pick. A first week with
nothing met yet is not one of them: exposures count only submitted responses,
so a pick made later cannot match a set that is still unsubmitted.

**Why generation may read it.** `FeaturedConcept.for` reads exposures and the
`RungLedger`, which come from reviewed answers. It reads no track, suggestion
or trial state and never `ConceptMastery`, so `level_suggestion_isolation_spec`
and `trial_isolation_spec` do not cover it. It writes the row the dashboard
would have written on the first visit of the week, and it replaces or removes a
stale row exactly as the dashboard does. The prompt never names the concept: the pick only shortens the closed
list a hiding kind may choose from.

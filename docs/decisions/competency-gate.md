# Automatic workload

`CompetencyGate` owns Automatic count, grade qualification, completion,
overload and recovery in one pure, forward fold. `DaySize` gives a fixed
setting precedence. Fixed counts 1–4 return before any workload query, skip
coverage and produce no forecast; their diagnostic gate is nil.

## Independent kind proof

Automatic starts at `CompetencyGate::FLOOR` (`DailyKinds::COUNT`, two).
Two to three requires one qualifying kind; three to four requires two.
Each kind needs five normal assessed attempts on distinct exercise dates at
its current evidence rung, at least four graded solid/strong. Rotated kinds
qualify independently; there is no pooled threshold, daily-pair restriction
or eight-of-ten route. Grades use `ReviewedSectionResults.at_or_above?`,
without requiring a favourable self-rating on each successful grade.

Each kind also retains its latest three known nominal-rung effort
observations. Normal or eased too-hard feedback supplies `hard`; normal
right-level/too-easy supplies `comfortable`. Eased comfort and invalid or
missing ratings supply no observation and cannot displace hard feedback.
Two hard observations block that kind from supplying growth, even with
fewer than three observations. They neither shrink earned size nor
disqualify another kind. No observation is not proof of comfort.

Eased attempts never occupy the five normal-grade positions. Five earlier
normal successes followed by two eased-hard attempts preserve the grades
but block qualification. With `comfortable, hard, hard`, one normal comfort
still leaves two hard observations; the second clears the safeguard.
Arbitrarily many eased comforts cannot do so. This bounded three-valued
rule needs no latch or separate reset threshold: easier comfort does not
establish comfort at the nominal rung. Level suggestions retain their
separate, uneased-only policy and unchanged constants.

## Real completion and safety

Growth also requires two qualified full-core completions at the replay's
current count. Each size change restarts that proof. Completion alone never
grows workload. One actual core skip interrupts positive proof and holds
growth; two consecutive qualified skip sets reduce one, floor two.
Unknown, pending, unsubmitted and supplementary-only days are absent.

Assignment is validated integer `plan_notes["size"]`, the base count before
coverage. Delivered and answered counts come from active adaptation keys,
never JSON key counts. A full day supplies proof when its assignment is at
least the replay count and all that assigned volume was actually delivered
as core work and completed. A legacy unknown assignment compares actual
core volume against the replay count. No drop or supplementary credit exists.

A smaller assignment is neutral. Completing a larger real assignment can
prove capacity for a smaller replayed count, but its skips cannot diagnose
inability to finish the smaller count. An assigned-three/core-two shortfall
supplies no positive proof even at replay count two. A known full short
matching (or legacy unknown) assignment interrupts the skip run, without
adding positive proof. An actual skip of a remaining core section still
counts when a provider drop made the day shorter. Completed real coverage
or kept extra core work counts; a dropped coverage addition does not.

Broad overload retains the latest three sets containing at least one valid
strict core self-rating since the last safety reduction. At least two
different kinds must each be too hard twice in those sets. Two sets can
already trigger; one struggling kind cannot. Eased ratings count here
because this measures the workload actually done. A partial review can
supply its assessed ratings immediately. Unrated sets occupy no position.

A skip and overload trigger on the same day reduce once; diagnostics name
both causes, with `brake` primary. A reduction clears capacity and overload
runs and starts recovery, retaining every kind's grade and effort windows.
At the floor the trigger is still consumed and recovery begins, but no
smaller-set message appears. Old triggering ratings cannot cause a second
reduction. Recovery requires two full sufficient-volume sets with all core
self-ratings known and at most one too-hard kind each. Two hard kinds or an
actual matching-count skip reset recovery. Missing ratings and insufficient
volume neither advance nor interrupt it. The trigger day is not a recovery
day. Growth may occur on the second recovery day if normal proof still holds.

`Plan#safety_hold` persists across ordinary held transitions, through
recovery and after a single actual skip until two full proofs. The existing
additive `CoverageException` remains in this release, but
`DaySize::Decision#brake?` reads this hold so coverage cannot bypass it.
Protected-practice scheduling and removing additive coverage are separate
approved future work, not implemented here.

## Eligibility and replay

`DailyResponse#assessed_sections` remains the basic authority: submitted,
substantively answered active work with a valid grade. The exercise owns
`adaptation_section_keys`, applying the kind's `adaptation_evidence?`
facet; response delegates and intersects assessment with it. Identifiable
bug hunts decline this facet. Other weekend core work still counts.

Normal grades, kind effort and broad overload require current
`ReviewedSectionResults::RUBRIC_VERSION` and a valid `pitched_at`.
Completion and recovery instead use basic assessed core work without those
stamps. Recovery's ratings come from that basic projection, never the strict
result list. Thus an unversioned full day can restore comfortable recovery
but cannot supply strict grade proof or enter the overload window. The
strict rating restriction is workload policy, not basic assessment policy.

`completion_evidence?(sections:)` requires at least one assessed answer in
the selected active subset and every answered selected sibling assessed.
Skipped sections owe no walkthrough; all-core-skipped/bug-only work is not
a zero-completion event. The default method and UI completeness retain
their all-active contracts.

`Evidence` owns an internally user-scoped submitted/reviewed relation,
preloaded in ascending date/id batches of 100. It applies the exclusive
`before:` to both projections. It cannot globally filter on rubric because
valid unversioned completion matters. Strict-only selectors retain the
shared coarse SQL stamp prefilter and final Ruby checks.

Every eligible historical day replays, with no age/candidate cap or #264
checkpoint. Batches bound eager materialization, not total work. The fold's
bounded rule windows do not bound historical input. Late reviews update the
original response event and replay its final merged evidence once.
`Day#evidence?` owns empty classification in both loader and fold; empty
events preserve the entire Plan exactly. Evidence-bearing dates must
strictly increase; duplicate dates raise rather than supplying extra proof.
Appending days preserves earlier outputs, while correcting earlier evidence
can legitimately change later decisions.

## Difficulty chronology

New generation captures one all-kind effective-rung map and the profile's
baseline level before the provider call. Initial/retry instructions, the
multi-file schema, requested diagnostics, ingest, ladders and the judge reuse
those captured inputs. Optional prompt-map/baseline keywords are a narrow
interface extension to preserve this immutable rendering contract; direct
callers retain their defaults and ordinary text. `JudgedGeneration` passes the map through
`DailyPlan::Result#notes(kind_rungs:)`; generation/regeneration persist it
with the set. Held sets keep it. The plan reads no difficulty, track,
suggestion or level-change state.

An evidence-bearing day reconciles its valid server snapshot, including
kinds absent from its results. A changed rung clears only that kind's grade
and effort windows, not count or other kinds. Returning to an old rung does
not resurrect its old window. A section stamp disagreeing with explicit
context cannot enter those windows or override the context; its basic
completion and strict workload ratings remain independent.

Legacy missing maps fall back per kind to observed result rungs. Unknown
registry keys and invalid rung values supply no context. Today's settings
never relabel old work. An already delivered exercise retains its assigned
difficulty after a setting edit; the next generated period records the
change. Historical setting changes during absent kinds cannot be recovered.

## Presentation, rollout and limitations

`SizeForecast` includes today's evidence using `exercise.date.next_day`.
Its baseline is the greater of valid base assignment and delivered core
volume, excluding supplementary work and undelivered coverage. Actual
completion or overload reductions use: “Your next automatic set will have
%{count} sections to leave more room for practice.” The larger line is
unchanged. No hold badge, mastery tier or browser rule is added.

`[set_size]` reports count, reason, setting and the gate's safety hold,
per-kind normal dates/successes, effort observations/safeguard, capacity,
recovery, overload sets, hard tallies, causes and transition dates.
It carries bounded facts, never answers, provider prose or keys.

Full historical replay can change future sizes in either direction and
historical bug-hunt exclusion can change pending suggestions. Stored sets,
grades and applied levels are never rewritten. Old materialized mastery
effects from bug-only cooldowns are not rebuilt; future countdowns require
the first assessed core transition. No new use of the reserved #726 schema
columns occurs. Mixed-version countdown histories remain indistinguishable.

Existing generation rating guidance can simplify work without the reduced
concept stamp. This release cannot identify unstamped historical easing.
#714 must own explicit support/easing and return-to-normal policy; there is
no new retention policy, track preview, graduation or #718 definition here.

The seeded fixture is an open-loop preserved-input replay of eight named
50-day result draws, enriching
each with deterministic dates, assigned base volume and delivered/answered
core keys. Its recorded counts intentionally replace the old pooled and
mean/stretch rules; the implementation report separates count changes,
reason-only changes and evidence-schema-only differences. Assignments come
from the preserved random walk, not the preceding replay output: 139 match
the pre-event replay count, 148 are smaller and 113 larger, across 400 events.
A separate eleven-event feedback spec assigns and delivers each previous
gate count, covering growth, skips, reduction and regrowth. Neither is a
production impact or latency measurement.

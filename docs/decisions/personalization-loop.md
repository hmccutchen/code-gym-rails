# Personalization loop

`DailyResponse#assessed_sections` owns basic performance eligibility: a
submitted response, an answered active section and a grade from
`ConceptMastery::AI_RATING_RANK`. Valid partial reviews contribute immediately.
Drafts, pending or failed answers, off-list grades and skipped walkthroughs
are absent performance evidence; they never imply poor performance.

`User#recent_performance` returns up to `PERFORMANCE_HISTORY_LIMIT` (the
existing ten) qualifying response days, newest first. Each has a date,
assessed adaptation sections with valid grades and optional concept/self-rating,
and optional core completion. The kind-owned adaptation facet excludes
supplementary bug hunts before the ten-day limit. Completion exists only
when every answered active core section is assessed and at least one core
answer was assessed. Skipped sections require
no walkthrough. Unknown completion carries neither a count nor skip labels.
Missing or malformed self-ratings are absent, including historical skipped
ratings. Concept names pass the existing bucket vocabulary.

`AdaptationHistory.recent` applies basic and consumer-specific eligibility
before taking a count limit. It traverses submitted responses by descending
date/id with preloaded exercises in cursor batches, without a candidate cap
or new age cutoff. Its own operational `BATCH_SIZE` bounds eager loading of
responses and exercises, independently of the gate loader's tuning. The
relation stays user-scoped and submitted; `.reviewed` cheaply excludes null
and empty reviews but is not assessment proof. Strict callers can request
the shared current-rubric SQL prefilter; general history still accepts valid
unversioned grades. Ruby eligibility and consumer projections remain
authoritative after either coarse filter. A late review uses the original response date.
Performance windows remain response-day windows across kinds; eligible
newer days can still displace older evidence. Each generation captures its
projections once and reuses them on retries.

`User#recent_delivered_content` separately projects dates and active section
keys, concepts and scenarios from the latest ten delivered sets, including
today during regeneration. It needs no response, omits dropped sections and
never serializes answer keys or whole problem sets. The prompt marks these
as repetition-only notes, with no inference about difficulty, struggle,
success or completion. Diagnostics log only the sanitized performance
projection. `ConceptExposureIndex` retains its existing submitted-day
exposure convention, including skipped and pending sections.

Workload's single `CompetencyGate` fold projects basic core completion
independently of strict current-rubric/rung results, retaining full eligible
history (`competency-gate.md`). Rotation uses delivered/scheduled
`ExerciseHistoryEntry` values with no answered field. The independent
mean/stretch completion ceiling and drop credits are retired. Unknown days
are absent; actual core skips and broad overload have distinct safety
triggers. Retention and drill policy remain unchanged.

The locked review merge counts a session only on its first assessed
adaptation-answer transition. A bug-only batch cannot spend a paused
concept's cooldown, and a later first core batch still counts once.
The model also guards countdown against successful keys outside that
subset. Enrolled users reconcile least-favourable daily contributions at
their original position with captured clocks, preserving subsequent
sessions, reviews, skips and manual commands. Untouched users retain batch
application while C's initiation default is false.
`daily-mastery-reconciliation.md` specifies the durable receipt, legacy
prefix, reserved drill slots and separate activation gate. Historical materialized
bug-only countdown effects are not rebuilt, and mixed-version deployments
cannot identify an old decrement from stored grades alone.

**Skipped retention checks defer without changing knowledge.** When a
submitted, successfully reviewed skipped section tags a vocabulary-valid
concept whose retention check was due on the response's date, review moves
its next check one existing interval beyond the user's local review date
(never before the work date). The interval, tier, streak, last rating and
mastery timestamp do not change. This releases a fourth slot that the same
overdue concept could otherwise hold indefinitely. It also postpones a
genuinely useful check when someone skips it; that is the accepted cost.
A concept answered anywhere on that response is excluded, even if that
section's review is still pending. Only successful sections in the current
batch qualify. The transaction locks the matching mastery rows, and the new
due date is beyond the work date. In reconciliation mode a receipt also
deduplicates the attempted skip per response/concept/bucket, even if a later
correction changes whether the original attempt was applicable.

No assignment metadata is stored: `DailyPlan` offers concepts and ingest
stores the provider's actual tags, not which offers it honored. The rule
therefore applies to a due concept actually shown and reviewed, whether
explicitly requested as retention or incidentally repeated. It cannot
infer an unhonored offer and never reschedules unrepresented concepts.
No backfill repairs mastery changed by historical skips.

**Reinforcement is offered only where today can host it.** `DailyPlan` passes
`User#concepts_needing_reinforcement` a `hostable:` test built from the day's
non-fourth kinds and `code_review` mode through `DayHosts`, and the method
applies it to drilled concepts and history entries alike. The prompt demands
every reinforcement concept it lists, so an entry no planned section can tag
would otherwise take a slot nothing can fill: on a two-section
`schema_review` day, for example, code review takes only data-modeling
concepts and design comparison never takes meta-skill ones. A history entry
left out is offered again on a later day that can host it, while it is still
in recent history.

Automatic reinforcement takes the newest qualifying response days after
assessed-section, mastery-kind, vocabulary, bucket and hosting filters.
Each concept/bucket resolves on its newest eligible occurrence, before
co-favourability or paused-tier suppression; a pending sibling cannot hide
older evidence. Mastery tiers load in one batch. Explicit drills remain first
and independent of those history windows.

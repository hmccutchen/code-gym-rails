# Drills

a user can mark one concept, or a whole Learn display group, as
drilled from the Learn tab (`ConceptDrills`, `ConceptDrillsController`). A
drilled concept leads `User#concepts_needing_reinforcement`, and since
`DailyPlan` truncates that list to today's hosts and order is priority, that
is the entire boost: no second weighting mechanism, and `SectionRotation`,
weights and `KindDifficulty` are untouched. It is the third axis of user
control beside those two — which kind, how hard, and now which concept — and
it is kept as separate from them as they are from each other. The prompt
renders the entry as `concept (tier, drilled)` and one line says `drilled`
never eases or raises anything; the locked-kind line already overrides
easing "whichever concept they carry", so a drilled concept in a locked
section composes with no special case.

**Storage is two nullable columns on `ConceptMastery`** (`drilled_at`,
`drill_group`), since that is already the one row per (user, concept,
bucket); drilling a never-met concept creates the row in its untouched
state, and every other reader ignores a row with no evidence. A group drill
is one row per concept labelled with the group, not a group flag: clearing
stays per concept, and the label is what lets the cap count a half-cleared
group as one drill. Drilled concepts beyond today's capacity rotate
never-seen first, then least recently seen, read from the exposure index —
which drill was offered is never recorded, like every other offer.

**A drill clears on the existing mastery signal and nothing else.** The
same co-favorable rating that sets a row to standard in
`ConceptMastery.evaluate_concept!` — self-rating "right level" or "too easy"
AND AI "solid" or "strong", on one occurrence — also clears the drill. That
can be a single day, and no drill-specific count exists on purpose: the
retention schedule takes over from there exactly as it does for any
mastered concept.

**The cap is `ConceptDrills::MAX_CONCURRENT`, counted in drills where a
group is one.** It is a stated 2, kept below the non-fourth hosts on the
fullest day, where every drill but a fourth-bucket one competes, so
single-concept drills always leave a host for evidence-driven
reinforcement or an overdue retention check. It is not derived from
`ExerciseSection.slots`: the second fixed slot raised that count without
making a day longer, and `DailyPlan.share_hosts` already keeps a host for
evidence when drills outnumber the hosts. A fourth-bucket drill counts
against the same cap while occupying only the fourth: the cap bounds how
many gaps are worked at once, not how many hosts they take. This paragraph
is the reasoning, a spec pins the value, and
`ConceptDrills#can_start?` / `#can_start_group?` are the one statement of
what it allows, read by the start methods and by the pages that offer the
button.

**Drills are scoped to what today can tag, and stand a retention check
down.** `DailyPlan` hands `concepts_needing_reinforcement` a `hostable:`
test built from the day's non-fourth kinds and `code_review` mode through
`DayHosts`, which reads `ConceptVocabulary.selectable_for_section`, the same authority
`AiService#can_host?` reads for retention checks — so a drilled
architecture concept is offered only on an architecture day and a drilled
data-modeling concept only when some section can tag it. A history entry
ages out, but a drill persists until mastered and would otherwise claim a
slot every day no section could carry it. When evidence-driven
reinforcement is waiting, drills keep all but one host
(`DailyPlan.share_hosts`), so a group drill larger than the day cannot
starve the concept the ratings flagged; a one-host day still goes to the
drill. A drilled concept whose retention
check is due is listed once, as reinforcement, and its overdue check
neither reserves nor takes a slot: the check would have asked for the same
concept under a second instruction in the same prompt. The same host test filters
history-derived reinforcement too, as `personalization-loop.md` records
("Reinforcement is offered only where today can host it").

**`ConceptDrills.for` reads only the user's current slice**
(`ConceptBucket.slice_for`, shared with the Learn tab), so a drill stranded
by a language change or a renamed concept neither counts against the cap
nor sits unreachable behind a stop control the slice would 404. A concept
whose group is drilled joins that group when drilled alone, a group absorbs
lone drills of its own members, and a member stops as its group, so one gap
is never two entries and a group is never half-labelled.

**Drilling a paused concept from its own page ends the pause**, through
the same exit an expired cooldown takes (`ConceptMastery#end_pause`), and
that page says so before the click — the one deliberate look at tier state
on the Learn tab, since a silent override would be worse than naming it. A
group drill states no such thing, so it leaves a paused member paused and
picks it up when the cooldown ends. A concept that reaches the paused tier
while drilled keeps its drill but waits out the cooldown; `concepts_needing_reinforcement` skips paused rows whether
drilled or not, and the page says it is waiting.

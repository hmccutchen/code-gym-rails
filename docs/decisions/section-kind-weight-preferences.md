# Section kind weight preferences

a user's stated multiplier
(`KindPreferences::MULTIPLIERS`, x0.25..x4, default x1) leans
`SectionRotation#pick_kind`'s weighted roll and nothing else — it is applied
only inside the branch the starvation guarantee returns before reaching, so
a low weight can shrink a kind's odds but can never starve it. Exclusion is a
separate, stronger action: it removes a kind from the pool everywhere the
pool is read, including `slot_staleness`, and it is the only preference that
can keep a starved kind out. Weights deliberately do not touch
`slot_staleness` — that computation is a `max` over the pool deciding which
*slot* wins a scarce spot, and a kind a weight could never actually place
there would let a slot win on strength it can't back up; only exclusion,
which really can remove a kind from contention, is allowed to move that max.
Validation (`SectionKindSettings`) refuses an exclusion that would empty a slot, so
`SectionRotation` never has to render a slot with nothing eligible in it.
Storage is sparse — a kind left at the default multiplier stores no key at
all — so a user who has never touched either control is byte-identical to
pre-feature behavior.

**Excluding kinds can make their slot fill less often.** `slot_staleness`
uses the stalest eligible kind in a slot. A smaller pool can be refreshed
more often, leaving that slot less stale than competing slots on days
without room for all of them. The effect depends on the daily kinds,
exclusions, recent history and number of optional places; it is not a fixed
percentage. A slot's frequency also differs from the frequency of each
kind within it. Setup describes this tradeoff without numerical promises.
This describes ordinary `SectionRotation`; `DailyPlan` can separately add a
coverage section.

Excluded kinds must stay out of slot ranking as well as selection. Otherwise
a kind that cannot be scheduled can keep its slot at the staleness cap and
give that slot priority unsupported by its eligible kinds. Ranking slots by
when the slot itself last filled would be a different planning policy,
outside the weight preference's scope.

Any future frequency measurement should record its date, layout, settings
and method. It describes that measured case, not a lasting cadence guarantee.

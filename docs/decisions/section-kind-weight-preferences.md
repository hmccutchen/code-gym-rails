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
User validation refuses an exclusion that would empty a slot, so
`SectionRotation` never has to render a slot with nothing eligible in it.
Storage is sparse — a kind left at the default multiplier stores no key at
all — so a user who has never touched either control is byte-identical to
pre-feature behavior.

**Accepted consequence: excluding kinds also makes that slot fill less
often**, not merely fill differently. `slot_staleness` is a `max` over the
eligible pool, so a narrowed pool keeps the surviving kind scheduled — and
therefore fresh — which lowers the slot's staleness and loses it ranking
contests on days too short to fill every slot. Excluding two of the three
fourth kinds takes that slot from roughly 81% of 3-section days to 50%, and
from 36% of 2-section days to 14%. The exclusion copy says so outright rather
than leaving it to be discovered. Ranking the slot over the *full* pool
instead was considered and is worse: an excluded kind is never scheduled, so
its staleness grows without bound and the slot would monopolize every scarce
spot forever. Decoupling slot frequency from pool size needs slots ranked by
when the slot itself last filled, which is a change to how every day is
shaped and not something this preference should drag in behind it.

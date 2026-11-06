# TrackChange

A pure preview over `KindDifficulty`. The same explicit targets and locks
are used on both sides; only the baseline changes. `changed` lists registered
kinds with different effective rungs, and `retained` lists explicit targets
with their lock status. Neither list changes the supplied settings.

An equal target remains explicit even when it matches the old or new
baseline. `already_saved?` distinguishes an unchanged baseline from an
all-targeted account changing its baseline without moving a kind.

The object does not validate HTTP confirmation or write anything.
`ProfileUpdate` owns the locked write; `LevelChange` compares actual saved
rungs for cutoffs and events. See `docs/decisions/tracks.md`.

# The Progress page shows the rung each concept is held at

It reads the stamps in
`each-section-records-the-rung-it-was-pitched-at.md`: `/progress`, a nav entry between Learn and History, in the buckets and
groups Learn uses (`ConceptBucket.slice_for`, `ConceptGroup.grouped`),
nothing regrouped; a single-group bucket shows one disclosure under the
bucket's name, as Learn shows it flat. `RungLedger` is the one rule:
for a concept, bucket and rung, the most recent day that answered a
reviewed, un-eased section pitched at that rung; held when both ratings
were favourable on every such section that day, the co-favourable and
least-favourable-section rules `record_review!` applies, with a review that
stored no rating counted as no signal as there; the standing
is the highest held rung, which covers the rungs below, and a later poor
attempt releases a rung, so the page describes now. Between rungs a
concept is "developing toward" the next one up
(`RungLedger#developing_toward`): once any rung above the held one has an
attempt that did not hold, or any attempt at all when none is held, the
page shows it one step past the held rung, so the ladder reads not yet,
developing toward junior, junior, developing toward mid-level, mid-level,
developing toward senior, and so on. An
attempt two rungs up still reads as developing toward the next one, since
the rung between is not held either. Its bar segment is striped in the
target rung's colour, its dot half filled, and the legend states it once.
This replaced "not yet" for a concept attempted but never held, which the
legend had described as having no reviewed answer. It is pure over the
response objects it is given and compares nothing to today, so time alone
changes nothing, which a spec pins. A concept with no attempt is "not yet",
or "not offered" when every kind that could show it is excluded, worded
as the user's choice with a link to Setup; hosts come from `ConceptHosts`,
the derivation `LadderCoverage` now reads too. Deliberately absent: any
total across a bucket or the page (group bars only), the streak, tier
state — the page shows rungs, not `ConceptMastery`, so the app's rule that
tier stays invisible still holds — drills, and any control beyond
navigation. No locked-kind marker, and no claim that a rung is exact: the
ledger records what was asked, `eased` covers the one easing the server
decides, and the page's own note says a rating adjustment can still nudge
an unlocked section and only a lock makes a rung exact.

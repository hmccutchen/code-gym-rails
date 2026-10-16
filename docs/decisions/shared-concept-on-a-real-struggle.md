# Shared concept on a real struggle

when reinforcement holds a
reduced-tier concept, drilled or not, that every fixed kind can tag,
`SharedConcept.pick` places the first such entry in both `code_review` and
`design_comparison` (`DailyPlan::Result#shared_concept`). Reduced takes
three stagnant reviews in a row, so it marks persistent difficulty; paused
concepts never reach the list. Hosting goes through `DayHosts`, which reads
the mode-aware `code_review` vocabulary and `design_comparison`'s strictest
no-rung list, since `DailyPlan` never reads `KindDifficulty`; the cost is
that a tradeoff concept is never shared. The pairing only fills hosts
nothing else needed: reinforcement and retention are fitted first, against
the final slot count, and the concept is shared only when every other
reinforcement entry and due check can still take a distinct remaining kind
able to tag it (`SharedConcept.placeable?`). A free section count alone
is not enough: with architecture as the only optional kind, two Ruby
concepts have the fixed sections as their only hosts, and pairing one
would leave the other nowhere. So it never evicts a drill or another
reinforcement entry, and when an overdue retention check takes the free
host the day is planned exactly as it would be without pairing. This
replaces the design note's "cut the remaining reinforcement by one more",
which let a reduced concept push a drill out.

**Advisory, like all reinforcement.** One line folded onto the end of the
drilled-concepts bullet (`AiService#shared_concept_guidance`) names it for
every fixed section, listing their keys from `ExerciseSection.fixed` and
stating no count, so a day without
one renders byte for byte as before; `DesignComparison.generation_guidance`
already carries the kind's own rule (two working designs, a scenario
different from the code review). A retry asks for one section and never
carries the line. It is not enforced through `fixed_concepts:`, which
would fail the whole draft when the model misplaced it. Each generation
logs `[shared_concept] user=… concept=… reason=reduced_tier
honored=true|false`, where honored means both delivered fixed sections
took it (`ExerciseSection.fixed_sections_share?`). Within one review
`record_review!` evaluates the concept once, on the least favourable
rating, so the second angle makes leaving Reduced stricter and never adds
weight.

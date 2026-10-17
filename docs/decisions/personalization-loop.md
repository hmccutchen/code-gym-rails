# Personalization loop

`user.recent_performance(limit: 10)` returns the last 10 sessions with dates, sections answered, ratings, and concept tags. This is embedded verbatim in the generation prompt so each day's exercises adjust to the user's trajectory. A skipped section's AI grade is not evidence of skill: `recent_performance`'s `ai_ratings`, `ConceptMastery.record_review!` and `User#concepts_needing_reinforcement` read `DailyResponse#answered_concept_tags`, and the prompt labels a skipped section `ai: skipped`. `recent_performance`'s `concepts:` and `User#concept_exposure_index` keep the full set because a skipped section was still shown. `self_ratings` returns the stored map unchanged for historical compatibility; new submissions use the finalization rule in `one-finish-action.md`.

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
due date is beyond the work date, so retries and later skipped duplicate
batches cannot defer the same day's check again.

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

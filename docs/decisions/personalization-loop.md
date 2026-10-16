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

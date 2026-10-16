# One reviewed-response invariant

once `DailyResponse#reviewed?` is true,
`ConceptMastery.record_review!` has already moved tier, streak and retention
state off that review, and nothing can undo it. So no action destroys a
reviewed response. `DailyResponse#replace_blocker` states the rule once:
`ResponsesController#start_over` and `DailyExercisesController#regenerate`
both refuse on it, and `RegenerateExerciseJob` asks it again under
`DailyExercise#with_response_locked`, because the controller's answer is
a worker hop and a provider call old by the time the destroy runs — abandoning
the whole regeneration (claim released, the day's one regeneration preserved)
rather than replacing a problem_set the standing review describes. A review
merely in flight (`DailyResponse#reviewing?`, the same stale-claim window
`#review` claims with) blocks the same way; an abandoned claim past that window
does not.

**Accepted consequence of chaining review onto submit:** the reconsider window
that used to sit between the two clicks is gone. Both guards fire within
milliseconds of a submit now — `reviewing?` for the length of the provider
call, `reviewed?` for good after it. The success path does land back on the
dashboard's submitted state, where "Start over" and "Generate new set" live,
but both render only while `reviewed?` is false, so neither is there once the
review it would discard exists. Reconsidering belongs before submitting,
which is untouched. Afterwards those two are reachable only when the
automatic review failed outright, or once an interrupted claim goes stale
with no section written. A partial review blocks them exactly as a partial
manual review always did.

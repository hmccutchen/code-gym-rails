# script/gemini_capacity_probe.rb

## `DEFAULT_PACE_SECONDS`

At 15 seconds per request, no rolling minute holds more than five requests, so the daily limit trips before any per-minute limit.

## `calls_per_day`

The probe measures the current one-exercise initial session. Its expected request count derives from `DaySize.initial`: one draft, a judge and grade for each generated section, one difficulty assessment, one concept reference and three duck turns. Kinds translated before grading add that request through the kind facet. Review pacing accounts for translation too. The opening line reports the minimum; each completed draft records its actual planned request budget. The quota-day estimate uses the interrupted day's budget and remains unknown when the draft never returned. These are estimates for that workload, not a promise that every future kind costs the same. The probe changes neither the user's in-memory preferences nor stored settings.

## `#run`

The run happens in the user's time zone, as generation does, so the day and a mixed account's language are the user's own.

## `#tester_day`

Returns false once a 429 or refused key has ended the run. Judges use the actual selected kinds. Review and duck contexts share an unsaved exercise whose section manifest matches the draft. The reference uses that section's concept and `ConceptBucket`, so a language-independent kind gets its own vocabulary.

## `MemoryResponse`

Review-time translation normally saves its rounds on `DailyResponse`. The probe's local subclass assigns updates in memory, so the existing translation method builds the same review context without saving a response or its associated exercise.

## `#step`

A step is fatal only on a 429 or a refused key. An unusable reply still counted against the quota, so the day carries on after one.

## `#record_attempts`

The review fan-out raises nothing of its own, so a 429 or a refused key during review is read off the recorded attempts instead of an exception.

## `#quota_violation`

A daily violation wins over a per-minute one, matching `GeminiService#quota_id_from`.

## `#tokens_per_completed_day`

Only days whose final duck step received a successful HTTP reply are counted. Earlier unusable replies still consume quota and remain in the total. A day cut short by a refusal, or whose final request times out, never contributes. Completion does not depend on the old two-section request count.

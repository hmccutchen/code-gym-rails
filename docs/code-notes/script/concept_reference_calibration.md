# script/concept_reference_calibration.rb

## `ConceptReferenceCalibration`

The calibration writes no `ApiUsage` rows. A row would charge a teammate's usage history for a calibration they never ran.

## `BUCKETS`

The sample covers every bucket a user can hold, which means both languages, since a "mixed" user holds both.

## `#sequential_phase`

The phase repeats the whole sample list rather than each concept in turn, so a concept's repeats spread out in time instead of landing seconds apart.

## `#concurrent_phase`

The phase runs one thread per concept to mirror the Learn backfill, which enqueues one job per concept. The calls share the provider's rate limit and this machine's CPU, as the backfill's jobs do.

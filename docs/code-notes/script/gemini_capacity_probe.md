# script/gemini_capacity_probe.rb

## `DEFAULT_PACE_SECONDS`

At 15 seconds per request, no rolling minute holds more than five requests, so the daily limit trips before any per-minute limit.

## `#initialize`

The probe sets `daily_section_count` to `SectionCount::FLOOR` in memory only. That gives a two-section plan without changing the user's stored setting.

## `#run`

The run happens in the user's time zone, as generation does, so the day and a mixed account's language are the user's own.

## `#tester_day`

Returns false once a 429 has ended the run.

## `#step`

A step is fatal only on a 429 or a refused key. An unusable reply still counted against the quota, so the day carries on after one.

## `#record_attempts`

The review fan-out raises nothing of its own, so a 429 or a refused key during review is read off the recorded attempts instead of an exception.

## `#quota_violation`

A daily violation wins over a per-minute one, matching `GeminiService#quota_id_from`.

## `#tokens_per_completed_day`

Only days whose last step got an answer are counted, so a day the 429 cut short never contributes.

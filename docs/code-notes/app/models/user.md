# app/models/user.rb

## `api_keys` encryption

The keys for every provider are encrypted together as one value. Decrypting
them needs `RAILS_MASTER_KEY` or the credentials file.

## `before_validation :clean_name`

A name that breaks the rules is cleaned and clamped rather than refused.
Sign-up names the row after the email's local part, which can be long or
oddly shaped, so refusing it would fail the login.

## `before_save :bump_section_kind_preferences_version` and `#section_kind_settings`

`#section_kind_settings` builds `SectionKindSettings` from the user's columns
and their stored values; the one validation `section_kind_settings_hold`
adds its problems, and the callback below asks it whether any preference
changed (see `docs/code-notes/app/models/section_kind_settings.md`).

The version moves only when a preference changes, so an unrelated save (a
login, a time zone) cannot make a pending Exercise mix save stale. The whole
mix shares one version.

## `.login_code_expiry_in_words`

`Duration#inspect` returns the humanized form ("15 minutes"), which is what
the mailer wants; it is not a debug dump.

## `#clear_stale_generation_error!`

Only an error from today is cleared. An error from an earlier day is history,
and the dashboard reports only today's.

## `#record_generation_failure!`, `#record_generation_message!` and `#clear_generation_failure!`

All three write through `#write_generation_status!`, which uses
`update_columns` and skips validation. The failure most worth recording is
a `SetupError`, which can mean the stored `provider` or `language` is
invalid. With `update!`, those inclusion validations would refuse the
write, and a page waiting on the failure would keep polling. The columns
written are bookkeeping that nothing validates, so skipping validation
loses nothing. The specs that pin this write an invalid value with
`update_columns` first.

## `#carry_held_set_forward!`

The read of `held_exercise` before the lock only avoids taking a lock when
there is nothing to move; the locked path reads again. A held row that cannot
be saved is logged and left in place, because raising would return a 500 on
every dashboard load while the user is paused.

## `#anonymize!`

`with_lock` makes the method idempotent: a second call sees `anonymized?` and
returns without overwriting `anonymized_at`.

## `#stored_providers`

The list follows registry order, so Setup lists providers the same way every
time.

## `#first_run?` and `#choose_track`

`#first_run?` is true for a saved account with no `track_chosen_at` and no
exercise. It read `learning_track` too for one release, for an account that
answered the old welcome page between the backfill and that code taking
traffic; `FinishTrackChosenAtBackfill` marked those accounts, so the column
is now in `ignored_columns` until the next release drops it (see
`docs/decisions/tracks.md`). The exercise check keeps the preview seed
account and accounts the nightly batch generated for out of `/welcome`. A null
`track_chosen_at` means no decision was recorded, not that the account is
undecided.

`#choose_track` records the welcome choice and its level. It no longer writes
`learning_track`, so a rollback to before tracks per level, two releases
back, would send an account that chose under this code to `/welcome` again.

## `#prepares_ladders?`

Each prepared ladder is a billed rewrite of a shared reference. A trial
account's calls run on a house key, so a trial is never offered the control
and the endpoint queues nothing for one.

## `#kind_rungs`

Each kind's rung, its target or else the skill level, read through
`KindDifficulty#rungs`, the same reading generation uses. Level suggestions,
their cutoffs and their event rows all work in rungs, so an account with no
targets is handled the same way as one with a target for every kind.

## No level callbacks

`User` records no cutoff and writes no event row when its levels or skill
level change. `ProfileUpdate`, the one flow that changes them on a saved
account, does both explicitly through `LevelChange` (see its notes). A spec
or script that sets levels with `update!` gets the new values and nothing
else.

## `#recent_performance`

It returns the last N sessions by count, which matches the "last 10 sessions"
wording in the generation prompt.

## `#recent_exercise_history`

`before:` defaults to today, since today has had no chance to be answered.
`SizeForecast` passes tomorrow so today's submission is included.

## `#concepts_needing_reinforcement`

Each (concept, bucket) is resolved once, on its latest answered occurrence;
older occurrences are skipped. A section with neither a self-rating nor an AI
rating is out of scope, and one where both are favourable counts as mastered.

## `#concepts_due_for_retention_check_in`

The result is unordered and uncapped, because `DailyPlan` ranks by overdue
ratio, and ordering by date or capping the list would cut across that ranking
(#93).

## `#concepts_overdue_for_retention_check`

Null intervals are excluded explicitly, since `retention_interval_days` is
cleared whenever a check fails.

## `#concept_exposure_index`

The index is memoized per instance so a page that renders many responses
never queries once per section. Several sections tagging the same concept on
one day count as one exposure, which matches `ConceptMastery`.

Each key holds a `Set` of dates rather than an array built with
`array |= [date]`. The union form rescans the whole array for every concept
tag, so the cost grew with the square of the account's age — the same concept
is re-tagged for reinforcement, drills and retention checks, so one key really
does collect a date per submitted day. On 500 submitted days the build
measured 47ms, of which 33ms was that rescan; the `Set` form measured 4.6ms.
The dashboard, `/history` and `/learn` all pay it, through `#first_exposure?`
and the featured concept's "seen N times" line. The `Set` is also what keeps
the one-exposure-a-day rule above true, so a plain array with `<<` would break
the dedup that `spec/models/user_spec.rb` pins.

## `#language_for_today`

For a "mixed" user, today's language is the opposite of the latest earlier
exercise's. Today's own row is excluded so a regeneration picks the same
language as the first generation.

## `#current_streak`

The walk runs back from today in the caller's zone. Only a past weekday that
holds an unsubmitted exercise breaks the streak; today never does.

## `#effective_time_zone`

`time_zone` stays blank until the browser detects it or the user sets one, so
both this method and the time zone validation treat blank as "not yet
detected" and fall back to the team default.

## `#recover_held_set`

It must run under `#with_lock` and in the user's zone. Both callers,
`#resume_generation!` and `#carry_held_set_forward!`, provide both.

## `#held_exercise`

The search excludes today so the set already dated today is never the one
found and moved onto itself.

## `#still_in_vocabulary?`

A concept that has left its vocabulary is not reinforced, since it would
waste an entry and a retention slot. A nil bucket cannot occur in practice;
it returns true.

## `#provider_has_a_stored_key`

It skips an account with no keys map, since anonymized and trial accounts can
name a provider while holding no keys.

# app/models/user.rb

## `api_keys` encryption

The keys for every provider are encrypted together as one value. Decrypting
them needs `RAILS_MASTER_KEY` or the credentials file.

## `before_validation :clean_name`

A name that breaks the rules is cleaned and clamped rather than refused.
Sign-up names the row after the email's local part, which can be long or
oddly shaped, so refusing it would fail the login.

## Section kind validations

The validations that check `section_kind_weights`, `excluded_section_kinds`,
`section_kind_levels` and `locked_section_kinds` against the registry run only
when that column changes. If they ran on every save, a kind retired from the
registry would make every user who names it unsavable, logins included.

## `before_save :bump_section_kind_preferences_version`

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

## `#locks_have_levels`

This is a model validation because a CHECK constraint cannot run subqueries.
A lock that slips past it anyway is inert, because `KindDifficulty#locked?`
ignores a lock on a kind with no target.

## `#provider_has_a_stored_key`

It skips an account with no keys map, since anonymized and trial accounts can
name a provider while holding no keys.

## `#every_slot_keeps_a_kind`

It reads the slot roster from `ExerciseSection.optional_slots` for the
user's own pair (`DailyKinds.for`), so a future slot that holds several
kinds needs no edit here. It runs when the exclusions or the pair change, and
reads `#emptied_slots`, which `DailyKindSwap` also asks to name the kinds in
its refusal; it tests each slot with `KindPreferences#all_excluded?`, the
predicate rotation's whole-slot fallback reads. A pair that leaves an optional slot holding only excluded kinds
is refused, the same as an exclusion that would: rotation would otherwise
fall back to the excluded kinds (`KindPreferences#eligible`), quietly undoing
"never show me this". Single-kind slots are skipped.

## `#keep_unrendered_preferences` and the rotatable-kind validations

The Exercise mix form posts only the controls it renders, and which those
are depends on the pair. Setup renders a weight and an exclude box for each
kind in a multi-kind optional slot, which is `ExerciseSection.rotatable`, and
difficulty controls for the daily kinds and every optional slot's kinds, which
is `ExerciseSection.pickable`; `spec/requests/setup_unrendered_preferences_spec.rb`
pins that the page renders exactly those. A daily kind has no weight row, and
while a fourth kind is daily its two siblings have no row at all (D1).
`ProfileUpdate#profile_attributes` passes every save through
`#keep_unrendered_preferences`, which merges back the stored weights and
exclusions for kinds outside `rotatable` and the stored difficulty targets and
locks for kinds outside `pickable`. A swap can therefore be undone without
losing any of those settings, and an unrelated save never deletes them.
Only entries for kinds still in `ExerciseSection.keys` are kept, so a retired
kind's stored entries drop out on the next save that posts that field.
`section_kind_weights_name_rotatable_kinds` and
`excluded_section_kinds_name_rotatable_kinds` check only the entries a save
adds or changes against `#rotatable_keys`; a kept entry was valid when it
was stored and must not refuse an unrelated save.

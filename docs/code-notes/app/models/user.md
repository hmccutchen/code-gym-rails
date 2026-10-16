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

## `#apply_track_change`

Runs before every save and holds the `TrackChange` for a save that moves the
track, or nil, so a later save on the same object never reads a stale one. It
is declared ahead of `bump_section_kind_preferences_version`: callbacks run in
declaration order and each `if:` is read when its callback is reached, so a
skill-level-only save must clear its targets before the bump checks
`section_kind_levels_changed?`. Otherwise the version would stay put and
another tab could write the cleared levels back. The first track choice is not
a track change.

## `#kind_rungs`, `#record_level_changes` and `#record_level_suggestion_events`

`#kind_rungs` is each kind's rung, its target or else the skill level, read
through `KindDifficulty#rungs`, the same reading generation uses. Level
suggestions, their cutoffs and their event rows all work in rungs, so an
account with no targets is handled the same way as one with a target for
every kind.

`#record_level_changes` runs before any save that changes
`section_kind_levels` or `skill_level`, for every account, after
`#apply_track_change`. It compares each kind's rung before the save
(`*_in_database`) with its rung after, and records a cutoff at the new rung
through the user's own today for each kind that moved onto
`LevelSuggestion::LADDER` (junior, mid_level, senior). A target set, edited or
cleared counts, and so does a skill-level change, which moves every kind
without a target and every kind whose target the track change cleared. Results
from an earlier stay at that rung then never count again, even after a detour
through principal_engineer. A rung that did not move records nothing, and a
move to principal_engineer records nothing, because no suggestion reaches it.
The first track choice records nothing: there are no results yet to cut off.

`#record_level_suggestion_events` runs in `after_save` under the same
conditions. It passes `LevelSuggestionEvent.applied_rows` the levels and skill
level from before and after the save (`*_before_last_save`), the cutoffs as
they stood before, `shown_level_suggestions`, the moves a page posted and
`ProfileController` checked under the row lock, and the kinds the track change
cleared, which are labelled `skill_level_edit`. The insert runs in the save's
transaction, so a failed insert raises and rolls back the level change and
its cutoff together.

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
kinds needs no edit here. It runs only when the exclusions change. A new pair
can leave its old slot holding only excluded kinds, and that save still goes
through: `SectionRotation.eligible` already falls back to the whole slot
when every kind in it is excluded. Single-kind slots are skipped.

# app/models/user.rb

## `api_keys` encryption

The keys for every provider are encrypted together as one value. Decrypting
them needs `RAILS_MASTER_KEY` or the credentials file.

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

## `#generation_failed_today?`

The one test for "generation failed today", read by the dashboard's three
actions and by `#clear_stale_generation_error!` (#691). "Today" is
`Date.current`, so it is the day in whatever zone the caller runs in: a
request runs in the user's zone (`ApplicationController#use_time_zone`), and
so do the generation jobs. The jobs' own `last_generation_error_date.present?`
checks ask a different question, whether any failure is recorded, so they
clear yesterday's too and don't go through this.

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

`#record_generation_failure!` also raises `generation_account_failures` for
a kind `KeyHold.counts?`, with `increment!`, which
adds in SQL, so a copy of the user loaded before another failure still adds
one to the stored count. `RegenerateExerciseJob` passes
`counts_toward_key_hold: false`. `#record_generation_success!` resets the
count with a guarded `UPDATE` for the same reason: the job's copy of the
user can predate the failures. `#clear_generation_failure!` leaves the count
alone, because "Try again" calls it before any provider has answered.

`#report_call_failure` is the one place that decides whether a failed
call's outcome is written: only while `#key_in_use` still equals what the
job noted before the call. The caller holds the row lock, which is what
makes the comparison current. A changed key clears only a failure whose
`last_generation_failure_provider` is the call's own provider, so another
provider's failure and a provider-less message survive.
`when_key_changed:` is what the daily job wants written in that case. It
runs only when the account still has a provider in use and today holds no
failure but the call's own provider's; otherwise the method falls back to
the clear above. A nil provider in
what the job noted means the call started with no key at all, and nothing
is written or cleared for it. `docs/decisions/per-user-api-keys.md` ("A
call that outlives its key") has the rule.

`#store_api_key` and `#use_provider` both put a key in use through the
private `#put_key_in_use`, the one place `provider` is assigned for a key
choice, and it sets the count back to zero: the count describes one
provider's key, so it does not follow the account to another. `#use_provider`
does nothing when the name is the provider already in use, because Setup
posts the current provider with every preferences save. When the provider
does change it first forgets a failure recorded against the provider it
leaves (`#forget_generation_failure_from`), read before `#put_key_in_use`
assigns the new one.
`docs/decisions/pausing-generation.md` has the rule.

`#remove_api_key` calls `#use_provider` with the provider
`#provider_after_removing` names: the most recently saved of the rest when
the key in use was removed, or nil when none is left. So the count resets
only when the removal changes the provider in use, and removing another
key leaves it. It also assigns the failure columns back to empty when
`last_generation_failure_provider` is the removed provider
(`#forget_generation_failure_from`), as part of the caller's save and not
with `#clear_generation_failure!`, which writes at once with
`update_columns` and would land outside that save. `#store_api_key` calls
the same method with the provider saved and the provider in use before the
save, read before `#put_key_in_use` changes it.

`#record_generation_message!` takes an optional `provider:`, which only the
daily job's quality-check message passes. It fills
`last_generation_failure_provider` and leaves `last_generation_failure`
nil, so `#generation_failure_message` still returns the text as written
and nothing counts toward the key hold. Because the provider column is
set, `#forget_generation_failure_from` and `#report_call_failure` treat the
message as that provider's; the first clears `last_generation_error` with
the rest.
`#key_removal_outcome` names what a removal would do without doing it;
Setup words its confirmation from it and the controller words its notice
from the same value once the removal has run. `#store_api_key` and
`#remove_api_key` assign `api_keys` and `key_saved_times` through
`#write_keys`, which keeps a time only for a provider with a stored key.
`#key_saved_time` reads a missing or unreadable time as nil, and
`nil.to_f` is 0, so such a key sorts behind every dated one.
`docs/decisions/per-user-api-keys.md` ("A stored key can be removed") has
the rules.

## `has_many :concept_references` and `:recognition_guides`

Neither association has `dependent:`, unlike the associations around them,
because `AccountData::FATES` is the one place that deletes a user's rows.

## `#carry_held_set_forward!`

The read of `held_exercise` before the lock only avoids taking a lock when
there is nothing to move; the locked path reads again. A held row that cannot
be saved is logged and left in place, because raising would return a 500 on
every dashboard load while the user is paused.

## `#anonymize!`

Account deletion no longer calls this method: since 2026-11-11 it deletes
the row and everything that belongs to it through `AccountDeletion`
(`docs/decisions/deleting-an-account.md`). The method, `#anonymized?`,
`anonymized_at` and `User.active` stay until a separate run has cleaned up
the accounts anonymized before then, and a later change drops them. What
follows describes the method as it still stands.

`with_lock` makes the method idempotent: a second call sees `anonymized?` and
returns without overwriting `anonymized_at`.

The authenticator's columns come from
`User::Authenticator::ERASED_ON_ACCOUNT_DELETION`, spread into the same
`update!`, so the class that owns those columns also says how deletion erases
them. `sessions_valid_after` stays listed here because `SignedInSessions` owns
it. `disable!` isn't used: turning the authenticator off keeps the sign-in
challenge and the daily cap's count, which deletion erases.

## `#give_back_invite_seat!`

Account deletion gives back the seat the account's invite code gave it.
It lives here, and the seat count on `InviteCode#give_back_seat!`, because
`trial_isolation_spec` allows only the trial models and `User` to read
invite state; `AccountDeletion` calls it without naming the code.

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

## `#writes_learn_content?`

Trials are paused, and a trial account's calls would run on a house key, so
the owner decided a trial account writes no Learn content
(`docs/decisions/learn-content-per-user.md`). Every way a concept write-up is
queued checks it, and `GenerateConceptReferenceJob` checks it again before
the call: the Learn prepare actions, AI difficulty guidance, the write-ups
queued on submit and those queued when a set is generated. A trial is never
offered the controls.

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

It returns the latest qualifying response days through `AdaptationHistory`,
with only assessed adaptation sections and optional core completion. The default
`PERFORMANCE_HISTORY_LIMIT` remains ten; malformed concept maps omit names
without losing otherwise valid grades.

`#recent_delivered_content` separately projects active delivered concepts and
scenario strings, without a response requirement, raw answers or answer keys.

## `#recent_exercise_history`

Rotation reads delivered plus dropped scheduled kinds, never responses.
`before:` defaults to today.

The old separate completion reader is retired. `CompetencyGate::Evidence`
projects basic core completion independently of strict results, without drop
credit. Planning reads earlier than today; `SizeForecast` passes the
exercise date's next day so today's eligible evidence can enter.

## `#concepts_needing_reinforcement`

Each (concept, bucket) resolves once on its latest assessed, vocabulary-valid,
hostable occurrence; ineligible sections cannot resolve it or crowd the
qualifying response-day window. Co-favourability and paused suppression
follow resolution. Tiers load once for selected pairs, without per-response
queries. Explicit drills come first and remain independent of inferred work.

## `#concepts_due_for_retention_check_in`

The result is unordered and uncapped, because `DailyPlan` ranks by overdue
ratio, and ordering by date or capping the list would cut across that ranking
(#93).

## `#concepts_overdue_for_retention_check`

Null intervals are excluded explicitly, since `retention_interval_days` is
cleared whenever a check fails.

## `#concept_exposures`

The `ConceptExposureIndex` is memoized per `User` instance, so a page that
renders many responses builds it once. `DailyResponse` reaches the same
instance through `belongs_to :user, inverse_of:`, and the helper, the Learn
controller and the featured callout all read `current_user`. Nothing clears
it: a fresh `User` load is a fresh index. The memo lives here because the
user instance is the one object every reader shares; see
`docs/code-notes/app/models/concept_exposure_index.md` for the index itself.

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
name a provider while holding no keys. An account that removed its last key
holds no provider either.

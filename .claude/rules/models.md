---
paths:
  - "app/models/**"
  - "db/**"
---

# Models

Generated exercise plan notes also carry a server-owned `kind_rungs` input
snapshot captured once for ingest and retries. The workload fold reads it
without consulting current profile settings. Missing legacy maps use
observed-rung fallback. Mastery receipt and suffix formats belong to
`DailyResponse` and `ConceptMastery::Reconciliation`, respectively; only
exact `{}` is unused. See `docs/decisions/daily-mastery-reconciliation.md`.
Retiring or renaming kinds, or changing grade/self-rating/tier tokens or
semantics, must preserve compatibility or deliberately migrate both durable
receipt tokens and open suffix data/policy before rollout. Frozen decoding
alone does not preserve replay semantics.

`ConceptMastery.practice_requests` is non-null jsonb, default `{}`, keyed by
kind with closed mode, source response ID and original operation timestamp.
P-C introduced compatible readers after P-S; P-A enables initiation after the P-C deployment gate.
Version-2 receipts and mixed-policy journals preserve enrollment after
compaction. `DailyExercise.plan_notes["practice_schedule"]` holds format-1,
policy-2 continuation and assignment metadata. Missing legacy notes are
safe; malformed nonempty state fails closed. See
`docs/decisions/protected-practice-opportunities.md`.


`DailyExercise.opened_at`, `User.generation_pause_source` and
`User.generation_account_failures` shipped one release ahead of the code
that uses them, because the worker can start before the web service has
migrated (`.claude/rules/deployment.md`, Migrations).
`AddUnopenedSetPauseColumns` filled `opened_at` with `created_at` on every
set that existed then and marked every paused account `manual`;
`RepeatUnopenedSetPauseFills` repeats both fills for rows written in
between, as `docs/decisions/tracks.md` records for `track_chosen_at`. What
reads and writes each column:

- `opened_at`: the first time the set was shown on the dashboard, or the
  time a resume acknowledged it. Written once by `DailyExercise#mark_opened!`,
  when the dashboard shows a finished set to its owner, and by
  `DailyExercise.acknowledge_unopened!`, which `#clear_generation_pause!`
  runs on the user's unopened sets dated before today. A count of sets
  opened therefore overcounts slightly for an account that was paused and
  resumed. Read by
  `DailyExercise.latest_openings` for `UnopenedSets`. A set created by
  current code starts with none.
- `generation_pause_source`: written by `User#pause_generation!` and cleared
  by `#clear_generation_pause!`, which `#resume_generation!` calls. Read by `#generation_pause_kind` and
  `#generation_paused_automatically?`, which treat `paused_generation_at` as
  the authority, so no validation ties the two columns.
- `generation_account_failures`: raised by `User#record_generation_failure!`
  for a kind in `KeyHold::KINDS`, set to zero by
  `#record_generation_success!` and `#store_api_key`, and by
  `#remove_api_key` and `#use_provider` when they change the provider in
  use. Read by
  `ScheduledGeneration.users`.

`docs/decisions/pausing-generation.md` has the rules.


| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, skill_level, focus_areas (jsonb), api_keys (encrypted JSON map of provider to key), provider (the one in use), invite_code_id (nullable fk; the code that admitted the account), trial_started_at / trial_ends_at / trial_consented_at (nullable; a present trial_ends_at is the trial), language, daily_section_count (nullable integer; nil = Automatic), reminder_level (enum: none/ready/ready_and_nudges, default none), anonymized_at (nullable — set by `User#anonymize!`, which account deletion no longer calls; kept, with `User.active`, until the accounts anonymized before 2026-11-11 are cleaned up and a later change drops it), section_kind_weights (jsonb, default {}), excluded_section_kinds (jsonb, default []), section_kind_levels (jsonb, default {}), locked_section_kinds (jsonb, default []), learning_track (nullable: junior/none; ignored by `User` and read by nothing, until the next release drops the column), level_suggestion_cutoffs (non-null jsonb, default {}), level_suggestions (boolean, default true), level_suggestion_answers (integer, default 0), daily_section_kinds (jsonb, default []: the user's daily kinds in place order, the pair then up to two chosen extra sections; empty = `DailyKinds::DEFAULT`), track_chosen_at (nullable datetime: set when the welcome track choice is recorded; for accounts that predate it, their creation time, so it is a flag, not a clock; null means no decision was recorded, not that the account is undecided), login_code_digest / login_code_sent_at / login_code_attempts (the emailed sign-in code), otp_secret (encrypted) / consumed_timestep (last accepted TOTP step) / otp_backup_codes (bcrypt digests of unused recovery codes) / two_factor_enabled_at (nil = authenticator off), second_factor_challenge_at / second_factor_challenge_failures (the pending sign-in challenge and its wrong codes), second_factor_failures / second_factor_failures_since (the 24-hour cap on wrong codes), sessions_valid_after (a session signed in before this counts as signed out), generating_since (nullable datetime: the claim a running `GenerateDailyExercisesJob` holds on the user, declared with `Claimable` and stale after `User::GENERATION_STALE_AFTER`), generation_pause_source (nullable string, no default: `manual` or `automatic` while paused, and `paused_generation_at` is the authority for whether it is), generation_account_failures (integer, default 0: generation failures in a row the provider put down to a bad key or no credit; `KeyHold::AFTER` of them hold the schedule) and key_saved_times (non-null jsonb, default {}: provider key to the ISO 8601 time its API key was saved; a provider with no entry was saved before the column existed. `User#store_api_key` writes an entry and `#remove_api_key` deletes one, each in the same assignment as `api_keys`; `#provider_after_removing` reads it to pick the key that takes over; `#anonymize!` clears it) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, design_comparison, pattern, a rotating third key, a rotating fourth key; at most four of them per day), language, generated_at, regenerated_at, dropped_sections (jsonb), plan_notes (jsonb, default {}: what the plan did — `daily_kinds`, `size`, `coverage`, `shared_concept`), opened_at (nullable datetime: the first time the dashboard showed the finished set to its owner, or the time a resume of generation acknowledged it unopened; a set from before the column holds its created_at) |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), ai_review (jsonb), review_provider (which provider wrote the review), concept_tags (jsonb), mastery_application (non-null jsonb, default {}: durable v1/v2 receipt with legacy/processed section keys, once-only core-session flag and skip identities; v2 pins policy 2 and retains enrollment after suffix compaction) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date, model, cache_read_tokens, cache_write_tokens (the last three null on rows written before they existed) |
| `ConceptMastery` | user_id, concept, language, tier (standard/reduced/paused), streak, last_rating, mastered_at, retention_interval_days, next_retention_check_on, drilled_at, drill_group, cooldown_remaining, practice_requests (non-null jsonb, default {}, per-kind mode/source/time), review_reconciliation (non-null jsonb, default {}: v1 nine-field or v2 extended baseline and ordered review/session/skip/drill correction suffix, retained from the earliest pending contribution) — one user's standing on one concept; `record_review!` and `ConceptDrills` route every write through pure policy dispatch and reconciliation |
| `ReviewFollowUp` | daily_response_id, section, role (user/assistant), content — one message of a follow-up conversation under a review; deleted with the account (`AccountData::FATES`) |
| `RecognitionGuide` | user_id (nullable fk; the owner, or null for a shared row read as a fallback until L5, see `docs/decisions/learn-content-per-user.md`), group_key (unique per user; unique among rows with no user_id through a partial index), questions, contrast, misfires — a guide that teaches a way of looking, one per group for each user |
| `SuggestedConcept` | language, normalized_name, display_name, occurrences, first_seen_at, last_seen_at, status (pending/promoted/dismissed), reviewed_by_id, reviewed_at — a concept tag the provider invented, held for an admin and never added to a vocabulary on its own |
| `InviteCode`    | code_digest (SHA-256 of the raw code, unique), label, seats, redeemed_count, expires_at, trial_days, daily_request_cap |
| `PushSubscription` | user_id, endpoint (unique), p256dh_key, auth_key, last_delivered_at — one browser install; transport for the reminder, never intent |
| `FeaturedConcept` | user_id, week_of (the Monday, in the user's zone), bucket, concept — unique on user_id and week_of; one row per week a user had a concept to feature |
| `DuckThread` | user_id, daily_exercise_id (unique), draft_scope (the exercise's scope when written; a mismatch reads as empty), threads (jsonb keyed by section: turns, version, cleared) |
| `LevelSuggestionEvent` | user_id, kind, action (applied/dismissed/removed), source (suggestion/setup_edit/skill_level_edit, applied rows only), from_level, to_level, window_size, favourable, too_hard_latest3, newest_result_on |
| `DailyKindSwapEvent` | table `daily_kind_swaps`: user_id, place (0-based), from_kind, to_kind, today_section (unanswered/answered/submitted/not_in_set/no_set), planned_size (the `plan_notes["size"]` of today's set, or of a paused user's held set not yet moved to today; null for no_set or an unrecorded size), size_setting (`daily_section_count` at the swap; null = Automatic) — one row per saved swap |
| `ConceptReference` | user_id (nullable fk; the owner, or null for a shared row read as a fallback until L5, see `docs/decisions/learn-content-per-user.md`), concept, language (unique per user; unique together among rows with no user_id through a partial index), tagline, explanation, code_example, senior_lens, guide_plain_language, guide_worked_example, guide_pitfalls, ladder_junior, ladder_mid_level, ladder_senior, ladder_principal_engineer, lesson, generation_version — one reference per concept for each user; `.claude/rules/learn.md` owns its rules |
| `JudgeSolve` | one row per blind judge pass on a design comparison: user_id, daily_exercise_id, set_generated_at (all null only for synthetic), source (live/replay/synthetic), section, attempt, edit_check, shipped, never_shown_reason (replaced_by_retry/section_dropped, live unshipped rows only), edit_reverted, revert_reason, rung, locked, concept, judge_status, judge_pick, key_better, matched (null = unsolved), unsolved_reason, unsolved_detail, judged_section (jsonb, with its answer_key), section_digest, judge_provider, judge_model, draft_model, app_revision, human_call (checked against matched), human_note, human_called_at. Every page reads content through `JudgeSolve.readable` (hidden unless proven: synthetic, a never_shown_reason, or that row's own section reviewed on the set it belongs to); `docs/decisions/design-comparison-the-second-fixed-section.md` |

`ConceptReference` (owned per user since L2; see `.claude/rules/learn.md`)
also carries `guide_plain_language`, `guide_worked_example`,
`guide_pitfalls` (all nullable text). `ConceptReference#guide?` — all three
guide fields present — is the single authority for "does this row carry a
guide". It also
carries `ladder_junior`, `ladder_mid_level`, `ladder_senior`,
`ladder_principal_engineer` (all nullable text), and `ConceptReference#ladder?`
— every ladder field present, one per rung in `KindDifficulty::LEVELS`, derived from the field list the same way `#guide?` is — is the
authority for "does this row carry the difficulty ladder"; `#complete?` is
`guide? && ladder?`. It also carries `lesson` (nullable jsonb): the short
lesson the Learn page shows, in `ConceptLesson`'s shape. `#lesson?` says
whether a row has one. It reads through `#usable_lesson`, so a stored value
with no part the page can show counts as none. It stays out of
`#complete?`, so the ladder poll and `LadderCoverage` never wait on it; `#fully_written?` is `complete? &&
lesson?`, the check `GenerateConceptReferenceJob` skips a row on.

`generation_version` advances on each successful generation write, even when
the provider returns unchanged text or an incomplete ladder. Learn polls that
counter to distinguish a completed rewrite from queued work; `updated_at` and
content equality cannot do that because an unrelated update changes the
timestamp and a valid generation may leave the prose unchanged. Failed calls and skipped
rewrites do not advance it.

`GenerateConceptReferenceJob` uses Solid Queue's per-user/concept/language
concurrency permit with `on_conflict: :discard`. One user's refresh modes
share the permit because they write the same row; another user's job has a
permit of its own, since it writes that user's row. Overlapping jobs are
discarded rather than blocked: a blocked job could make another billed call
immediately after an incomplete result. Finishing or failing releases the
permit, so a later explicit retry remains possible. Its expiry derives from
the reference call budget, and the dispatcher recovers expired permits after
an interrupted worker. That lease includes queue time; it does not guarantee
deduplication beyond its expiry. The existing row lock still guards writes
after expiry or for direct `perform_now` calls, which bypass queue controls.
`GenerateRecognitionGuideJob` keys its permit on user and group key the same
way, so one user's overlapping job is discarded and a teammate's never is.

Exercise mix autosaves update the open form without navigating.
`ExerciseMixLadders` supplies the same guidance counts and labels to the initial
Setup render and preference-save responses, including stale-tab corrections.
The client applies the response for its latest edit and keeps guidance
preparation disabled until pending saves finish. Preparing guidance is
optional: difficulty targets already apply without it, and the action writes
concept-specific difficulty descriptions for future generation, not a new set.

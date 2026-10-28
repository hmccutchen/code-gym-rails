---
paths:
  - "app/models/**"
  - "db/**"
---

# Models


| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_keys (encrypted JSON map of provider to key), provider (the one in use), invite_code_id (nullable fk; the code that admitted the account), trial_started_at / trial_ends_at / trial_consented_at (nullable; a present trial_ends_at is the trial), language, daily_section_count (nullable integer; nil = Automatic), reminder_level (enum: none/ready/ready_and_nudges, default none), anonymized_at (nullable — set on self-service deletion), section_kind_weights (jsonb, default {}), excluded_section_kinds (jsonb, default []), section_kind_levels (jsonb, default {}), locked_section_kinds (jsonb, default []), learning_track (nullable: junior/none; ignored by `User` and read by nothing, until the next release drops the column), level_suggestion_cutoffs (non-null jsonb, default {}), level_suggestions (boolean, default true), level_suggestion_answers (integer, default 0), daily_section_kinds (jsonb, default []: the user's daily kinds in place order, the pair then up to two chosen extra sections; empty = `DailyKinds::DEFAULT`), track_chosen_at (nullable datetime: set when the welcome track choice is recorded; for accounts that predate it, their creation time, so it is a flag, not a clock; null means no decision was recorded, not that the account is undecided), login_code_digest / login_code_sent_at / login_code_attempts (the emailed sign-in code), otp_secret (encrypted) / consumed_timestep (last accepted TOTP step) / otp_backup_codes (bcrypt digests of unused recovery codes) / two_factor_enabled_at (nil = authenticator off), second_factor_challenge_at / second_factor_challenge_failures (the pending sign-in challenge and its wrong codes), second_factor_failures / second_factor_failures_since (the 24-hour cap on wrong codes), sessions_valid_after (a session signed in before this counts as signed out) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, design_comparison, pattern, a rotating third key, a rotating fourth key; at most four of them per day), language, generated_at, regenerated_at, dropped_sections (jsonb), plan_notes (jsonb, default {}: what the plan did — `daily_kinds`, `size`, `coverage`, `shared_concept`) |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), ai_review (jsonb), review_provider (which provider wrote the review), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date, model, cache_read_tokens, cache_write_tokens (the last three null on rows written before they existed) |
| `InviteCode`    | code_digest (SHA-256 of the raw code, unique), label, seats, redeemed_count, expires_at, trial_days, daily_request_cap |
| `PushSubscription` | user_id, endpoint (unique), p256dh_key, auth_key, last_delivered_at — one browser install; transport for the reminder, never intent |
| `FeaturedConcept` | user_id, week_of (the Monday, in the user's zone), bucket, concept — unique on user_id and week_of; one row per week a user had a concept to feature |
| `DuckThread` | user_id, daily_exercise_id (unique), draft_scope (the exercise's scope when written; a mismatch reads as empty), threads (jsonb keyed by section: turns, version, cleared) |
| `LevelSuggestionEvent` | user_id, kind, action (applied/dismissed/removed), source (suggestion/setup_edit/skill_level_edit, applied rows only), from_level, to_level, window_size, favourable, too_hard_latest3, newest_result_on |
| `DailyKindSwapEvent` | table `daily_kind_swaps`: user_id, place (0-based), from_kind, to_kind, today_section (unanswered/answered/submitted/not_in_set/no_set), planned_size (the `plan_notes["size"]` of today's set, or of a paused user's held set not yet moved to today; null for no_set or an unrecorded size), size_setting (`daily_section_count` at the swap; null = Automatic) — one row per saved swap |
| `JudgeSolve` | one row per blind judge pass on a design comparison: user_id, daily_exercise_id, set_generated_at (all null only for synthetic), source (live/replay/synthetic), section, attempt, edit_check, shipped, never_shown_reason (replaced_by_retry/section_dropped, live unshipped rows only), edit_reverted, revert_reason, rung, locked, concept, judge_status, judge_pick, key_better, matched (null = unsolved), unsolved_reason, unsolved_detail, judged_section (jsonb, with its answer_key), section_digest, judge_provider, judge_model, draft_model, app_revision, human_call (checked against matched), human_note, human_called_at. Every page reads content through `JudgeSolve.readable` (hidden unless proven: synthetic, a never_shown_reason, or that row's own section reviewed on the set it belongs to); `docs/decisions/design-comparison-the-second-fixed-section.md` |

`ConceptReference` (not listed above — it has no `user_id`; see
`.claude/rules/learn.md`) now also carries `guide_plain_language`, `guide_worked_example`,
`guide_pitfalls` (all nullable text). `ConceptReference#guide?` — all three
guide fields present — is the single authority for "does this row carry a
guide". It also
carries `ladder_junior`, `ladder_mid_level`, `ladder_senior`,
`ladder_principal_engineer` (all nullable text), and `ConceptReference#ladder?`
— every ladder field present, one per rung in `KindDifficulty::LEVELS`, derived from the field list the same way `#guide?` is — is the
authority for "does this row carry the difficulty ladder"; `#complete?` is
`guide? && ladder?`. It also carries `lesson` (nullable jsonb): the short
lesson the Learn page shows, in `ConceptLesson`'s shape. `#lesson?` says
whether a row has one and stays out of `#complete?`, so the ladder poll and
`LadderCoverage` never wait on it; `#fully_written?` is `complete? &&
lesson?`, the check `GenerateConceptReferenceJob` skips a row on.

`generation_version` advances on each successful generation write, even when
the provider returns unchanged text or an incomplete ladder. Learn polls that
counter to distinguish a completed rewrite from queued work; `updated_at` and
content equality cannot do that because an unrelated update changes the
timestamp and a valid generation may leave the prose unchanged. Failed calls and skipped
rewrites do not advance it.

`GenerateConceptReferenceJob` uses Solid Queue's per-concept/language
concurrency permit with `on_conflict: :discard`. Users and refresh modes share
the permit because they share the cached reference. Overlapping jobs are
discarded rather than blocked: a blocked job could make another billed call
immediately after an incomplete result. Finishing or failing releases the
permit, so a later explicit retry remains possible. Its expiry derives from
the reference call budget, and the dispatcher recovers expired permits after
an interrupted worker. That lease includes queue time; it does not guarantee
deduplication beyond its expiry. The existing row lock still guards writes
after expiry or for direct `perform_now` calls, which bypass queue controls.

Exercise mix autosaves update the open form without navigating.
`ExerciseMixLadders` supplies the same guidance counts and labels to the initial
Setup render and preference-save responses, including stale-tab corrections.
The client applies the response for its latest edit and keeps guidance
preparation disabled until pending saves finish. Preparing guidance is
optional: difficulty targets already apply without it, and the action writes
concept-specific difficulty descriptions for future generation, not a new set.

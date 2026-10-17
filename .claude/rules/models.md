---
paths:
  - "app/models/**"
  - "db/**"
---

# Models


| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_keys (encrypted JSON map of provider to key), provider (the one in use), invite_code_id (nullable fk; the code that admitted the account), trial_started_at / trial_ends_at / trial_consented_at (nullable; a present trial_ends_at is the trial), language, daily_section_count (nullable integer; nil = Automatic), reminder_level (enum: none/ready/ready_and_nudges, default none), anonymized_at (nullable — set on self-service deletion), section_kind_weights (jsonb, default {}), excluded_section_kinds (jsonb, default []), section_kind_levels (jsonb, default {}), locked_section_kinds (jsonb, default []), learning_track (nullable: junior/none; ignored by `User` and read by nothing, until the next release drops the column), level_suggestion_cutoffs (non-null jsonb, default {}), level_suggestions (boolean, default true), level_suggestion_answers (integer, default 0), daily_section_kinds (jsonb, default []: the user's daily kinds in place order; empty = `DailyKinds::DEFAULT`), track_chosen_at (nullable datetime: set when the welcome track choice is recorded; for accounts that predate it, their creation time, so it is a flag, not a clock; null means no decision was recorded, not that the account is undecided) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, design_comparison, pattern, a rotating third key, a rotating fourth key; at most four of them per day), language, generated_at, regenerated_at, dropped_sections (jsonb), plan_notes (jsonb, default {}: what the plan did — `daily_kinds`, `size`, `coverage`, `shared_concept`) |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), ai_review (jsonb), review_provider (which provider wrote the review), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date, model, cache_read_tokens, cache_write_tokens (the last three null on rows written before they existed) |
| `InviteCode`    | code_digest (SHA-256 of the raw code, unique), label, seats, redeemed_count, expires_at, trial_days, daily_request_cap |
| `PushSubscription` | user_id, endpoint (unique), p256dh_key, auth_key, last_delivered_at — one browser install; transport for the reminder, never intent |
| `FeaturedConcept` | user_id, week_of (the Monday, in the user's zone), bucket, concept — unique on user_id and week_of; one row per week a user had a concept to feature |
| `DuckThread` | user_id, daily_exercise_id (unique), draft_scope (the exercise's scope when written; a mismatch reads as empty), threads (jsonb keyed by section: turns, version, cleared) |
| `LevelSuggestionEvent` | user_id, kind, action (applied/dismissed/removed), source (suggestion/setup_edit/skill_level_edit, applied rows only), from_level, to_level, window_size, favourable, too_hard_latest3, newest_result_on |

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

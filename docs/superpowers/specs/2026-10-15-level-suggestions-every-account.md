# Level suggestions for every account (PR 2)

Plan only. Read on `origin/main` at **bcbfad6**, with #390 and #391 both merged. #391 merged with the same tree as the head `e92a052` this plan was first read against, and every claim below was re-checked on bcbfad6.

This plan follows `2026-10-14-level-suggestions.md` ("PR 2" and "Changes requested at review") except where the request for this PR overrides it. Every claim is marked **Verified** (read in the code or fixtures named) or **Inferred** (follows from what was read, but not run).

## What changes for a person

- Every account gets level suggestions on the submitted dashboard, not just junior-track accounts. The rule is the one #390 shipped: one rung at a time along junior, mid-level and senior, from each kind's own reviewed results.
- Accepting a suggestion sets that one kind's level. The account's skill level stays where it was.
- The "Suggest level changes" switch moves into Setup's Exercise mix, where every account can find it.
- A junior-track account whose kinds all reach senior keeps getting suggestions, step-backs included.
- Nothing is generated or graded differently. Suggestions are computed from stored results and only shown.

## Starting conditions

1. **#391 has merged (bcbfad6).** Its welcome view renders the level step from `TrackGraduation::LADDER` (**Verified**, `app/views/welcome/show.html.erb:36`), and `TRACK_CHOICE_KEYS[OFF]` now allows `skill_level` (**Verified**, `profile_controller.rb:163`). The rename below changes the welcome view's constant, and #391's `welcome_spec.rb` and `profile_learning_track_spec.rb` move with it.
2. **There is no `WelcomeController::STARTING_LEVELS` to replace (Verified).** #391 reads the ladder constant directly, so the welcome levels and the suggestion ladder are already one list. The rename commit changes that one reference to `LevelSuggestion::LADDER`; a spec pins that the welcome step offers exactly `LevelSuggestion::LADDER`.
3. **The Experienced hint is not touched.** #391 replaced it.

## Design

### Rungs, not targets

Today the rule reads `user.section_kind_levels`, the targets, and skips any kind without one (**Verified**, `track_graduation.rb:21` and `:74`). A track account has a target for every kind, so that worked. Most accounts have none.

`LevelSuggestion.for(user)` reads each kind's **rung** instead: `KindDifficulty#rung_for(kind, skill_level:)`, the target when set, else the skill level. That is the same reading generation uses, so the card never proposes moving a kind from a level it isn't at. Everything else that keyed on the target moves to the rung:

- candidates (rung in `LADDER`, kind not locked);
- the cutoff check (a cutoff counts only at the kind's current rung);
- dismissal's kind check and the cutoff level it writes;
- the event rows' `from_level`.

A lock needs a target (`locks_have_levels`), so an untargeted kind is never locked (**Verified**, `user.rb:39`).

### Rename (pure commits)

| From | To |
|---|---|
| `TrackGraduation`, `TrackGraduation::Evidence` | `LevelSuggestion`, `LevelSuggestion::Evidence` |
| `dashboard/_track_proposal` | `dashboard/_level_suggestion` |
| `track_proposal_controller.js` (`track-proposal`) | `level_suggestion_controller.js` (`level-suggestion`) |
| `LearningTrackDismissalsController`, `LearningTrackAnswersController` | `LevelSuggestionDismissalsController`, `LevelSuggestionAnswersController` |
| `POST /learning_track/dismissal`, `/answer` | `POST /level_suggestion/dismissal`, `/answer` |
| `learning_track.proposal.*` locale keys | `level_suggestion.card.*` |
| `LearningTrack::IN_PLACE_ANSWERS` | `LevelSuggestion::IN_PLACE_ANSWERS` |
| `User#suggests_track_moves?`, `#applies_track_proposals_in_place?` | `#suggests_level_moves?`, `#applies_level_suggestions_in_place?` |
| `TrackGraduation::Result#favourable?` | `LevelSuggestion::Result#ai_favourable?` |
| save-queue names `track_apply`, `track_dismissal`, `track_answer` | `level_apply`, `level_dismissal`, `level_answer` |

Specs, code notes and system specs move with their files. The rename commits change no behavior: the suite passes after each one with only names changed.

**Why `ai_favourable?` (requested).** Two rules now share the word "favourable" and mean different things:

- `ReviewedSectionResults#favourable?(bar:)`, which the competency gate reads, needs the AI rating at the bar **and** a favourable self-rating. The gate grows a day's size with no one approving it, and the AI rating's calibration against the stated level is unverified, so it asks both ratings to agree.
- The suggestion's check is the AI rating alone. The self-rating still has its own say, as the too-hard veto over the latest three, and nothing moves without an explicit Apply.

A one-line comment on `ai_favourable?` points at this difference; the reasoning goes in `docs/code-notes/app/services/level_suggestion.md`.

### Old paths, one release

`config/routes.rb` keeps `POST /learning_track/dismissal` and `/learning_track/answer` routed straight to the new controllers, each under a bare route annotation, with a one-line note naming the PR that removes them. Not redirects: `code_gym/request.js` treats a followed redirect as a signed-out session (**Verified** in the original plan's review, `request.js:36`). The removal goes in the same later PR that drops the ignored columns.

An old Setup tab can also post `track_suggestions` to `PATCH /profile`. Once that column is ignored, assigning it raises `ActiveModel::UnknownAttributeError`, a 500 (**Inferred** from Rails' `ignored_columns` behavior). For one release `ProfileController` reads `track_suggestions` as `level_suggestions`, with the same true-or-false check. A request spec covers it.

### Data and migration

One migration, `AddLevelSuggestionColumnsToUsers`:

```ruby
def up
  add_column :users, :level_suggestions, :boolean, default: true, null: false
  add_column :users, :level_suggestion_cutoffs, :jsonb, default: {}, null: false
  execute <<~SQL
    UPDATE users SET level_suggestions = track_suggestions,
                     level_suggestion_cutoffs = track_evidence_cutoffs
  SQL
end

def down
  remove_column :users, :level_suggestion_cutoffs
  remove_column :users, :level_suggestions
end
```

- `User.ignored_columns += %w[track_suggestions track_evidence_cutoffs]`, the `api_key` precedent (`f63594b`, **Verified**). A later PR drops them.
- `track_proposals_answered` keeps its name (decision E). Only `User`, the answer controller and the card read it.
- The backfill copies every row, so an account that turned suggestions off on the track stays off, and every other account reads `true`, the column's default.

**Rollback.**
- `down` drops the two new columns. The old columns were never written by the migration, so old code runs unchanged against them.
- Rolling back code without the migration also works: old code never reads the new columns.
- **Two accepted windows.** A dismissal or level change written by old code after the migration runs but before new code serves is not copied, so it costs one repeat offer. And after a code rollback, old code reads `track_*` values that miss anything new code wrote, with the same cost. Both are bounded to a re-offer the user can dismiss again.

### `record_level_changes` for every account

`User#record_track_level_changes` (**Verified**, `user.rb:463-477`) runs only on the track and only when `section_kind_levels` changes. It compares targets, so it misses a cleared target and a skill-level change.

It becomes `record_level_changes`, a `before_save` for every account, run when `section_kind_levels` or `skill_level` changes:

- For each kind, compare the rung before the save (`section_kind_levels_in_database`, `skill_level_in_database`) with the rung after.
- A kind whose rung changed to a rung on `LADDER` gets `{level: new rung, through: today in the user's zone}` in `level_suggestion_cutoffs`.
- A rung that didn't change records nothing: a target set to the level the skill level already gave, or a skill-level change for a targeted kind.
- A move to principal engineer records nothing, since no suggestion reads principal.
- A save that also changes `learning_track` records nothing, as today. That covers the welcome page's junior preset and #391's Experienced level, both first-run choices with no results to cut off.

`finish_learning_track` stays as it is (ends the track when no target is below senior), but it no longer changes what the dashboard shows.

### Apply on an account without targets

The card's Apply already posts the stored targets plus one key per listed kind (**Verified**, `track_proposal_controller.js` `apply()`). For an account with no targets that is exactly one new target, and `skill_level` is not in the request. No code change is needed for the write; specs pin it.

### A stale card could move a kind the wrong way (found while planning)

The card's Apply is guarded by `section_kind_preferences_version`, but a skill-level change doesn't bump that version (**Verified**, `user.rb:516-519`). So:

1. The dashboard shows "Try code review at mid-level" while the skill level is junior.
2. In another tab, the user sets the skill level to senior. Code review is now at senior.
3. Apply on the old card still matches the version, and writes a `mid_level` target: a step **down**, labelled as a suggestion.

This only exists once untargeted kinds get suggestions, so it belongs to this PR. The fix is the same request as the event-labelling fix below.

### Event accuracy (decision A): the card posts what it showed

**Recommended: the card posts the steps it displayed, and the server checks them under the row lock.** Documenting the limits instead would leave the stale-card bug above in place.

- Apply and the Setup save send `level_suggestion: { steps: [{ kind, from, to }, …] }` beside the levels.
- `ProfileController` checks each step inside the existing `with_lock`, after the version check:
  - `from` must equal the kind's current rung. If not, the reply is the existing **409 stale**, which the card already handles by reloading once saves finish.
  - `to` must be one rung from `from` on `LADDER`, and must equal the level this request saves for that kind. Otherwise **422**, nothing saved.
- The checked steps go to the model through an attribute the event callback reads. A rung change that matches a checked step is `source: suggestion` with the `to_level` the card showed. Every other rung change is `setup_edit`.
- The dismissal request already sends kinds and a reason. It gains each kind's displayed `from` and `to`, checked the same way: `from` must be the current rung (409 if not), `to` one rung away (422 if not). The row stores the displayed `to_level`.
- **Setup:** when Setup was opened from the card's link (`suggested[]` and `suggested_level`), the Exercise mix sends a step for a highlighted kind whose new level equals the suggested one. So after three answers, when acceptance happens in Setup, those edits are still labelled `suggestion`.
- The evidence counts on each row are still computed by the server at write time. They can differ from the card's numbers when a review lands in between. The code note says so.

What this fixes from the three cases named in the request:

| Case | Today | With posted steps |
|---|---|---|
| A review lands between render and Apply | label and `to_level` come from a new proposal | label and `to_level` are what the card showed |
| A kind removed after Apply | `to_level` recomputed from the post-Apply proposal, often nil | the `to` the card showed |
| A Setup edit on an unsubmitted day matches a pending proposal | labelled `suggestion` | `setup_edit`, since no card was shown |

Trust: a client can still post a step that matches a real adjacent move and label its own edit `suggestion`. That only mislabels the account's own analytics row; the move itself is one the user could make in Setup anyway.

Cost of the change: the server no longer recomputes a proposal on every level-changing save. It still runs the evidence query once for the counts.

### Skill-level changes write event rows (decision B)

A skill-level change can move up to ten untargeted kinds. **Recommended:** one `applied` row per kind whose rung moved, `source: setup_edit`, so later "stuck" analysis sees every rung change, however it was made. The alternative is no rows for skill-level changes, which would leave gaps in exactly the accounts this PR adds.

### Dismissal endpoint: 422, never 500

`create!` and `update!` run inside `with_lock` (**Verified**, `learning_track_dismissals_controller.rb:29-35`).

- **The event rows can't be invalid.** `kind` is checked against `ExerciseSection.keys` before the write, `action` comes from a closed map, and `source` is nil for both dismissal actions. A spec builds every kind × reason and asserts each row is `valid?`.
- **The user row can be.** `update!` runs every unconditional `User` validation, including `time_zone_must_be_loadable` (**Verified**, `user.rb:33`). A stored zone that a tzdata update removed makes `update!` raise, which is a 500 today, and the event rows already created roll back with the transaction only because the exception escapes.
- **Fix:** rescue `ActiveRecord::RecordInvalid` outside `with_lock`, so the transaction still rolls back, and answer 422 with the card's existing "Those sections can't be set aside." Log the error class only. A request spec stores an unloadable zone with `update_column`, dismisses, and checks for 422, no event row and unchanged cutoffs.

### Suggestions no longer depend on the track (item 9)

- `User#suggests_level_moves?` is `level_suggestions?`. Nothing reads `learning_track` for suggestions.
- The dismissal and answer controllers lose their track checks. The answer endpoint counts for every account. Its "the track just ended, return without counting" branch goes, since suggestions continue.
- `ApiKeysController#suggested_kinds` loses its track check. `suggested_level` is still checked against `LADDER`.
- After this, the track decides only the first-run preset, the key guide for a track account with no exercises, and the on-track line and Leave on Setup.

### Setup

- **The switch** moves out of `api_keys/_learning_track` to the top of the Exercise mix, for every account, with id `level-suggestions`. It gets its own small Stimulus controller, `level-suggestions-switch`, holding the `toggleSuggestions` code that `learning_track_controller.js` has now. The Exercise mix controller owns the versioned preference save, and this switch doesn't bump the version, so keeping them apart keeps the 409 logic unchanged.
- **Reaching it from the card (decision C).** The Exercise mix is a closed `<details>`. Whether a fragment link opens a closed `<details>` varies by browser (**Inferred**). The card's "Turn these suggestions off in Setup" link adds `?show=level_suggestions`, and Setup renders the mix `open` for it, as it already does for `suggested[]`.
- `_learning_track` keeps the on-track line and Leave, with copy that no longer ties suggestions to the track (below).

### Performance

The submitted dashboard now runs `LevelSuggestion::Evidence` for every account with suggestions on: up to 60 submitted responses with their exercises preloaded. Today only track accounts pay it. **Inferred** to be in the range `SizeForecast` measured for the same shape of read (15 ms at 60 reviewed days). The PR will time it the same way and report the number.

## Copy

All new and changed strings follow the plain-language standard and name no tier.

| Key | Now | Proposed |
|---|---|---|
| `api_keys.edit.skill_level_hint` | "How hard your sections start out, unless you've set a difficulty for that section in the Exercise mix below. Junior suits early-career developers and career changers. Your ratings still nudge each day's set up or down." | "The level each section uses unless you set one for it in the Exercise mix below. Junior suits early-career developers and career changers. Your ratings nudge each day's set, but this setting changes only when you change it. When your reviews show a section is ready to move, Code Gym suggests a level for that section, and you decide." |
| `level_suggestion.setup.suggestions_label` (moved) | "Suggest level changes" | unchanged |
| `level_suggestion.setup.suggestions_hint` (moved) | "When this is off, the dashboard stops suggesting level changes. You can still change levels yourself in Exercise mix, and turn this back on at any time." | "When this is off, the dashboard stops suggesting level changes. You can still change levels yourself below, and turn this back on at any time." |
| `learning_track.setup.on_track` | "You're on the junior track. Code Gym suggests moving each kind of exercise up as your reviews show you're ready." | "You're on the junior track, so every kind of exercise started at junior." |
| `learning_track.setup.leave_hint` | "Your current difficulty settings stay as they are. You can't rejoin the track afterwards." | "Your difficulty settings and level suggestions stay as they are. You can't rejoin the track afterwards." |
| card footer link | anchor `learning-track` | `setup_path(show: "level_suggestions", anchor: "level-suggestions")` |

The card's own wording (#390) is unchanged apart from its key names.

## Test plan

TDD per piece; the scoped spec during each step, the unit suite at the end, then `spec/system`.

**Rename commits:** the existing suite, unchanged apart from names. A spec pins the welcome level step to `LevelSuggestion::LADDER`.

**Old paths** (`spec/requests/level_suggestion_legacy_paths_spec.rb`): `POST /learning_track/dismissal` and `/learning_track/answer` reach the new controllers and return the same JSON, with no redirect. `PATCH /profile` with `track_suggestions: false` turns `level_suggestions` off; a non-boolean is a 422.

**Migration** (`spec/migrations/add_level_suggestion_columns_to_users_spec.rb`, the existing migration-spec pattern):
- backfill copies `track_suggestions` false and true, and a cutoffs map, row for row;
- an account with defaults reads `true` and `{}`;
- `down` removes both columns and leaves `track_*` as they were;
- `User` no longer exposes the ignored columns.

**`record_level_changes`** (`spec/models/user_level_changes_spec.rb`, for an account off the track unless stated):
- a target edit through `PATCH /profile` records `{level: new rung, through: today}`;
- Apply records it for that kind only;
- a skill-level change records it for every untargeted kind and none of the targeted ones;
- clearing a target records the skill-level rung;
- no cutoff when the rung is unchanged (the same target re-saved; a target equal to the skill level; a skill-level change for a targeted kind);
- the junior→mid→junior round trip: the junior cutoff is today's, so junior results from before the first move never count again, and a stale entry at another level is replaced;
- a move to principal engineer records nothing;
- a save that changes `learning_track` records nothing (the welcome junior preset and the Experienced level).

**Rule over rungs** (`spec/services/level_suggestion_spec.rb`): an untargeted kind at the skill level is a candidate; its cutoff counts only at that rung; a targeted kind's target wins over the skill level; principal is never a candidate.

**Apply without targets** (request): one target written for the kind, `skill_level` unchanged, other kinds still untargeted.

**Posted steps** (request): `from` not the current rung → 409 and nothing saved (the stale-card case: skill level changed in another tab); `to` not adjacent or not the saved level → 422; a matching step labels the row `suggestion` with the shown `to_level`; an edit with no step is `setup_edit`; a Setup save opened from the card's link labels a matching edit `suggestion`.

**Events:** skill-level change writes one `setup_edit` row per moved kind; dismissal rows store the shown `to_level`; nothing written on a dashboard render.

**Dismissal 422:** every kind × reason builds a valid row; an unloadable stored zone gives 422 with no partial write.

**Every account and the track ending:** a non-track account sees the card, Apply, Not now, the answer count and the Setup highlights; a track account whose kinds all reach senior leaves the track and still sees a step-back; a nil-track legacy account behaves the same.

**Setup:** the switch renders for every account inside the mix; `?show=level_suggestions` opens the mix; the moved hint copy.

**Isolation** (`spec/services/learning_track_isolation_spec.rb`, renamed to `level_suggestion_isolation_spec.rb`):
- **Text search, stricter.** The file list stays (`app/{services,jobs}`, `concept_mastery.rb`, `judge_verdict.rb`, `review_prose_verdict.rb`, `kind_difficulty.rb`). The pattern becomes `learning_track|LearningTrack|level_suggestion|LevelSuggestion|track_evidence_cutoffs|track_suggestions|track_proposals_answered|TrackGraduation`. The only exemptions are `app/services/level_suggestion.rb` and `app/services/level_suggestion/evidence.rb`. So generation, review, both judges, `ConceptMastery` and `KindDifficulty` can name neither the track nor suggestion state.
- **Byte-identical prompts, wider.** The twins gain an off-track account with suggestions off and a cutoffs map set. All must send the same generation and judge calls as the baseline. The cutoffs fixture moves from `track_evidence_cutoffs` to `level_suggestion_cutoffs`; no assertion weakens.

**System:** the renamed `level_suggestion_spec.rb` and `level_suggestion_controls_spec.rb` cover a non-track account's card and the switch in its new place.

## Snapshot counts

Counted by reading the fixtures on bcbfad6, which carry #391's re-recorded pages. Final numbers are confirmed by running.

- **Prompt snapshots: 0 of 72.** No prompt code changes. **Verified:** no file in `spec/fixtures/prompt_snapshots` mentions suggestions, tracks or cutoffs. **Inferred:** the run will match.
- **Request snapshots: 0 of 15.** Same reasoning and check, on `spec/fixtures/request_snapshots`.
- **Page snapshots: 5 of 5**, which differs from the original plan's 1 of 5.
  - **All five, importmap only (Verified):** every page lists every Stimulus controller with its digest, and all five list `track_proposal_controller` and `learning_track_controller` (lines 37/51 and 76/90; 38/52 and 77/91 in `setup.html`). Renaming one, editing the other, and adding `level_suggestions_switch_controller` changes the import map and preload lines on every page.
  - **`setup.html` also changes in its body:** the switch inside the Exercise mix and the skill-level hint (line 660).
  - **`dashboard_submitted.html` keeps its body (Inferred):** the snapshot's review has no rubric stamp and its sections no `pitched_at` (**Verified**, `existing_account_pages_spec.rb:25-46`), so there is no evidence and no card.
  - `account`, `history` and `dashboard_unsubmitted` change only in the import map.

## Commits

1. This spec (its own commit, done on this branch).
2. Rename: `TrackGraduation` → `LevelSuggestion` with `Evidence`, `ai_favourable?`, `IN_PLACE_ANSWERS`, specs and code notes.
3. Rename: partial, Stimulus controller, locale keys, user predicates; page snapshots re-recorded (import map only).
4. Rename: controllers and routes, with the old paths routed to the new controllers; legacy-path request spec.
5. Migration, `ignored_columns`, the `track_suggestions` param alias; migration spec.
6. Rungs instead of targets in the rule, dismissal and events.
7. `record_level_changes` for every account, including skill-level changes.
8. Posted steps: the stale-card 409, event labels from what was shown, Setup's highlighted edits.
9. Suggestions for every account, without the track.
10. Dismissal 422.
11. Setup: the switch move, the `show` param, hint and track copy; `setup.html` re-recorded.
12. Stricter isolation spec.
13. CLAUDE.md ("Junior learning track" becomes "Level suggestions" plus a shorter track section; the File Map) and code notes.

## Files touched

About 55.

- **Renamed (with specs and code notes):** `app/services/track_graduation.rb`, `track_graduation/evidence.rb`, both dismissal and answer controllers, `dashboard/_track_proposal.html.erb`, `track_proposal_controller.js`, `spec/services/track_graduation_spec.rb`, `track_graduation/evidence_spec.rb`, `spec/requests/track_proposal_spec.rb`, `track_suggestion_controls_spec.rb`, `learning_track_dismissals_spec.rb`, `spec/system/track_proposal_spec.rb`, `track_suggestion_controls_spec.rb`, `learning_track_isolation_spec.rb`.
- **New:** the migration and its spec, `level_suggestions_switch_controller.js` and its code note, `spec/requests/level_suggestion_legacy_paths_spec.rb`.
- **Edited:** `app/models/user.rb`, `learning_track.rb`, `level_suggestion_event.rb`, `profile_controller.rb`, `api_keys_controller.rb`, `dashboard_controller.rb`, `config/routes.rb`, `config/locales/en.yml`, `api_keys/edit.html.erb`, `api_keys/_learning_track.html.erb`, `dashboard/_exercise.html.erb`, `welcome/show.html.erb` (one constant), `spec/requests/welcome_spec.rb`, `learning_track_controller.js`, `exercise_mix_controller.js`, `db/schema.rb`, `spec/models/user_level_changes_spec.rb`, `user_learning_track_spec.rb`, `level_suggestion_event_spec.rb`, `spec/db/one_result_per_kind_per_day_spec.rb`, `spec/requests/profile_learning_track_spec.rb`, `security_audit/cross_user_access_spec.rb`, the 5 page snapshots, `CLAUDE.md`, and code notes for `user`, `level_suggestion_event`, `profile_controller`, `system_test_helper`.

## Riskiest piece

**`record_level_changes` over rungs, together with the posted-step check.** It now runs on every skill-level change as well as every target change, for every account, and decides which results count toward the next suggestion. A mistake hides evidence silently (a cutoff written when the rung didn't move) or brings back results the user already acted on (a cutoff missed on a cleared target). The posted-step check sits inside the profile save's lock, so a wrong comparison either refuses a valid Apply with a 409 loop or lets a stale card through. The specs above target each of those shapes.

Second: `ignored_columns`. Anything still assigning a `track_*` column raises at runtime. Before pushing, a grep for both names outside migrations and this PR's alias must come back empty.

## Decisions for you (recommendation first)

- **A. Event accuracy.** The card and Setup post the steps they showed, and the server checks them under the lock. This also fixes the stale-card step-down. Alternative: document the three limits in the code note and leave the stale-card bug open.
- **B. Skill-level changes in the event table.** One `setup_edit` row per kind whose rung moved. Alternatives: no rows, or a new `source: skill_level`.
- **C. Card link to the switch.** `?show=level_suggestions` opens the Exercise mix. Alternative: a fragment link alone, which may land on a closed `<details>`.
- **D. Leave the track.** Keep it, with the hint saying suggestions continue. After this PR it changes only Setup's on-track line and the key guide; removing it is a separate decision.
- **E. `track_proposals_answered`.** Keep the name in this PR; rename it with the column drop if you want the names to match.

# Level suggestions for every account (PR 2)

Plan only. Read on `origin/main` at **bcbfad6**, with #390 and #391 both merged. Every claim is marked **Verified** (read in the code or fixtures named) or **Inferred** (follows from what was read, but not run).

This plan follows `2026-10-14-level-suggestions.md` ("PR 2" and "Changes requested at review") except where the request for this PR overrides it. The decisions at the end were made at review on 2026-10-15.

## What changes for a person

- Every account gets level suggestions on the submitted dashboard, not just junior-track accounts. The rule is the one #390 shipped: one rung at a time along junior, mid-level and senior, from each kind's own reviewed results.
- Accepting a suggestion sets that one kind's level. The account's skill level stays where it was.
- The "Suggest level changes" switch moves into Setup's Exercise mix, where every account can find it.
- A junior-track account whose kinds all reach senior keeps getting suggestions, step-backs included.
- Nothing is generated or graded differently. Suggestions are computed from stored results and only shown.

## Starting conditions

1. **#391 has merged (bcbfad6).** Its welcome view renders the level step from `TrackGraduation::LADDER` (**Verified**, `app/views/welcome/show.html.erb:36`). `TRACK_CHOICE_KEYS[OFF]` now allows `skill_level` (**Verified**, `profile_controller.rb:163`). The rename below changes the welcome view's constant, and #391's `welcome_spec.rb` and `profile_learning_track_spec.rb` move with it.
2. **`WelcomeController::STARTING_LEVELS` does not exist, so there is nothing to replace (Verified).** `git grep STARTING_LEVELS origin/main` finds nothing. #391 reads the ladder constant directly, so the welcome levels and the suggestion ladder are already one list. The rename commit changes that one reference to `LevelSuggestion::LADDER`, and a spec pins that the welcome step offers exactly `LevelSuggestion::LADDER`.
3. **The Experienced hint is not touched.** #391 replaced it.

## Design

### Rungs, not targets

Today the rule reads `user.section_kind_levels`, the targets, and skips any kind without one (**Verified**, `track_graduation.rb:21` and `:74`). A track account has a target for every kind, so that worked. Most accounts have none.

`LevelSuggestion.for(user)` reads each kind's **rung** instead: `KindDifficulty#rung_for(kind, skill_level:)`, the target when set, else the skill level. That is the same reading generation uses, so the card never proposes moving a kind from a level it isn't at. Everything that keyed on the target moves to the rung:

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

`config/routes.rb` keeps `POST /learning_track/dismissal` and `/learning_track/answer` routed straight to the new controllers, each under a bare route annotation, with a one-line note naming the PR that removes them. They aren't redirects, because `code_gym/request.js` treats a followed redirect as a signed-out session (**Verified**, `request.js:35-36`). They're removed in the same later PR that drops the ignored columns.

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

- `User.ignored_columns += %w[track_suggestions track_evidence_cutoffs]`, following the `api_key` precedent (`f63594b`, **Verified**). A later PR drops them.
- `track_proposals_answered` keeps its name (decision F). Only `User`, the answer controller and the card read it.
- The backfill copies every row, so an account that turned suggestions off on the track stays off, and every other account reads `true`, the column's default.
- `level_suggestion_events.source` is a plain nullable string with no database constraint (**Verified**, `db/schema.rb:144`), so the new `skill_level_edit` value (decision C) needs no migration.

**Rollback.**
- `down` drops the two new columns. The migration never wrote the old columns, so old code runs unchanged against them.
- Rolling back code without the migration also works: old code never reads the new columns.
- A rolled-back release doesn't choke on stored `skill_level_edit` rows. Model validations run only on writes, and nothing in the app reads `source` back (**Inferred**: the event table has no reader).
- **Two accepted windows.** A dismissal or level change written by old code after the migration runs but before new code serves is not copied, so it costs one repeat offer. And after a code rollback, old code reads `track_*` values that miss anything new code wrote, with the same cost. Both are limited to a re-offer the user can dismiss again.

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

This only becomes possible once kinds without targets get suggestions, so it belongs to this PR. Decision B fixes it.

### Event accuracy (decision B): the card posts what it showed, and the server checks `from` first

- Apply and the Setup save send `level_suggestion: { steps: [{ kind, from, to }, …] }` beside the levels.
- **`from` is checked against the stored level before anything is saved.** In `ProfileController#save_with_preference_precondition`, inside the existing `with_lock` and after the version check, every step's `from` is compared with the kind's current rung, as read from the row the lock just loaded: `KindDifficulty#rung_for` over the stored targets and the stored skill level. Any mismatch refuses the whole request with the existing **409 stale** body, and nothing is assigned or saved. The card already handles 409 by reloading once other saves finish, so the person sees the current suggestion, or none.
- After that check, `to` must be one rung from `from` on `LADDER` and must equal the level this request saves for that kind. Otherwise it's a **422**, and nothing is saved.
- The checked steps reach the model through an attribute the event callback reads. A rung change that matches a checked step is `source: suggestion` with the `to_level` the card showed.
- The dismissal request already sends kinds and a reason. It gains each kind's displayed `from` and `to`. Inside the dismissal's `with_lock`, `from` is compared with the stored rung first: 409 on a mismatch, with no cutoff and no event row written. Then `to` must be one rung away, or it's a 422. The row stores the displayed `to_level`.
- **Setup:** when Setup was opened from the card's link (`suggested[]` and `suggested_level`), the Exercise mix sends a step for a highlighted kind whose new level equals the suggested one, so it goes through the same checks. After three answers, when acceptance happens in Setup, those edits are still labelled `suggestion`. Setup renders each highlighted kind's current rung into the page as that step's `from`.
- The evidence counts on each row are still computed by the server at write time. They can differ from the card's numbers when a review lands in between. The code note says so.

What this fixes, from the three cases named in the request:

| Case | Today | With posted steps |
|---|---|---|
| A review lands between render and Apply | label and `to_level` come from a new proposal | label and `to_level` are what the card showed |
| A kind removed after Apply | `to_level` recomputed from the post-Apply proposal, often nil | the `to` the card showed |
| A Setup edit on an unsubmitted day matches a pending proposal | labelled `suggestion` | `setup_edit`, since no card was shown |
| The skill level changed in another tab (above) | a step down saved and labelled `suggestion` | 409, nothing saved |

Trust: a client can still post a step that matches a real one-rung move and label its own edit `suggestion`. That only mislabels the account's own analytics row; the move itself is one the user could make in Setup anyway.

Cost: the server no longer recomputes a proposal on every level-changing save. It still runs the evidence query once for the counts.

### Event sources (decision C): skill-level moves have their own source

`LevelSuggestionEvent::SOURCES` becomes `suggestion`, `setup_edit` and `skill_level_edit`. Each applied row's source comes from what moved that kind's rung in this save:

- **`suggestion`:** the kind's target changed, and the change matches a checked posted step.
- **`setup_edit`:** the kind's target changed (set, edited or cleared), with no matching step.
- **`skill_level_edit`:** the kind's target did not change, and its rung moved because `skill_level` changed. A skill-level change writes one such row per untargeted kind whose rung moved, so a bulk move can be found by `source` and grouped by `created_at`.

The rule is decided per kind, so a single request that changes both a target and the skill level labels each kind by its own cause. Setup sends them separately today, so this only matters for completeness. `from_level` and `to_level` are the rungs before and after, never raw targets, so a `skill_level_edit` row reads the same way as the others. The model validation (`source` present on applied rows, absent otherwise) is unchanged apart from the list.

### Dismissal endpoint: 422, never 500

`create!` and `update!` run inside `with_lock` (**Verified**, `learning_track_dismissals_controller.rb:29-35`).

- **The event rows can't be invalid.** `kind` is checked against `ExerciseSection.keys` before the write, `action` comes from a closed map, and `source` is nil for both dismissal actions. A spec builds every kind × reason and asserts each row is `valid?`.
- **The user row can be.** `update!` runs every unconditional `User` validation, including `time_zone_must_be_loadable` (**Verified**, `user.rb:33`). A stored zone that a tzdata update removed makes `update!` raise, which is a 500 today.
- **Fix:** rescue `ActiveRecord::RecordInvalid` outside `with_lock`, so the transaction rolls back, and answer 422 with the card's existing "Those sections can't be set aside." Log the error class only. A request spec stores an unloadable zone with `update_column`, dismisses, and checks for 422, no event row and unchanged cutoffs.

### Suggestions no longer depend on the track (item 9)

- `User#suggests_level_moves?` is `level_suggestions?`. Nothing reads `learning_track` for suggestions.
- The dismissal and answer controllers lose their track checks (**Verified**, the three `on_learning_track?` guards at `learning_track_dismissals_controller.rb:6,23` and `learning_track_answers_controller.rb:5`). The answer endpoint counts for every account. Its "the track just ended, return without counting" branch goes, since suggestions continue.
- `ApiKeysController#suggested_kinds` loses its track check (**Verified**, `api_keys_controller.rb:39`). `suggested_level` is still checked against `LADDER`.

### What the track still does after this PR (decision E)

After this PR, `learning_track` is read in only these places (**Verified** by `git grep on_learning_track?` on bcbfad6, less the guards removed above):

- the first-run choice and its validation (`learning_track_change_allowed?`, `ProfileController::TRACK_CHOICE_KEYS`);
- `finish_learning_track`;
- Setup's on-track line and Leave button (`api_keys/edit.html.erb:124`);
- Setup's API key guide for a track account with no exercises yet (`api_keys/edit.html.erb:43`).

**So Leave changes nothing about suggestions.** It removes the on-track line and the Leave button. It also does one thing more than the request assumed: for a track account that has no exercises yet, Setup stops showing the API key guide. `learning_track_controller.js` already removes the guide in place on Leave, and an account in that state still has the ordinary key field. The plan keeps that behavior and states it in CLAUDE.md, rather than saying Leave only removes the line. The Leave hint says suggestions continue.

### Setup

- **The switch** moves out of `api_keys/_learning_track` to the top of the Exercise mix, for every account, with id `level-suggestions`. It gets its own small Stimulus controller, `level-suggestions-switch`, holding the `toggleSuggestions` code that `learning_track_controller.js` has now. The Exercise mix controller owns the versioned preference save, and this switch doesn't bump the version, so keeping them apart leaves the 409 logic unchanged.
- **Reaching it from the card (decision D).** The card's "Turn these suggestions off in Setup" link is `setup_path(show: "level_suggestions", anchor: "level-suggestions")`.
  - `ApiKeysController#show_level_suggestions?` is true only when `params[:show]` is exactly `"level_suggestions"`. Any other value is ignored.
  - When it's true, the server renders the Exercise mix `<details>` with `open`, as it already does for `suggested[]`, and gives the switch's wrapper `data-level-suggestions-switch-focus-value="true"`. Without the parameter, neither attribute is rendered, so the page is unchanged.
  - On `connect()`, the controller sees that value, calls `scrollIntoView({ block: "center" })` on the switch, and moves focus to its checkbox, the control the link was about. The server decides that the switch should take focus, and the script only acts on that.
  - The anchor stays, so the browser lands near the switch before the script runs.
  - Instant scrolling, the browser's default, needs no reduced-motion handling.
- `_learning_track` keeps the on-track line and Leave, with copy that no longer ties suggestions to the track (below).

### Performance

The submitted dashboard now runs `LevelSuggestion::Evidence` for every account with suggestions on: up to 60 submitted responses with their exercises preloaded. Today only track accounts pay it. **Inferred** to be in the range `SizeForecast` measured for the same kind of read (15 ms at 60 reviewed days). The PR will time it the same way and report the number.

## Copy

All new and changed strings follow the plain-language standard and name no tier.

| Key | Now | Proposed |
|---|---|---|
| `api_keys.edit.skill_level_hint` | "How hard your sections start out, unless you've set a difficulty for that section in the Exercise mix below. Junior suits early-career developers and career changers. Your ratings still nudge each day's set up or down." | "The level each section uses unless you set one for it in the Exercise mix below. Junior suits early-career developers and career changers. Your ratings nudge each day's set, but this setting changes only when you change it. When your reviews show a section is ready to move, Code Gym suggests a level for that section, and you decide." |
| `level_suggestion.setup.suggestions_label` (moved) | "Suggest level changes" | unchanged |
| `level_suggestion.setup.suggestions_hint` (moved) | "When this is off, the dashboard stops suggesting level changes. You can still change levels yourself in Exercise mix, and turn this back on at any time." | "When this is off, the dashboard stops suggesting level changes. You can still change levels yourself below, and turn this back on at any time." |
| `learning_track.setup.on_track` | "You're on the junior track. Code Gym suggests moving each kind of exercise up as your reviews show you're ready." | "You're on the junior track, so every kind of exercise started at junior." |
| `learning_track.setup.leave_hint` | "Your current difficulty settings stay as they are. You can't rejoin the track afterwards." | "Your difficulty settings and level suggestions stay as they are. You can't rejoin the track afterwards." |

The card's own wording (#390) is unchanged apart from its key names.

## Test plan

Each piece is built test-first. Run the scoped spec during each step, the unit suite at the end, then `spec/system`.

**Rename commits:** the existing suite, unchanged apart from names. A spec pins the welcome level step to `LevelSuggestion::LADDER`.

**Old paths** (`spec/requests/level_suggestion_legacy_paths_spec.rb`):
- `POST /learning_track/dismissal` and `/learning_track/answer` reach the new controllers and return the same JSON, with no redirect.
- `PATCH /profile` with `track_suggestions: false` turns `level_suggestions` off; a non-boolean is a 422.

**Migration** (`spec/migrations/add_level_suggestion_columns_to_users_spec.rb`, the existing migration-spec pattern):
- the backfill copies `track_suggestions` (false and true) and a cutoffs map, row for row;
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

**Rule over rungs** (`spec/services/level_suggestion_spec.rb`):
- an untargeted kind at the skill level is a candidate;
- its cutoff counts only at that rung;
- a targeted kind's target wins over the skill level;
- principal is never a candidate.

**Apply without targets** (request): one target is written for the kind, `skill_level` is unchanged, and other kinds stay untargeted.

**Posted steps** (request):
- a `from` that doesn't match the stored rung gets 409, and neither targets, cutoffs nor event rows change. This covers the stale-card case: the skill level changed through `PATCH /profile` after the card rendered.
- one mismatched step among several refuses the whole request;
- the `from` check runs after the version check, so a stale version still gets the existing 409;
- a `to` that isn't one rung away, or isn't the saved level, gets 422 with nothing saved;
- a matching step labels the row `suggestion` with the shown `to_level`;
- an edit with no step is `setup_edit`;
- a Setup save opened from the card's link labels a matching edit `suggestion`;
- dismissal: a mismatched `from` gets 409 with no cutoff or event row, and a matching one stores the shown `to_level`.

**Event sources:**
- a skill-level change writes one `skill_level_edit` row per untargeted kind whose rung moved, and none for targeted kinds;
- a target edit writes `setup_edit`;
- one request changing both writes each kind under its own cause;
- `LevelSuggestionEvent` accepts `skill_level_edit` only on applied rows;
- nothing is written on a dashboard render.

**Dismissal 422:** every kind × reason builds a valid row; an unloadable stored zone gives 422 with no partial write.

**Every account and the track ending:**
- a non-track account sees the card and can use Apply, Not now, the answer count and the Setup highlights;
- a track account whose kinds all reach senior leaves the track and still sees a step-back;
- a legacy account with no track set behaves the same;
- Leave changes no suggestion output: the same proposal before and after.

**Setup:**
- the switch renders for every account inside the mix;
- `?show=level_suggestions` renders the mix `open` and the focus value;
- any other `show` value, or none, renders neither;
- the moved and rewritten copy.

**Isolation** (`spec/services/learning_track_isolation_spec.rb`, renamed to `level_suggestion_isolation_spec.rb`):
- **Text search, stricter.** The file list stays the same: `app/{services,jobs}`, `concept_mastery.rb`, `judge_verdict.rb`, `review_prose_verdict.rb` and `kind_difficulty.rb`. The pattern becomes `learning_track|LearningTrack|level_suggestion|LevelSuggestion|track_evidence_cutoffs|track_suggestions|track_proposals_answered|TrackGraduation`. The only exemptions are `app/services/level_suggestion.rb` and `app/services/level_suggestion/evidence.rb`. So generation, review, both judges, `ConceptMastery` and `KindDifficulty` can name neither the track nor suggestion state.
- **Byte-identical prompts, wider.** The twins gain an off-track account with suggestions off and a cutoffs map set. All must send the same generation and judge calls as the baseline. The cutoffs fixture moves from `track_evidence_cutoffs` to `level_suggestion_cutoffs`; no assertion is weakened.

**System:**
- `level_suggestion_spec.rb` (renamed) covers a non-track account's card, Apply and Not now.
- `level_suggestion_controls_spec.rb` (renamed) covers the switch in its new place.
- Following the card's Setup link lands with the mix open and `document.activeElement` on the switch's checkbox; loading Setup without the parameter leaves focus where the page puts it.

## Snapshot counts

Counted by reading the fixtures on bcbfad6, which already include #391's re-recorded pages. Final numbers are confirmed by running.

- **Prompt snapshots: 0 of 72.** No prompt code changes. **Verified:** no file in `spec/fixtures/prompt_snapshots` mentions suggestions, tracks or cutoffs. **Inferred:** the run will match.
- **Request snapshots: 0 of 15.** Same reasoning and check, on `spec/fixtures/request_snapshots`.
- **Page snapshots: 5 of 5**, which differs from the original plan's 1 of 5.
  - **All five change in the import map only (Verified):** every page lists every Stimulus controller with its digest, and all five list `track_proposal_controller` and `learning_track_controller` (lines 37/51 and 76/90; 38/52 and 77/91 in `setup.html`). Renaming one, editing the other, and adding `level_suggestions_switch_controller` changes the import map and preload lines on every page.
  - **`setup.html` also changes in its body:** the switch inside the Exercise mix, and the skill-level hint (line 660). The snapshot request carries no `show` parameter, so the mix stays closed and no focus value is rendered (decision D adds nothing to the snapshot).
  - **`dashboard_submitted.html` keeps its body (Inferred):** the snapshot's review has no rubric stamp and its sections no `pitched_at` (**Verified**, `existing_account_pages_spec.rb:25-46`), so there is no evidence and no card.
  - `account`, `history` and `dashboard_unsubmitted` change only in the import map.

## Commits

1. This spec (its own commits, already on this branch).
2. Rename: `TrackGraduation` → `LevelSuggestion` with `Evidence`, `ai_favourable?`, `IN_PLACE_ANSWERS`, specs and code notes.
3. Rename: partial, Stimulus controller, locale keys, user predicates; page snapshots re-recorded (import map only).
4. Rename: controllers and routes, with the old paths routed to the new controllers; legacy-path request spec.
5. Migration, `ignored_columns`, the `track_suggestions` param alias; migration spec.
6. Rungs instead of targets in the rule, dismissal and events.
7. `record_level_changes` for every account, including skill-level changes.
8. Posted steps: the stored-`from` check and its 409, the `to` check, event labels from what was shown, Setup's highlighted edits.
9. The `skill_level_edit` source.
10. Suggestions for every account, without the track.
11. Dismissal 422.
12. Setup: the switch move, the `show` parameter with server-rendered open and focus, hint and track copy; `setup.html` re-recorded.
13. Stricter isolation spec.
14. CLAUDE.md ("Junior learning track" becomes "Level suggestions" plus a shorter track section that states what Leave does; the File Map) and code notes.

## Files touched

About 57.

- **Renamed (with specs and code notes):**
  - `app/services/track_graduation.rb`, `track_graduation/evidence.rb`
  - both dismissal and answer controllers
  - `dashboard/_track_proposal.html.erb`, `track_proposal_controller.js`
  - `spec/services/track_graduation_spec.rb`, `track_graduation/evidence_spec.rb`, `learning_track_isolation_spec.rb`
  - `spec/requests/track_proposal_spec.rb`, `track_suggestion_controls_spec.rb`, `learning_track_dismissals_spec.rb`
  - `spec/system/track_proposal_spec.rb`, `track_suggestion_controls_spec.rb`
- **New:**
  - the migration and its spec
  - `level_suggestions_switch_controller.js` and its code note
  - `spec/requests/level_suggestion_legacy_paths_spec.rb`
- **Edited:**
  - models: `app/models/user.rb`, `learning_track.rb`, `level_suggestion_event.rb`
  - controllers: `profile_controller.rb`, `api_keys_controller.rb`, `dashboard_controller.rb`
  - views: `api_keys/edit.html.erb`, `api_keys/_learning_track.html.erb`, `dashboard/_exercise.html.erb`, `welcome/show.html.erb` (one constant)
  - scripts: `learning_track_controller.js`, `exercise_mix_controller.js`
  - config and schema: `config/routes.rb`, `config/locales/en.yml`, `db/schema.rb`
  - specs: `spec/models/user_level_changes_spec.rb`, `user_learning_track_spec.rb`, `level_suggestion_event_spec.rb`, `spec/db/one_result_per_kind_per_day_spec.rb`, `spec/requests/profile_learning_track_spec.rb`, `welcome_spec.rb`, `security_audit/cross_user_access_spec.rb`
  - the 5 page snapshots
  - `CLAUDE.md`, and the code notes for `user`, `level_suggestion_event`, `profile_controller` and `system_test_helper`

## Riskiest piece

**`record_level_changes` over rungs, together with the posted-step check.**

- The cutoff recording now runs on every skill-level and target change, for every account, and decides which results count toward the next suggestion. A mistake hides evidence silently (a cutoff written when the rung didn't move), or brings back results the user already acted on (a cutoff missed on a cleared target).
- The `from` check sits inside the profile save's lock, after the version check. If it compares against the wrong value (the posted levels instead of the stored ones, or the target instead of the rung), it either refuses a valid Apply in a 409 loop or lets a stale card through.

The specs above target each of those cases.

Second: `ignored_columns`. Anything still assigning a `track_*` column raises at runtime. Before pushing, a grep for both names outside migrations and this PR's alias must come back empty.

## Decisions (made at review, 2026-10-15)

- **B. Event accuracy:** the card and Setup post the steps they showed. The server checks each step's `from` against the stored rung under the row lock before anything is saved, and refuses a mismatch with 409.
- **C. Skill-level changes in the event table:** one applied row per kind whose rung moved, with their own source, `skill_level_edit`, separate from per-kind `setup_edit` rows.
- **D. Card link to the switch:** `?show=level_suggestions` makes the server render the Exercise mix open, and the switch's controller scrolls to the switch and focuses it.
- **E. Leave the track:** kept. After this PR it changes nothing about suggestions. It removes the on-track line and the Leave button, and, for a track account that hasn't generated a set yet, Setup's API key guide. The hint says suggestions continue.
- **F. `track_proposals_answered`:** keeps its name in this PR.

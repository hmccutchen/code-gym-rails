# Tracks per level

Read on `origin/main` at **9ecd83b**. This plan covers PR 2 (every kind's level in the prompt) and PR 1 (tracks per level) in full, then PRs 3–5 in brief.

**Status.** PR 2 is implemented in the same pull request as this plan, and merges and deploys on its own before PR 1. PR 1 below is the revised plan, waiting for review: it adds the target-clearing rule to every track change.

## Decisions this plan follows

- **1b.** Presets are no longer written. The generation prompt's difficulty block covers every kind, not only targeted ones.
- **2.** `skill_level` is the track. `learning_track` stops carrying meaning.
- **3c.** `RUBRIC_VERSION` is not raised. The grader change lands before graduation reads ratings.
- **4.** Graduation needs 4 of the next level's areas, each with 2 of its latest 3 results at the current level solid, plus both daily kinds meeting the per-kind step-up rule.
- **5a.** Principal engineer is set by hand in Setup. Senior is the highest track graduation reaches, and the copy and CLAUDE.md say so.
- **6.** The per-kind evidence read stays at the latest 60 responses.
- "Leave the track" is removed. Graduation follows the "Suggest level changes" switch.
- The target-clearing table from the investigation stands as written, and applies to every track change, by hand in Setup as well as by graduation.
- **Q1** yes: ladder preparation follows every section's level. **Q2**: senior needs all but one reachable area. **Q3**: a mixed-language account covers an area in either language. **Q4**: graduation reads only reviews dated after PR 4 shipped.

## Sequencing

**Decided: PR 2 merges and deploys on its own first.** PR 1 runs no data migration of targets. Existing targets change only when the track changes, through the rule in PR 1's scope item 10.

- **PR 2 first.** It makes a target that equals the skill level render byte-identically to no target. After it, a junior preset and "no target at skill level junior" send the same generation and judge calls, and a spec pins that. PR 1 can then stop writing presets without any account's prompt changing.
- **PR 1 runs no target migration.** Existing preset targets stay, and after PR 2 they no longer change anything in a prompt. They matter again only when the track moves, and every track change, by hand or by graduation, then clears the unlocked ones equal to the old or new level.

Why not ship both in one deploy: PR 2 changes every account's prompt and all 72 prompt snapshots, while PR 1 changes onboarding and Setup. Separate deploys keep each rollback independent. The only ordering risk is a new junior-track account created under PR 1 before PR 2 is live, which would get the weaker prompt. Merging PR 2 first removes that risk.

---

## PR 2: every kind's level in the generation prompt

### Scope

1. **The difficulty block covers every kind.**
   - `AiService#kind_difficulty_guidance` takes each kind's rung (`KindDifficulty#rung_for`: the target, else the skill level) instead of filtering to `targeted_kinds`.
   - A kind renders the same way whether its rung comes from a target or from the skill level.
   - The lock lines stay as they are: only a targeted, locked kind is listed as locked. The unlocked line lists every other kind.
2. **The block's opening line is rewritten** so it holds whether or not a kind has a target. Today's line, "its level replaces the skill level in the engineer profile above", would be false for a kind with no target. Proposed:
   > Difficulty by section. Pitch each section named below at its level; where it differs from the skill level in the engineer profile above, the section's level wins.
3. **Ladders follow the rung.** `ladders_for` and `kind_difficulty_diagnostics` read every kind at its rung. `ladders_for` needs the skill level, so `draft_exercise` passes the rungs it already computes. `build_exercise_prompt` already holds `rungs` (`ai_service.rb:1192`) and passes them on.
4. **The diagnostics line** `[difficulty_diagnostics]` gains `targeted: true|false` per kind, so a log reader can still tell a set target from a followed skill level. Logs are not prompts.
5. **Learn and Setup ladder preparation follow the rung** (see open question Q1).
   - `ExerciseMixLadders#ladder_preparation`, `LearnController#prepare_ladders` and `#ladder_targets_for` read every kind at its rung instead of `targeted_kinds`.
   - `LadderCoverage.for` hands `ConceptHosts` a `KindDifficulty` built from `user.kind_rungs`, so an untargeted kind is counted at the skill level rather than as the union of every rung.
   - Without this, a junior-track account loses Setup's "Prepare AI guidance" control once PR 1 stops writing presets, although its prompt now uses those ladders.

### Files

- `app/services/ai_service.rb`: `kind_difficulty_guidance`, `level_difficulty_paragraph` (unchanged body), `ladders_for`, `kind_difficulty_diagnostics`, `draft_exercise`, `exercise_prompt_options`, `build_exercise_prompt` (passes `rungs`).
- `app/models/kind_difficulty.rb`: possibly `#rungs_for(kinds, skill_level:)` if the call sites read better with it. No new state.
- `app/models/ladder_coverage.rb`, `app/controllers/concerns/exercise_mix_ladders.rb`, `app/controllers/learn_controller.rb`.
- `config/locales/en.yml`, Setup and Learn ladder strings (see Copy).
- `docs/code-notes/app/services/ai_service.md` (the difficulty block section), `docs/code-notes/app/models/ladder_coverage.md` if present.
- `CLAUDE.md`, "Difficulty targets and locks": the block now covers every kind; `prepare_ladders`' scoped exception becomes "the concepts behind each section's level".

### Migration and rollback

No migration. Rolling back the code restores the old prompts byte for byte, because nothing is stored.

### Snapshots (counted on 9ecd83b)

- **Prompt: 72 of 72 change.** The characterization user is an untargeted junior, so every snapshot gains the block, with every kind at junior and no ladders, since the spec passes `ladders: {}`. Rebaselined with `UPDATE_PROMPT_SNAPSHOTS=1` as the intended deliverable.
- **Request: 0 of 15.** They carry fixed test prompts, not the generation prompt.
- **Page: 1 of 5.** `setup.html` changes because ladder preparation now counts the snapshot user's kinds:
  - the section is no longer hidden, and the button count rises from 0;
  - the design comparison coverage label changes from 0/21 to 0/20, read at junior instead of the union of rungs;
  - the explanation copy changes.

  No JavaScript file changes, so the other four keep their import maps. Without item 5, 0 of 5 change.

### Tests

- **`spec/services/ai_service_spec.rb`** (8 references to the block and ladders today):
  - the block renders for an untargeted account, every kind at the skill level;
  - a targeted kind at the skill level and an untargeted kind render identically;
  - mixed levels group by level as before;
  - lock lines list only locked kinds;
  - `ladders_for` fetches rungs for untargeted kinds at the skill level;
  - diagnostics carry `targeted`.
- **`MAX_LADDER_GUIDANCE_CHARS`.** The spec already renders every kind at every level, so the worst case it measures is the one every account can now reach. Only the signature changes. Re-run it: the new opening line is a few characters longer than the old one, and if the bound no longer holds, that is a decision for you, not a number to raise.
- **`spec/services/level_suggestion_isolation_spec.rb`**, new example: twins at skill level junior, one with every kind targeted at junior (today's preset) and one with no targets, send byte-identical generation and judge calls. This is the property that makes PR 1 safe.
- **`spec/services/generation_prompt_characterization_spec.rb`**: rebaseline 72.
- **`spec/models/ladder_coverage_spec.rb`, `spec/requests/learn_spec.rb`, `spec/requests/profile_spec.rb`** (`ladder_preparation` in the save body), **`spec/system/exercise_mix_spec.rb`**, **`spec/models/kind_difficulty_spec.rb`**: read at the rung, with untargeted kinds counted.
- **`spec/requests/existing_account_pages_spec.rb`**: rebaseline `setup.html` only.

### Copy

- `exercise_mix.ladders_explanation`:
  > Optional: prepare concept-specific guidance that tells the AI what problems at each section's level should look like. Your levels work without it. The count is the concepts behind your sections' levels that still need guidance; this does not generate a new exercise set.
- `learn.ladder_offer`:
  > Optional: prepare concept-specific guidance to help the AI pitch %{targets} at its level. It works without it. This uses your API key and may change the shared reference's wording.
- `exercise_mix.ladders_cost` is unchanged.

### Risk

- **Medium.** Every account's generation prompt changes. The new text says what the profile line and the stamped rung already meant, so the intended pitch doesn't move, but the model now reads an explicit level definition for every section. That can shift how hard untargeted sections come out. Nothing measures this beyond `[difficulty_diagnostics]` and the ratings that follow.
- **Prompt size.** An untargeted account with no grounded ladders adds a few hundred characters. One whose concepts have ladders adds up to the existing bound. That costs more input tokens per generation by an unmeasured amount.

### As built

- The block's worst case measured 53,668 characters, up from 53,632, under the 54,000 bound.
- `KindDifficulty#targeted_kinds` lost its last caller and was removed. `KindDifficulty#rungs_for(kinds, skill_level:)` is the one helper the call sites share.
- After the critical review: ladder preparation skips kinds the user excluded (the plan can never pick them), is never offered to a trial account (`User#prepares_ladders?`, so a house key never funds a shared rewrite), and a one-section retry carries only that kind's ladder rungs. `LadderCoverage#gaps` and `#grounding_kinds` lost the kinds argument every caller passed as "all". One press can still queue about a hundred jobs, since `PREPARE_PER_HOUR` counts presses; capping jobs per press is left open.
- `setup.html` changed as predicted: the preparation section shows, the button counts concepts, and the design comparison's coverage reads 0 of 20.
- Specs that used "the control is hidden" as their signal for "no account with no targets" now check that the button is disabled while a save is pending, the property they were guarding. The retention spec that matched `/retention check/i` now matches the retention block's own heading, since the difficulty block always names retention checks.

---

## PR 1: tracks per level (revised, approved)

The revision adds scope item 10: every track change applies the target-clearing table, not only graduation. Approved on 2026-10-15, with an optional preview before a Setup track change saves ("This moves N sections; Pattern keeps Senior", Save and Cancel), built only if it stays inside the existing Setup controller and a small partial; otherwise it is a follow-up.

### Scope

1. **The welcome page offers three tracks, in one step:** Junior, Mid-level and Senior, from `LevelSuggestion::LADDER`.
   - Each button saves that `skill_level` and records the choice.
   - The Experienced step, its level step and Back are removed.
   - Principal engineer is not offered, and the page says it can be chosen in Setup.
2. **The choice is recorded in a new column, `users.track_chosen_at`** (nullable datetime).
   - `User#first_run?` becomes `persisted? && track_chosen_at.nil? && !daily_exercises.exists?`.
   - `learning_track` is no longer read. For one release, a track choice also writes `learning_track: "none"`, so rolled-back code doesn't send new accounts to `/welcome` again. A later cleanup PR drops the column (the repo's one-release pattern).
3. **No presets.** The welcome choice writes no `section_kind_levels` and needs no `section_kind_preferences_version`. No migration touches existing targets; they change only through item 10.
4. **Removed:**
   - `LearningTrack.preset_levels`, `START_LEVEL`, `START_SKILL_LEVEL`, then the `LearningTrack` module itself. The validation moves to a literal list for the one release, then goes with the column.
   - `User#on_learning_track?`, `#learning_track_change_allowed?`, `#finish_learning_track` and its `before_save`.
   - Leave: `api_keys/_learning_track.html.erb`, `learning_track_controller.js` and its code note.
   - The Experienced and level-step parts of `welcome_controller.js`.
5. **Kept, renamed:** `choosing_learning_track?` and `chose_learning_track?` become `choosing_track?` and `chose_track?`, read from `track_chosen_at` changing from nil. The first choice still records no cutoff and no event row, as today.
6. **`ProfileController`:**
   - A track choice is `user: { choose_track: true, skill_level: }`. Under the row lock it is refused (422) unless `first_run?`, unless the keys are exactly those two, and unless `skill_level` is in `LevelSuggestion::LADDER` (principal refused).
   - `TRACK_CHOICE_KEYS` and `invalid_learning_track_change?` are replaced by that check. `LOCKED_KEYS` swaps `learning_track` for `choose_track`.
   - **Stale tabs:** a post carrying `learning_track` gets a 422 with "This page is out of date. Reload it to continue." and saves nothing. That covers a welcome page opened before the deploy, whose junior post would otherwise save presets without recording a choice, and a Setup tab's old Leave.
7. **The key guide** shows on Setup for a trial that ended, or for any account with no exercise yet. That replaces "on the track and no exercise". In practice that means a new account, whichever track it chose.
8. **Setup's skill level control becomes the track control.** Same select, same endpoint, same four options. Principal engineer stays selectable here only, and the label and hint change.
9. **CLAUDE.md:**
   - Rewrite the "Junior learning track" bullet as "Tracks".
   - Update "Skill level control", the Models table (`track_chosen_at`; `learning_track` noted as unread until dropped), and the level suggestion bullet's track sentences ("The first-run choice … records nothing", "leaving or finishing it").
   - Update the File Map: `learning_track.rb` goes; `welcome_controller.rb` stays.
   - Change the spec-helper note (`create_user_with_key` defaults to a chosen track).
   - Add the line: "Senior is the highest track graduation reaches; principal engineer is set by hand in Setup."
   - State the target-clearing rule in the Tracks bullet, once, with `TrackChange` as its authority.
10. **Every track change clears the targets the track now covers.** One rule, `TrackChange` (`app/models/track_change.rb`, pure over plain values), applied whenever `skill_level` changes after the first choice: by hand in Setup now, and by graduation in PR 5.

    | Target | On a track change | Why |
    | --- | --- | --- |
    | Equal to the old or new level, unlocked | Cleared | Redundant; the kind rejoins the track |
    | Above the new level | Kept | The kind earned more |
    | Below the old level | Kept | The kind stepped back |
    | Locked | Kept | The user asked for it |

    The table assumes a one-rung move. A hand move in Setup can skip a rung (junior to senior), so the rule is stated by level rather than by rung distance:
    - an unlocked target equal to the old or the new level is cleared;
    - every other target is kept, and so are locked ones.

    So a junior-to-senior move clears junior and senior targets and keeps a mid-level one, which sits between the two levels. That kind earned or chose its level, and the kept line names it so the person can clear it by hand.

    - **Where it runs:** a `before_save` on `User`, when `skill_level` changes and the save is not the first track choice. It is declared **ahead of `bump_section_kind_preferences_version`** (`user.rb:51`), not just ahead of `record_level_changes`. Callbacks run in declaration order and each `if:` is read when its callback is reached, so a skill-level-only save that clears targets must have cleared them before the bump checks `section_kind_levels_changed?`; otherwise the version stays put and another tab overwrites the cleared levels. A request spec saves `skill_level` alone and asserts the version moved.
      - The cleared and kept kinds ride a transient attribute (`track_change`, holding the `TrackChange` result), as `shown_level_suggestions` does, so the after-save event hook and the controller reply read the same object.
      - A kind whose target was cleared and whose rung moves (a junior preset when the track goes to mid-level) gets a cutoff at its new rung and a `skill_level_edit` event row, like any kind the skill level moved.
      - A kind whose target equalled the new level keeps its rung, so it gets neither.
      - `LevelSuggestionEvent.source_for` learns that a target removed by `TrackChange` counts as `skill_level_edit`, not `setup_edit`; `User` hands it the cleared kinds.
    - **Version:** clearing targets changes `section_kind_levels`, so `section_kind_preferences_version` bumps. Another open Setup tab gets the existing 409 on its next Exercise mix save and re-syncs from the server.
    - **Setup in the same tab:**
      - A track save's reply also carries `section_kind_levels`, `locked_section_kinds`, `section_kind_preferences_version`, `kind_rungs`, `ladder_preparation` and `kept_own_level` (the kinds `TrackChange` kept, with their levels).
      - `profile_preferences_controller.js` hands the server state to the Exercise mix through its existing `applyServerState`, sent as a Stimulus event rather than a reach into the other controller. Cleared kinds then show "Your track (…)" and kept ones their level.
      - A status line under the select names the kinds that kept their own level, and is empty when none did.
    - **Graduation (PR 5)** builds the same `TrackChange` to show the card's "keeps its own level" list before Apply, and its Apply goes through the same `before_save`. The rule has one statement.

### Files

- `db/migrate/2026101xxxxxxx_add_track_chosen_at_to_users.rb`: add the column; backfill `track_chosen_at = created_at` where `learning_track IS NOT NULL`. That covers every backfilled `"none"` account and your `"junior"` account.
- `app/models/user.rb`, `app/models/learning_track.rb` (deleted), `app/controllers/profile_controller.rb`.
- `app/models/track_change.rb` (new), `app/models/level_suggestion_event.rb` (`source_for`).
- `app/javascript/controllers/profile_preferences_controller.js` (applies a track save's reply and shows the kept line), `app/javascript/controllers/exercise_mix_controller.js` (listens for the server-state event), `app/views/api_keys/edit.html.erb` (the kept line's status element).
- `app/views/welcome/show.html.erb`, `app/javascript/controllers/welcome_controller.js`.
- `app/views/api_keys/edit.html.erb`; `app/views/api_keys/_learning_track.html.erb` and `app/javascript/controllers/learning_track_controller.js` deleted.
- `config/locales/en.yml`:
  - `learning_track.welcome` moves to `welcome`;
  - `learning_track.setup.key_guide` moves to `api_keys.key_guide`;
  - `learning_track.setup.suggested` moves to `level_suggestion.setup_suggested`;
  - the on-track, Leave and left strings are deleted;
  - so the `learning_track` namespace goes.
- `app/views/api_keys/_key_guide.html.erb`: 23 key lookups, renamed only.
- `spec/support/auth_helpers.rb`: helpers take `track_chosen_at:`, defaulting to a time; a first-run spec passes `nil`.
- Code notes: `docs/code-notes/app/models/user.md`, `app/controllers/profile_controller.md`, `app/javascript/controllers/welcome_controller.md`, `app/models/track_change.md` (new); `learning_track_controller.md` deleted.
- `CLAUDE.md`, as in scope item 9.

### Migration and rollback

- **The migration ships ahead of the code (PR 1a, `AddTrackChosenAtToUsers`, built once PR 2 merged as #396).** Web and worker deploy separately, and the worker's pre-deploy waits only for a schema to exist, not for this migration. If PR 1's code reached a worker before the web pre-deploy migrated, every `User` save in a job would hit callbacks reading `track_chosen_at` and raise. So PR 1a is migration only: add the column and backfill, with no code reading it. PR 1 follows once 1a is deployed. This is the repo's existing add-then-read pattern.
- **Up:** add `track_chosen_at` and backfill from `learning_track IS NOT NULL`. Reversible: the down removes the column. Accounts created between 1a and PR 1 come in with `learning_track` set by today's welcome flow, so PR 1's deploy re-runs the same backfill as an idempotent data step for rows still null with a non-null `learning_track`.
- **Code rollback after deploy:**
  - Old code reads `learning_track`, which still holds every old value.
  - Accounts created under PR 1 hold `"none"` through the dual write, so old code neither re-prompts them nor shows Leave.
  - A Mid-level or Senior choice is only a `skill_level`, which old code reads normally.
  - Nothing is lost.
- **Follow-up cleanup PR**, one release later: ignore, then drop `learning_track`, remove the dual write and the literal validation. Same pattern as `RemoveTrackLeftoversFromUsers`.

### Snapshots (counted on 9ecd83b)

- **Page: 5 of 5 change.** Every page's import map lists each Stimulus controller with its digest. PR 1 deletes `learning_track_controller.js` and edits `welcome_controller.js`, `profile_preferences_controller.js` and `exercise_mix_controller.js`, so all five change there. `setup.html` also changes in the track label, the hint, the Exercise mix's default-option label and the empty kept line.
- **Prompt: 0 of 72.** The profile line still reads "Skill level: …" and keys on the level only.
- **Request: 0 of 15.**

### Tests

**Replace `spec/requests/profile_learning_track_spec.rb`** (20 preset references) with `profile_track_choice_spec.rb`:
- each of junior, mid_level and senior saves `skill_level` and sets `track_chosen_at`;
- principal is refused with 422;
- a second choice is refused;
- extra keys are refused;
- the first choice writes no cutoff and no event row;
- a stale `learning_track` post gets the 422 and saves nothing.

**`spec/models/user_learning_track_spec.rb`** (11) becomes `user_track_spec.rb`:
- `first_run?` for not chosen with no exercise, chosen, and has exercises;
- no `finish_learning_track` behavior remains;
- a skill-level change after the choice still records cutoffs and events.

**`spec/models/track_change_spec.rb`** (new, no database), the table row by row:
- unlocked targets at the old level and at the new level are cleared;
- a target above the new level is kept, and so is one below the old level;
- a locked target at the old level is kept;
- a two-rung move (junior to senior) keeps a mid-level target;
- `kept` lists exactly the kinds that keep a target.

**`spec/requests/profile_track_change_spec.rb`** (new), through `PATCH /profile` with `skill_level`:
- **your account's case:** every kind preset at junior, one locked and one at senior; the track moves to mid_level. Afterwards no unlocked kind holds a junior target, the locked kind keeps junior, and the senior kind keeps senior;
- the cleared kinds get a cutoff at mid_level and a `skill_level_edit` event row each; a kind whose target equalled the new level gets neither;
- `section_kind_preferences_version` bumps, and a stale Exercise mix save from another tab gets the 409;
- the reply carries the levels, the version and `kept_own_level`.

**`spec/system/setup_track_change_spec.rb`** (new): changing the select to Mid-level shows the cleared kinds' radios at "Your track (Mid-level)" without a reload, and the status line names the kept kinds; the next Exercise mix edit saves with no 409.

**`spec/requests/welcome_spec.rb`, `spec/system/welcome_spec.rb`:**
- three buttons, no Experienced, no principal;
- the busy state, and focus returning on failure;
- redirect to Setup.

**`spec/requests/setup_learning_track_spec.rb`, `spec/system/setup_learning_track_spec.rb`, `spec/system/learning_track_spec.rb`**, merged into `setup_track_spec` (request and system):
- no Leave;
- the key guide for an account with no exercise and not for one with exercises;
- the track label and hint;
- principal is selectable in Setup.

**Preset references replaced with explicit `section_kind_levels`:**
- `spec/requests/level_suggestion_spec.rb` (14);
- `level_suggestion_controls_spec` (request and system);
- `level_suggestion_steps_spec`;
- `level_suggestion_dismissals_spec`;
- `spec/system/level_suggestion_spec.rb`;
- `spec/models/user_level_changes_spec.rb`.

**`spec/services/level_suggestion_isolation_spec.rb`:**
- twins differ by `track_chosen_at`, cutoffs and the switch, not by `learning_track`;
- `state_readers` adds `track_chosen` and `choose_track`, so generation and judging code can never read the choice.

**Also:**
- `spec/migrations/add_track_chosen_at_to_users_spec.rb`: backfill and rollback.
- `spec/migrations/backfill_learning_track_for_existing_users_spec.rb` is kept; it tests a past migration.
- `spec/requests/existing_account_pages_spec.rb`: the user gets `track_chosen_at`; rebaseline 5.
- `spec/requests/trials_spec.rb`, `provider_failure_characterization_spec.rb`, `spec/system/input_font_size_spec.rb`: helper argument only.

### Copy

No line names a job title or claims what the person is; each says what the exercises are like.

**Welcome page (`welcome.*`):**
- Title: "Before you start"
- Question: "Where should your exercises start?"
- **Junior:** "One clearly visible problem in a small scenario. A good start if you're early in your career, changing careers, or new to this stack."
- **Mid-level:** "Problems that don't point at themselves, so you find them by reading closely."
- **Senior:** "A problem alongside a real constraint or a second issue, where the right answer depends on context."
- Note under the buttons: "You can change this any time in Setup, and set a level for each kind of section. Senior is the highest level Code Gym suggests; choose Principal engineer in Setup if you want it."

**Setup:**
- Label: "Track"
- Hint, for PR 1, before graduation exists: "The level every section uses unless you set one for it in the Exercise mix below. When your reviewed answers show a section is ready to move, Code Gym suggests a level for that section, and you decide. Principal engineer is set only here; Code Gym never suggests it." PR 5 adds the sentence about suggesting the next track.
- `exercise_mix.level_default`: "Your track (%{skill_level})", replacing "Your skill level (…)".
- Kept line, after a track change that kept some kinds: "These sections kept their own level: Pattern (Senior), Challenge (Junior, locked). Choose Your track for any of them in the Exercise mix to have it follow the track."
- A sentence added to the hint: "Changing your track also moves any section set to your old or new level, unless it is locked."

### Risk

- **Medium.** Onboarding and Setup, with no prompt change of its own. A track change now rewrites targets, which a person can't undo with one click; the kept line and the hint say what happened.
- A stale tab is handled by the 422, and an open Exercise mix by the version bump and its existing 409.
- The rollback window is handled by the dual write. Targets cleared by a track change before a rollback stay cleared, which old code reads as following the skill level, its own meaning.

---

## PRs 3–5, in brief

### PR 3: rubric module and evidence reader, no UI

- **`LevelRubric`** (`app/services/level_rubric.rb`, pure).
  - **Area map per language**, built from existing `ConceptVocabulary` constants. The lists of concepts are domain data, so they live in `ConceptVocabulary` (a `RUBRIC_AREAS` table) and `LevelRubric` reads them.
  - **Mid-level areas:**
    - security: `authorization` plus `RAILS_SECURITY_CONCEPTS` for Rails. `authorization` reaches the rubric through code review, whose vocabulary carries it. JavaScript uses `JS_SECURITY_CONCEPTS`.
    - performance: `n_plus_one`, `indexing`, `caching` for Rails; the event-loop and rendering concepts for JavaScript.
    - testing, data modeling, code smell, meta skill.
  - **Senior areas:** OO design, module design, domain modeling, silent correctness, and correctness under load (Rails only: `concurrency`, `transaction_safety`, `idempotency`).
  - **Junior areas are not needed.** Graduation only reads the next level's areas.
- **Spec rules:**
  - no concept in two levels' areas, so `n_plus_one` is mid-level only;
  - every area has at least one concept that code review or design comparison can tag in that language;
  - areas only the rare language-independent kinds can reach are left out, so complexity cause is excluded.
- **Evidence:** `ReviewedSectionResults::Result` gains `concept`. A new reader takes rubric-stamped, answered, un-eased results at the current track's level, grouped by area. An area counts when 2 of its latest 3 results are solid or better.
- **The spec simulates the 2-of-latest-3 rule.** A seeded simulation uses the real `SectionRotation`, vocabularies and mode weights, as in the investigation. It records the share of accounts that qualify at 2, 3 and 4 sections over 22, 43 and 60 weekdays. It asserts the rule is reachable at two sections within 60 weekdays for an account answering everything at a 70% solid rate. The table goes in the code note, and the bound is set from the first run.
- **Decided:** senior needs all but one reachable area (4 of 5 for Rails, 3 of 4 for JavaScript; mid-level stays 4 of 6), and a mixed-language account covers an area in either language.

### PR 4: level-specific grader expectations

- Each kind's `grading_note` takes the pitched rung.
- **The junior text is today's note, byte for byte.** For code review that is the planted issue, why it is a problem, and a fix that works as written. A spec pins junior against a copy of today's text, so junior can't become easier and junior-pitched reviews keep their meaning.
- **Mid-level, senior and principal only add expectations.** For code review:
  - mid-level adds how to test for it;
  - senior adds the interacting issue and how to prevent it coming back;
  - principal adds whether to fix it locally or change the design, and what each costs.
- **Parsons is unchanged,** since its rating is computed.
- `RATING_RUBRIC` and `RUBRIC_VERSION` are unchanged (3c).
- **Snapshots:** 0 of 72, 0 of 15, 0 of 5.
- **Specs:** about 15 `grading_note` references across 4 spec files, plus the "notes never restate the levels" spec.
- **Calibration:** a billed re-run with mid and senior fixtures added. You run it.
- **Known effect:** mid-level and senior results graded before PR 4 sit beside stricter ones graded after. 3c accepts this. Decided: graduation reads only reviews dated after PR 4 shipped.

### PR 5: graduation suggestion

- A card on the submitted dashboard, one at a time: per-kind step-back, then graduation, then per-kind step-ups.
- **It offers the next track up to Senior,** never Principal. It shows nothing at Senior or Principal.
- **It follows the "Suggest level changes" switch.**
- **Apply** goes through `PATCH /profile` with a graduation step, checked under the row lock against the current `skill_level`. The skill-level change runs PR 1's `TrackChange`, and the card names the kinds it would keep before Apply.
- **Not now** adds an `"overall"` entry to `level_suggestion_cutoffs`. Nothing validates that map's keys today (checked).
- **Events:**
  - `level_suggestion_events.kind` accepts `"overall"`;
  - `SOURCES` adds `"graduation"`;
  - the per-kind `skill_level_edit` rows a graduation causes are labelled `graduation`.
  - Migration: none for the column, which is a string; the change is the model validation.
- **Copy** names what the results show, never a title. For example: "Your reviewed answers show mid-level work across security, testing, data modeling and code smells." The track hint in Setup gains the sentence about suggesting the next track.
- **Isolation:** the new module joins the spec's `own` list.

### Cleanup PR, one release after PR 1

- Ignore, then drop `users.learning_track`.
- Remove the dual write and the literal validation.

## The by-hand clearing rule (from the critical review; decided)

The rule in item 10 clears an unlocked target equal to the old or new level on every track change. Once presets stop being written, a target equal to the old level is indistinguishable from one chosen on purpose. Example: on mid-level, someone deliberately holds pattern at mid-level; raising the track to senior in Setup clears it, and pattern jumps to senior with no preview and no one-click undo. Only a lock protects it. The review's alternatives:

- **A.** Keep the rule as decided, and show which sections would be cleared and kept before the Setup select saves (a confirm step), not only after.
- **B.** Apply `TrackChange` only to graduation, whose card previews it, and clear today's exact presets (every kind junior, unlocked, on a junior-track account) with a one-off script. Hand moves in Setup leave targets alone.
- **C.** Keep the rule as decided, with the after-the-fact line only.

**Decided:** the rule stays on every track change. The preview in A is built in PR 1 only if it stays inside the existing Setup controller and a small partial; otherwise PR 1 ships C and the preview becomes a follow-up.

## Decisions recorded

- **Q1.** Ladder preparation follows every section's level: yes, built in PR 2.
- **Q2.** Senior area threshold: all but one reachable area.
- **Q3.** Mixed-language accounts: an area counts if covered in either language.
- **Q4.** PR 5 reads only reviews dated after PR 4 shipped.
- Every track change applies the target-clearing rule (PR 1, item 10).

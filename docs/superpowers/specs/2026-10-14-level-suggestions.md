# Level suggestions for every account

Read on `origin/main` at **01dede7**. The only change since the investigations (read at 02b9b56) is `.claude/agents/critical-reviewer.md`; no app code moved.

## Context

Pitch (the rung a section is generated at) is a setting. Only `TrackGraduation` ever proposes moving it, only for junior-track accounts, only junior↔senior, with a 3-result all-or-nothing rule, a lead bundle that offers kinds with no evidence, and a "Not now" bug. The goal: every account gets per-kind suggestions driven by its own stored results, one rung at a time, and the user always decides.

### Findings re-confirmed on 01dede7 (all hold)
1. Holds. `KindDifficulty#rung_for` (kind_difficulty.rb:36-37) reads only targets and skill_level. `TrackGraduation` runs only when `suggests_track_moves?` (user.rb:227, track-only), `NEXT_LEVEL = { junior => senior }` (track_graduation.rb:6), candidates filter on `LearningTrack::LEVELS` (junior, senior), so mid/principal kinds are skipped.
2. Holds. `full_favourable_window?` needs exactly 3, all favourable (AI ≥ solid AND self too_easy/right_level). `single(:own)` returns the first kind in registry order.
3. Holds. `led_step` accepts `at_level.first(3).all?` → an empty list passes; the partial even has copy for it (`led_no_results`).
4. Holds; bug. `since_cutoff(key, @results.fetch(@lead, []))` filters lead results by date only (reproduced last round: junior-level code review results re-opened a dismissed bundle member).
5. Holds. `back_step` counts `too_hard?` only, `PREVIOUS_LEVEL` senior→junior.
6. Holds. `welcome.experienced_hint` says "Exercises follow the regular difficulty" but the account stays at skill_level `junior`; `skill_level_hint` says "start out … ratings still nudge" though nothing moves the setting.

## Design

### Where the code lives
- New `app/services/level_suggestion.rb` (replaces `TrackGraduation`) and `app/services/level_suggestion/evidence.rb` (replaces `TrackGraduation::Evidence`). Pure over plain values, like today; `LevelSuggestion.for(user)` is the only DB-reading entry.
- It never reads `learning_track`. It reads `section_kind_levels`, `locked_section_kinds`, `skill_level` (through `KindDifficulty#rung_for`) and the cutoff map.
- All constants in one place, `LevelSuggestion::Rule`:
  - `LADDER = %w[junior mid_level senior]` (derived as `KindDifficulty::LEVELS - ["principal_engineer"]`, with a spec pinning that).
  - `WINDOW = 5`, `FAVOURABLE_NEEDED = 4`, `VETO_WINDOW = 3`, `VETO_TOO_HARD = 2`.
  - `STEP_BACK_WINDOW = 3`, `STEP_BACK_TOO_HARD = 2`, `IN_PLACE_ANSWERS = 3` (moved from `LearningTrack`).

### Evidence (per kind, current rung only)
- Same source as today: `ReviewedSectionResults.for(response, require_rubric: true)` over the latest 60 submitted, reviewed responses. Results must be answered, stamped with `pitched_at`, not eased, and have an AI rating.
- **Change: rubric stamp required.** The AI rating now decides alone, and only rubric-stamped ratings are graded against the stated rung (`CompetencyGate` already requires it). Cost: a `RUBRIC_VERSION` bump restarts suggestion evidence, as it does for the gate.
- A kind's evidence = its results whose `level` equals the kind's current rung (`rung_for`) and dated after that kind's cutoff, if the cutoff's level equals the current rung.

### Rule
- **Candidates:** kinds whose current rung is in `LADDER`, not locked.
  - Principal: no suggestion to or from it. A kind at principal is never a candidate, and mid→senior is the top step. The card and Setup never mention principal.
  - Excluded kinds stay candidates, as today.
- **Step up** (rung junior or mid_level), all of:
  - the latest 5 results at the rung exist (minimum sample 5);
  - at least 4 of them have AI rating `solid`/`strong`;
  - fewer than 2 of the latest 3 are self-rated `too_hard` (the veto).
  - Destination: next rung on `LADDER`.
- **Step back** (recommended form, open decision A), rung mid_level or senior:
  - at least 2 of the latest 3 results at the rung are self-rated `too_hard`;
  - **and** those too-hard results were not all rated `solid`/`strong` by the AI.
  - So the person's own rating proposes, and the AI grade can veto — the mirror of step up. Destination: one rung down.
- **Precedence:** step-back proposals are shown alone, before any step up (the person said it's too hard; that comes first).
  - Several step-ups on one day: see open decision C.
- **Day spread:** see "Constants" below; I recommend not adding the 3-day rule.

### Lead bundle: removed
With the decided requirement that a bundle member must meet the same rule on its own results, every member would already qualify by itself.

The lead then adds two things only:
- a gate: code review must be targeted above junior;
- grouping into one card.

The gate only *withholds* offers the own-results rule already justifies. The grouping is open decision C, independent of any lead. So the lead adds nothing, and I propose removing it:
- `led_step`, `lead_past?`, the `:led` basis;
- `ExerciseSection.learning_track_lead` and `.leads_learning_track?` (code_review.rb:10, exercise_section.rb:18-19, 165);
- the `led_*` locale keys.

Finding 4 disappears with it. A spec still pins the decided fix: after "Not now", only results at the kind's *current* rung and after the cutoff can re-open an offer.

### "Not now" sticks
Dismissal writes `{level: current rung, through: newest reviewed date (or today)}` per kind, under the row lock — as today, but the level is the *rung* so untargeted kinds work.

After that, the full step-up rule must be met by post-cutoff results alone: 5 new results at that rung. Because each kind appears at most once per day, that is at least 5 more days with that kind, never the next day.

### Level changes record cutoffs for every account
`User#record_track_level_changes` (user.rb:459) becomes `record_level_changes`, for every account:
- Any change to a kind's rung records a cutoff at the destination rung, through today, so old results at that rung (from an earlier visit) can't be reused.
- Rung changes come from a target edit, Apply, or a skill_level change that moves untargeted kinds.
- `finish_learning_track` changes from "no junior target remains" to **"no target below senior remains"** (see report (c)), so moving the last junior kind to mid-level no longer ends the track. This lands in PR 1.
- The same callback is where Apply and Setup-edit events are detected and written (see report (d)).

### Apply on an account without targets, and skill_level
Apply PATCHes `section_kind_levels` with the existing versioned precondition, adding one key, so only that kind gets a target. That kind's rung is then the target (kind_difficulty.rb:36-37).

**`skill_level` is not changed.** It keeps deciding every untargeted kind and the prompt's "Skill level:" profile line.

Consequence: once Apply runs, that user's generation prompt gains the difficulty-targets block for the targeted kind. That is runtime state; no snapshot is affected (see "Snapshots").

### Data and migration
New columns (track-neutral names, so the isolation spec can forbid them in generation code):
- `users.level_suggestions` boolean, default `true` (open decision B), not null;
- `users.level_suggestion_cutoffs` jsonb, default `{}`, not null.

The migration:
- adds both;
- backfills from `track_suggestions` and `track_evidence_cutoffs` in one `UPDATE`;
- marks the old two columns `ignored_columns` for one release, the `api_key` / `adaptive_set_size` precedent.

A later PR drops them. `track_proposals_answered` keeps its name (only `User` and the partial read it).

Rollback:
- `down` removes the new columns; the old columns were never touched, so the previous release runs unchanged.
- Known window: a dismissal written by old code between migration and new code going live is not copied. It costs at most one re-offer, which the user can dismiss again.

### UI and routes
- **Card.** `dashboard/_track_proposal` → `dashboard/_level_suggestion`; `track_proposal_controller.js` → `level_suggestion_controller.js`.
  - Same place: the submitted dashboard, for any account with `level_suggestions` on.
  - Same Apply / Not now / in-place-then-Setup behavior, now counted for every account.
- **Routes.** `learning_track_dismissals` and `learning_track_answers` → `level_suggestion_dismissals` / `level_suggestion_answers` (`POST /level_suggestion/dismissal`, `/answer`). The track checks are removed; valid kinds are those whose rung is in `LADDER`.
- **Setup:**
  - The "Suggest level changes" switch moves out of `_learning_track` into the Exercise mix, above the difficulty controls, for every account.
  - The highlights (`ApiKeysController#suggested_kinds`) work for every account, with `suggested_level` validated against `LADDER`.
  - `_learning_track` keeps the on-track line and Leave. Its copy no longer claims suggestions belong to the track.
- **Copy.** All new and changed strings follow the plain-language standard and never name a tier. See open decisions D and E.

### Isolation spec (`spec/services/learning_track_isolation_spec.rb`)
- **Test 1 (byte-identical prompts on/off track)** is untouched in intent.
  - Its cutoffs fixture keys on `ExerciseSection.learning_track_lead.key`, which is removed, so that line changes to the literal `"code_review"` and the column `level_suggestion_cutoffs`.
  - This is a fixture rename, not a weaker assertion.
- **Test 2 (text search)** is **strengthened**:
  - The `own` exemption list becomes empty: no file under services or jobs mentions track state any more.
  - The regex gains `level_suggestion_cutoffs|level_suggestions|LevelSuggestion`, with `app/services/level_suggestion.rb` and `level_suggestion/evidence.rb` as the only exemptions.
  - So generation, review, judges, `ConceptMastery` and `KindDifficulty` can't read suggestion state either.

### Snapshots (counted on 01dede7)
- **Prompt snapshots: 0 of 72 change.** `generation_prompt_characterization_spec` renders an unpersisted `User.new(skill_level: "junior")` with no targets; no prompt code changes.
- **Judge prompt snapshots:** none exist. `spec/fixtures/judge` holds 25 model-comparison inputs, not snapshots.
- **Request snapshots: 0 of 15.** Placeholder prompts, and no new `#call` keyword.
- **Page snapshots: 1 of 5 expected, `setup.html`** (the switch moves in, and the hint copy changes).
  - `dashboard_submitted.html` should stay identical: its fixture sections carry no `pitched_at`, so there is no evidence and no card. To be confirmed by running.
  - account, history and dashboard_unsubmitted are unaffected.
- **No new provider calls;** the suggestion is display-only and writes nothing on render. Only the Apply, dismissal and answer endpoints write.

### Side effect to know about
`CompetencyGate` line 92: Apply changes that kind's `pitched_at`, so its growth windows restart from the next result. The earned size is never taken back. This is existing behavior, now reachable by every account.

## Walkthrough: old rule vs new rule
Old outputs were verified last round by running `TrackGraduation.proposal`. New outputs are what the new rule produces by its definition, and become specs in Phase 2.

**A. The original data (3 results per kind; every kind targeted junior):**

| Kind | Results, newest first (AI / self) | Old rule | New rule |
|---|---|---|---|
| code review | solid/just right ×3 | **offered** junior→senior (1st, alone) | no offer: 3 < 5 results |
| design comparison | developing, solid, solid | blocked by one developing | no offer: 3 < 5 |
| pattern | strong/too easy ×3 | offered 2nd, after code review applied | no offer: 3 < 5 |
| challenge | beginner/too hard ×1 | blocked | no offer: 1 < 5 |
| security review | strong/just right, strong/**too hard**, strong/just right | blocked by one too hard | no offer: 3 < 5 (one too hard alone would not veto) |
| plan review | solid ×2 | in the 3rd-step lead bundle | no offer: 2 < 5 |
| architecture, parsons, ambiguity hunt, pseudocode | none | in the lead bundle with **0 results** | no offer |

**B. The same profile with 5 results where there were 3:**

| Kind | Latest 5 (AI / self) | Old rule | New rule |
|---|---|---|---|
| code review | solid/just right ×5 | offered → **senior** | offered → **mid-level** |
| design comparison | developing, then solid ×4 | blocked (latest 3 incl. developing) | **offered** → mid-level (4 of 5) |
| pattern | strong/too easy ×5 | offered after code review, one at a time | offered → mid-level |
| security review | strong ×5, latest 3 incl. one too hard | blocked | **offered** (veto needs 2 of 3) |
| security review, variant | strong ×5, two too hard in the latest 3 | blocked | **vetoed** |
| code review at senior, variant | strong, self too hard ×2 of 3 | step back → **junior** | step back offered → mid-level only if the AI didn't rate those solid+; here AI strong → **no step back** (open decision A) |
| design comparison, dismissed with "Not now" | then 3 junior-level code review results | re-offered via the lead (bug) | stays dismissed until 5 new design comparison results at its rung |

## Open decisions (my recommendation first)
- **A. Step back:** one rung down (senior→mid, mid→junior), and consult the AI as a veto. If the AI rated the too-hard results solid or better, don't offer. This mirrors step up and avoids a downgrade for good work that merely felt hard.
- **B. Switch default and place:**
  - Default **on** for everyone, backfilled from `track_suggestions` (which is `true` unless a track user turned it off). An offer needs 5 graded results, so nobody sees one early.
  - Place: the Exercise mix on Setup, next to the difficulty controls it changes, with id `level-suggestions` for the card's link.
- **C. Several kinds on one day:** show them **together** in one card, each line with its own "Keep at {level}" remove button, one Apply and one Not now. This reuses the existing removable-list UI and suits uneven profiles. Step-backs stay alone.
- **D. Card copy and place:** same place (the submitted dashboard). The wording is in "Changes requested at review", item 4, with counts computed from the evidence. Footer: "You decide each time. Turn these suggestions off in Setup." No tier is shown.
- **E. Copy fixes:**
  - Experienced: "Exercises start at the junior level. Set your skill level in Setup, and Code Gym will suggest moving each kind up as your reviews show you're ready."
  - Setup skill-level hint: "The level every section uses unless you set one for it in Exercise mix. It stays where you put it. When your reviews show a section is ready to change, Code Gym suggests it, and you decide."

### Constants — where I'd differ
- **Day spread (3 days): drop it.** A day holds each kind at most once, and one exercise and one response exist per user per date. So 5 results of one kind are always on 5 different days, and the rule could never fire. If you want protection against a burst, the meaningful knob is a minimum span between the oldest and newest of the 5, not a day count. I'd leave it out until data shows bursts.
- **5 / 4 / veto 2-of-3: keep.** For daily kinds (code review, design comparison) that is one week. For rare kinds it is weeks to months, and within the 60-response read some may never reach 5. That is accepted, and stated in CLAUDE.md.
- **Add: rubric stamp required** (above), since the AI rating now decides alone.

## Files and risk
About 40 files.
- **New:** service, evidence, migration, 2 controllers, partial, Stimulus controller, spec doc.
- **Removed or renamed:** TrackGraduation (2), the 2 old controllers, the partial, the JS controller and their code notes.
- **Edited:** `user.rb`, `profile_controller.rb`, `api_keys_controller.rb`, `dashboard_controller.rb`, `routes.rb`, `en.yml`, `edit.html.erb`, `_learning_track`, `exercise_section.rb`, `code_review.rb`, `learning_track.rb`, `CLAUDE.md` (the "Junior learning track" section and the File Map).
- **Specs:** about 12 renamed or edited, plus new ones; `setup.html` snapshot.

**Riskiest piece:** generalizing the level-change cutoff (`record_level_changes`) to every account and to skill_level changes. It runs on every preference save, and a mistake there silently hides or resurrects evidence. The schema migration with ignored columns is second.

## Changes requested at review

1. **Old routes kept one release as aliases, not redirects.**
   - `app/javascript/code_gym/request.js:36` treats any followed redirect as an expired session ("The only redirect a JSON endpoint gives is to the login page"). So a 307 from an old tab's dismissal would show "your session expired" and save nothing.
   - Instead, `POST /learning_track/dismissal` and `/learning_track/answer` route straight to the new controllers for one release. A comment names the removal; a later PR drops them along with the ignored columns.
   - A request spec covers both old paths.
2. **`record_level_changes` specs** (`spec/models/user_level_changes_spec.rb`):
   - a target edit through `PATCH /profile` records `{level: new rung, through: today}`;
   - Apply (the same endpoint, adding one key) records it for that kind only;
   - a `skill_level` change records it for every *untargeted* kind and none for targeted ones;
   - no cutoff when the rung is unchanged (same target re-saved; skill level changed but the kind is targeted);
   - a round trip, junior→mid→junior: the junior cutoff is today's, so junior results from before the first move never count again, and a stale entry at another level is replaced rather than reused.
3. **Once per kind per day: where it is enforced, and the pin.**
   - Enforced by the unique indexes `index_daily_exercises_on_user_id_and_date`, `index_daily_responses_on_user_id_and_date` and `index_daily_responses_on_daily_exercise_id` (`db/schema.rb:91,112,113`), plus `problem_set` being a hash keyed by section, so a kind appears at most once in a day's set.
   - Carry-forward re-dates a held set only when today has none.
   - Pin: an evidence spec asserting a kind's results carry distinct dates, and a schema spec asserting those three indexes exist and are unique.
4. **Card copy computes its claim.**
   - Up: "{n} of your last 5 {kind} sections were reviewed solid or better. Try {kind} at {level}?", where `{n}` comes from the step's evidence.
   - The "most felt manageable" clause is removed: the veto checks only the latest 3, so the claim isn't guaranteed.
   - Back: "{m} of your last 3 {kind} sections at {level} felt too hard. Move {kind} to {lower level}?"
5. **Renames in their own commits, and two PRs (recommended).**
   - **PR 1 — the rule, track accounts only.** One new table (`level_suggestion_events`), no columns on `users`, no renames. In `TrackGraduation` as it stands:
     - the ladder;
     - 5/4 favourable, with the veto;
     - rubric required;
     - step back one rung, with the AI veto;
     - bundle removed (with `learning_track_lead`);
     - not-now sticking at the current rung;
     - the computed card copy;
     - `record_track_level_changes` covering mid-level;
     - the evidence snapshot table.
     
     Small, reviewable, and it fixes finding 4 for the accounts that have it today.
   - **PR 2 — every account.**
     - Rename commits first (pure moves: TrackGraduation→LevelSuggestion, partial, Stimulus controller, routes with aliases).
     - Then the migration with new columns and ignored old ones.
     - Then `record_level_changes` for all accounts and skill_level.
     - Then the Setup switch move, the welcome and hint copy, and the stricter isolation spec.
     
     The riskiest piece lands alone, behind a rule already proven on track accounts.
   - **Branch handling (decided: sequential, not stacked).** The harness pins one branch, `claude/adoring-dirac-7fk2m5`. PR 1 goes there now. PR 2 starts only after PR 1 merges, on the same branch restarted from the new main.

## Reports requested at review

**(a) How many results a kind can collect within the 60-response read.**
- Fixed kinds appear every day: 60 appearances.
- At **2 sections**, optional kinds appear only through the coverage exception: at most one addition per 5 weekdays, so 12 per 60. Spread across 8 kinds, that is **at most 2 each; none can reach 5.**
- At 3 and 4 sections I simulated `SectionRotation` (logic copied inline, 3,000 runs, warmed up past the starvation drain):

  | Sections | Mean (min) appearances in 60 days |
  |---|---|
  | 3 | pattern 6.8 (6); thirds 7.7–7.8 (5–6); fourths 7.4 (6) |
  | 4 | pattern 13.9 (11); thirds 14.4 (8–9); fourths 16.2 (9–11) |

- Appearances aren't results. A result also needs the section answered, reviewed, rubric-stamped and not eased.
- **So at 3 sections, an optional kind reaches 5 only if about 70% of its appearances are answered and un-eased.** At 4 it's comfortable; at 2 it's impossible.
- The 2026-10-01 production replay (CLAUDE.md) found about one section answered a day, so today most accounts sit at 2. **For them only code review and design comparison can ever be offered.**

**(b) Your account's rubric-stamped results by kind:** not available. No read-only copy of production exists (CLAUDE.md lists web, worker and one Postgres), and I won't read the live database. A console one-liner you can run yourself, read-only:
`ReviewedSectionResults` over `user.daily_responses.submitted`, with `require_rubric: true`, grouped by `kind` and `level`, tallying `ai_rating` and `self_rating`.

**(c) `finish_learning_track` with mid-level** (user.rb:474):
- It ends the track as soon as no target is `junior`. With the ladder, a track account that moves its last junior kind to **mid-level** leaves the track, though no kind has reached senior. Today that only happens at senior.
- Effect in PR 1: suggestions stop for that account, because PR 1 is still track-only. **I'll change the condition to "no target below senior" in PR 1**, so the track ends where its copy says it does.
- **Known gap until PR 2:** a track account whose kinds all reach senior leaves the track, and with it every suggestion, step-backs included, because PR 1 still shows suggestions only on the track.
- In PR 2, suggestions no longer depend on the track. Ending it then only removes the on-track Setup line and Leave; rejoining is still refused.

**(d) An evidence snapshot at Apply and dismissal.**
- New table `level_suggestion_events`. Columns:
  - `user_id`, `kind`;
  - `action` (`applied` | `dismissed` | `removed`);
  - `source` (`suggestion` | `setup_edit`, applied rows only);
  - `from_level`, `to_level`;
  - `window_size`, `favourable`, `too_hard_latest3`, `newest_result_on`;
  - `created_at`.
- Every count is recomputed on the server from stored results at `from_level`. Nothing the client sends is trusted.
- **Applied rows: written where the server detects the rung change.**
  - In `record_track_level_changes` (`record_level_changes` in PR 2), every saved rung change becomes one `applied` row, however it arrived (card Apply, Setup edit, or Setup reached from the card's link).
  - `source` is decided by the server. Before the save, it computes the proposal from the levels in the database (`TrackGraduation.proposal(levels: section_kind_levels_in_database, …)`). The change is `suggestion` when suggestions are switched on for the account and that proposal contains a step for this kind with this destination; otherwise it is `setup_edit`. With suggestions off, no offer was on screen, so every change is `setup_edit`.
  - Detection runs in `before_save`; the rows are inserted in `after_save`, inside the same transaction as the level change.
  - The answer endpoint only counts, as today.
- **Dismissed and removed rows** stay in the dismissal endpoint, written before the cutoff. The card's dismissal request gains `reason: not_now | removed`; that only labels the row. The kinds are validated as today.
- Nothing is written on render.
- "Stuck" is measured later by joining a row to the kind's level and results afterwards. No reader is built now.
- The table is in PR 1. Its migration is reversible (`down` drops it).

**What this loses against the answer-endpoint design: nothing it would have captured.**
- The answer request fires only after a successful Apply and is best effort (its failure is already tolerated), so it could miss applies. The model callback can't.
- It sees every change, including a Setup edit made from the card's "Change it in Setup" link. The answer endpoint never sees those, since only the card calls it.
- One trade: `source: suggestion` now means "matched the proposal the server would have shown at save time", not "clicked Apply on the card". A Setup edit that happens to match a pending proposal is labelled `suggestion`. I count that as correct, since the suggestion is what it answers.
- Cost: the evidence query runs on level-changing saves, which are rare. Other saves don't run it.

## Known limit: rare kinds
- **At 2 sections**, only code review and design comparison can ever reach 5 results. Optional kinds appear at most twice in the 60-response read.
- **At 3 sections**, an optional kind reaches 5 only if about 70% of its appearances are answered and not eased.
- There is no account-level path for the other kinds: nothing lets evidence from one kind, or from the account as a whole, justify an offer for a kind that lacks its own 5 results. Those kinds move only when the user edits them in Setup.
- No fix is planned here; that decision comes before PR 2.

## Phase 2: PR 1 (approved)
Scope: the rule for track accounts only. One new table, no columns on `users`, no renames, no Setup move.

1. Restart the designated branch `claude/adoring-dirac-7fk2m5` from `origin/main`. It holds no unmerged work.
2. Commit this plan as `docs/superpowers/specs/2026-10-14-level-suggestions.md`, its own commit.
3. Implement in `TrackGraduation` and its existing files, TDD per piece, logic commits only:
   - **Rule specs** (`spec/services/track_graduation_spec.rb`):
     - walkthroughs A and B;
     - the veto (one too hard in the latest 3 doesn't block; two do);
     - not-now: re-offer needs 5 post-cutoff results at the current rung, and results at another rung never count;
     - the ladder: junior→mid→senior, principal never a candidate or destination, a mid-level kind is a candidate;
     - bundle removal: 0-result kinds never offered, `:led` gone;
     - step back one rung with the AI veto;
     - rubric stamp required;
     - minimum sample 5.
   - **Evidence spec:** a kind's results have distinct dates. **Schema spec:** the three unique indexes exist.
   - **`record_track_level_changes`** (`spec/models/user_level_changes_spec.rb`), for track accounts in PR 1:
     - target edit;
     - Apply;
     - no cutoff when the rung is unchanged;
     - the round trip;
     - the applied event row with `source` `suggestion` versus `setup_edit`.
     
     The skill_level-change case moves to PR 2, since track accounts' kinds are all targeted.
   - **`finish_learning_track`:** moving the last junior kind to mid-level keeps the track; the track ends when nothing is below senior.
   - **Events:** migration and model spec; dismissal endpoint rows with `reason`; nothing written on a dashboard render.
   - **Card:** the computed copy (counts from the evidence), the step-back wording, several kinds in one removable list (decision C), and `LearningTrack::LEVELS` replaced by the ladder in the dismissal check and Setup highlights.
   - **Isolation spec:** it passes unchanged, except the `learning_track_lead` fixture line becomes `"code_review"`. I'll say so in the PR.
   - **CLAUDE.md:** update the "Junior learning track" section, plus a code note for any file whose reasoning grows.
4. Verify:
   - rubocop and `bin/comment-check`;
   - the full unit suite, then `spec/system` (the track proposal system specs);
   - confirm 0 of 72 prompt snapshots and 0 of 5 page snapshots changed. PR 1 touches no Setup layout and no copy shown to the snapshot account.
5. Push, open a draft PR, subscribe to its activity, run the `critical-reviewer` agent on it, address its findings, then report.

## PR 2 (after PR 1 merges; listed so it isn't lost)
1. Rename commits: TrackGraduation→LevelSuggestion, partial, Stimulus controller, routes, with the old paths as aliases for one release.
2. Migration: `level_suggestions` and `level_suggestion_cutoffs`, backfill, old columns ignored. Spec covers backfill and rollback.
3. `record_level_changes` for every account, including the skill_level case.
4. Setup switch move, Experienced and Setup-hint copy, and the `setup.html` snapshot.
5. Request specs for a non-track account (card, Apply writes one target and leaves skill_level alone, dismissal, answer, highlights) and for the old route aliases.
6. The stricter isolation spec.

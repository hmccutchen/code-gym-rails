# Tracks

A track sets baseline difficulty, and it is
`skill_level` itself; nothing stores it a second time. Every kind follows
it unless that kind has a target of its own, earned through a level
suggestion or set in the Exercise mix. The welcome page at `/welcome` asks
once, offering one track per rung of `LevelSuggestion::LADDER` (Junior,
Mid-level, Senior), each described by what its exercises are like rather
than by a job title. A choice posts `choose_track: true` with its level to
`PATCH /profile`, which checks it under the user-row lock: exactly those two
keys, a level on the ladder, and `User#first_run?` still true, or a 422 that
saves nothing. `User#choose_track` sets `skill_level` and `track_chosen_at`.
No preset targets are written: since 2026-10-15 the generation prompt
states every kind's level whether or not it has a target, so an equal target
would change no generated rung that day, but would pin it during later track
changes. **Senior is the highest level
suggestions reach; principal engineer is set by hand in Setup**, and both
pages say so.

## Track and exercise mix

The decision in #709, agreed on 2026-11-05, is to keep track out of
kind frequency. Track supplies neither an initial exercise-mix preset nor
an ongoing rotation bias. Changing track does not rewrite exercise weights
or exclusions. The same kinds remain available across tracks, subject to
the user's explicit settings. Principal engineer remains manual-only, and
difficulty-lock protections remain unchanged. A junior can practise
architecture through a simpler problem, and a senior can still benefit
from a code-ordering exercise.

Today, `SectionRotation` selects optional kinds using history, weights and
exclusions; `DailyPlan` does not use track or per-kind difficulty to bias
the mix. `KindDifficulty#rung_for` resolves each kind's target or baseline,
and `GenerationPrompt::DifficultyGuidance` expresses those levels.
Each kind now supplies concrete expectations beside the shared rung
standard, reused by generation and grading (#718,
`docs/decisions/kind-difficulty-expectations.md`). The offline checks do
not establish live-provider calibration or equal difficulty across kinds.
Demonstrated practice needs and explicit preferences guide frequency under
the protected-practice and variety direction in #714, whose implementation
is separate from this decision.

## Graduation direction — not yet implemented

The direction agreed in #709 on 2026-11-05 keeps two layers of progression:

- **Per-kind advancement:** success at a kind's current difficulty can earn
  an opportunity to attempt harder work. Code review can move to mid-level
  while design comparison stays junior. Today's `LevelSuggestion` already
  offers per-kind changes that require an explicit Apply and leave the
  overall track alone (`level-suggestions.md`).
- **Overall graduation:** broad, sustained performance at the next level
  can justify offering an overall track change. This is a future offer,
  never a silent promotion. Success at the current level earns the harder
  opportunity; evidence from that harder work supports graduation.

The established "Suggest level changes" opt-out also applies to future
graduation: turning the switch off disables graduation offers. That policy
is settled, although graduation itself is not implemented.

A future graduation offer and its application must preserve easier
per-kind levels where more practice is needed. The weakest kind must not
hold back every other kind, and success in one kind must not make all
others harder. How to protect an untargeted kind that currently follows
the baseline remains undecided. The manual target-preservation change in
#720 preserves explicit targets, which does not settle that untargeted-kind
case or implement graduation's protection.

Per-kind difficulty, overall graduation and Automatic daily workload size
are separate decisions. The four-of-five rule approved in #715 concerns
growing the workload from two sections to three; it is not a graduation
threshold. Graduation recognizes ability demonstrated in the app's
exercises, not professional seniority, which also involves delivery,
collaboration and judgment in real projects. Senior remains the highest
level graduation may offer; principal engineer remains a manual choice.

Graduation's required breadth, evidence thresholds and time windows remain
open, as do other presentation details, wording and confirmation.
Eligibility still needs decisions about self-ratings, eased work, retention,
and unavailable or user-excluded kinds. It must neither require every kind to advance nor
treat missing evidence as demonstrated readiness. These questions and the
preservation behavior need their own specification before implementation;
this decision adds no graduation algorithm or UI.

## Current behavior and history

**`track_chosen_at` is a flag, not a clock.** `User#first_run?` is a saved
account with no `track_chosen_at` and no exercise.
`AddTrackChosenAtToUsers` shipped a release before any code read the
column, because the worker's pre-deploy waits for a schema, not for pending
migrations; it and `RepeatTrackChosenAtBackfill` set it to `created_at` for
every account with a `learning_track`, so accounts that predate it hold their
creation time. A null value means no choice was recorded, which is not the
same as undecided: accounts the nightly batch generated for before they
opened `/welcome` hold null and are past first run because they have
exercises. The exercise check also keeps the preview app's seeded account
from being asked.

**`learning_track` goes in two releases.** For the release that made the
skill level the track (#398), a choice also wrote `learning_track: "none"`,
so code rolled back to before it neither re-asked the account nor showed the
old Leave control, and `first_run?` still read the column so an account
that answered the old welcome page in that deploy gap was not asked again.
The next release stopped there: `FinishTrackChosenAtBackfill` repeats the
`track_chosen_at` backfill once more, guarded by `track_chosen_at IS NULL`,
for any account that answered the old page in #398's own deploy gap, and
`User` then lists the column in `ignored_columns`, with the write, the
validation and the `first_run?` read gone. A release that drops the column
while code still reads it would raise `MissingAttributeError` on every
`first_run?` check between the migration and the new code taking traffic,
which is why the drop waits one more release, as `RemoveApiKeyFromUsers`
and `RemoveTrackLeftoversFromUsers` did. Rolling back one release is safe
either way, since #398's code reads `track_chosen_at` first; rolling back
two re-asks accounts that chose under the ignoring release. A post that
carries `learning_track` still comes from a page rendered before tracks
per level and gets a 422 asking for a reload (`tracks.stale_page`); that
guard reads the request, not the column, and stays. Leave the track,
`finish_learning_track` and the junior preset are gone: the "Suggest level
changes" switch stops today's per-kind suggestions. Its established opt-out
for future graduation is specified in "Graduation direction — not yet
implemented" above. In specs, `create_user_with_key` and
`create_fake_provider_user` stand for accounts that chose a track; a first-run
spec passes `track_chosen: false`.

**Manual track changes preserve explicit targets and locks (#720).**
A target equal to the old or new baseline is still an explicit choice:
unlike an unset target, it must stay put during future track changes.
The earlier clearing policy, adopted on 2026-10-15, is removed.
`TrackChange` is a pure consequence calculation through `KindDifficulty`.
It lists every registered kind that changes effective rung and every retained
target with its lock status. It never writes settings.

Selecting a track, including an edit before scripts connect, requests a
read-only `POST /profile/track_preview` for the authenticated current user.
Setup displays the server-rendered consequences with Apply and Cancel.
An all-targeted account can still change its baseline without moving a kind;
the preview explains that future kinds following the track use that baseline.
Selecting an already-saved track is reported as such, never as a future move.
Cancel restores only the latest confirmed saved track select and value row.
Other settings retain their independent autosaves.

Apply uses `PATCH /profile` with a closed `track_change` confirmation:
`from`, `to`, and integer `preferences_version`. Under the existing user
lock, `ProfileUpdate` validates its shape and destination, then compares
both its baseline and version with the reloaded row before assignment.
A baseline-only change does not bump the preference version, so comparing
only that version would accept stale consequences. A 409 carries the current
baseline, refreshes the preview and requires another explicit Apply.
No retry replaces the old confirmation with newer values.
Welcome retains its exact first-run Continue exception under the same lock.

The preview waits for pending autosaves, including the Exercise mix's 400ms
delay, and does not ignore failures from other settings. Selection, Cancel
and mix edits invalidate earlier preview callbacks. Apply stays on the
shared `exercise_mix` queue, with the existing pending-edit flush before it
and newer-local-edit adoption after it. Saved labels change only when a
server reply confirms the saved baseline. Failures remain visible; refreshing
after a lost successful reply can confirm an already-saved track without
another write.

`LevelChange` records cutoffs and event rows only for actual effective-rung
movements, with its existing first-choice and principal-rung cutoff rules.
Preserved targets create no false movement, cutoff or event. Weights,
exclusions and all other settings remain untouched. No bulk reset, graduation
offer, or planner policy is added.

**Existing accounts were told apart by a backfill, not a date.**
`AddLearningTrackToUsers` added the nullable string and
`BackfillLearningTrackForExistingUsers` set every row it found to `"none"`,
so an account that predates the old junior track was never asked; the
`track_chosen_at` backfill carried that forward.

**The preview migration version is reconciled.** The PR app first added
these controls under `20261011040000`, which main then used for
`MakeDailyResponseExerciseUnique`. Renaming the controls migration to
`20261011050000` lets it run where the columns already exist, but Rails
still considers the response-index migration applied. The later
`ReconcileDailyResponseExerciseUnique` checks for the unique exercise index
and, only when absent, runs the original migration's duplicate cleanup and
index change. It keeps the original response-ranking rule in one place.
A database with the correct index is untouched; rolling back reconciliation
leaves the index in place, since the original migration owns its rollback.

Setup shows the key guide to an account with no key of its own and no
exercise yet, and to an ended trial. Its copy remains scrollable: in Chromium at 390×844, the guide is about 893px
tall at default text, 1,321px at 125%, and 1,681px at 140%, measured in an
older headless Chromium once the OpenAI section was added (the same build
measured the guide without it at 711, 1,069 and 1,340). Even at default
size it extends below the initial viewport; enlarged text needs vertical
scrolling. There is no unconditional one-screen promise or hidden content.

**Operator preparation was retired with shared wording.** Until
2026-11-13 an operator ran a pair of junior ladder preparation scripts under
`script/` to report junior ladder coverage and,
with `--run`, queue missing ladders on their own key for every user's shared
reference. Learn content became per user that day
(`learn-content-per-user.md`), so a refresh on one key no longer reaches
anyone else, and both scripts were removed. Each account prepares its own
ladders from Setup's "Prepare AI guidance" (see
`difficulty-targets-and-locks.md`).

**Production coverage before any run, 2026-10-08.** The retired report step,
run against production, grounded 5 of 90 code review pairs, 3 of 48 design
comparison, 5 of 90 pattern, 5 of 90 challenge, 5 of 42 Parsons, and none
of architecture (0/15), security review (0/4), plan review (0/4), ambiguity
hunt (0/5) or pseudocode to code (0/8), leaving 117 concept and language
pairs without a ladder once duplicates across kinds are counted once. The
`--run` step has not been taken, so the billed cost and the coverage after
it stay unmeasured.

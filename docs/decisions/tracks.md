# Tracks

a track is the person's overall level, and it is
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
states every kind's level whether or not it has a target, so a target equal
to the skill level would change nothing. **Senior is the highest track
graduation reaches; principal engineer is set by hand in Setup**, and both
pages say so.

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
changes" switch is the way to stop suggestions, and graduation will follow
it. In specs, `create_user_with_key` and `create_fake_provider_user` stand
for accounts that chose a track; a first-run spec passes
`track_chosen: false`.

**Every track change clears the targets the track now covers.**
`TrackChange` is the one statement of the rule: an unlocked target equal to
the old or the new level is cleared, so that kind follows the track again;
every other target stays, including a locked one and, on a two-rung move,
one between the two levels. `User#apply_track_change` runs before every save
and holds the change for a save that moves the track after the first
choice. It is declared ahead of `bump_section_kind_preferences_version`, so
a skill-level-only save that clears targets also bumps the version and an
Exercise mix open in another tab gets the usual 409. A cleared kind whose rung
moves gets a cutoff and a `skill_level_edit` event row, like any kind the
skill level moved. Setup's track select saves through the same endpoint; the
reply carries the preference state the Exercise mix adopts in place (the
`profile-preferences:trackSaved` event) and one sentence naming the sections
that kept their own level. Once presets stop being written, a target equal to
the old level can't be told apart from one chosen on purpose, so a deliberate
target at the old level is cleared too and only a lock protects it; that was
decided on 2026-10-15. Showing what a change will do before the select saves
is a follow-up, and graduation's card will show it from the same `TrackChange`.

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

**Operator preparation rewrites shared wording.** Run
`bin/rails runner script/prepare_junior_ladders.rb <operator_user_id>` first
for per-kind coverage and deduplicated gaps across both languages.
It writes nothing. Adding `--run` queues missing ladders through
`GenerateConceptReferenceJob` with `refresh: true`, billed to that active
operator's own key. A refresh rewrites the whole shared reference and guide,
including rows that already have a guide, for every user. Since 2026-10-15
the report reads every kind at junior, the unsaved user's default skill
level, where it read the union of every rung before; the 2026-10-08 figures
below were measured the old way, and only design comparison differs. It is
no longer the only bulk path: Setup's "Prepare AI guidance" now covers every
section's level for any account with its own key (see
`difficulty-targets-and-locks.md`).

**Production coverage before any run, 2026-10-08.** The report step, run
against production, grounded 5 of 90 code review pairs, 3 of 48 design
comparison, 5 of 90 pattern, 5 of 90 challenge, 5 of 42 Parsons, and none
of architecture (0/15), security review (0/4), plan review (0/4), ambiguity
hunt (0/5) or pseudocode to code (0/8), leaving 117 concept and language
pairs without a ladder once duplicates across kinds are counted once. The
`--run` step has not been taken, so the billed cost and the coverage after
it stay unmeasured.

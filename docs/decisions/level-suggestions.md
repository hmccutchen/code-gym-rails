# Level suggestions

every account with `users.level_suggestions` on
(default true) can be offered a one-rung move for a section kind on the
submitted dashboard, and nothing moves without an explicit Apply. A kind is
read at its rung (`User#kind_rungs`, from `KindDifficulty#rungs`): its
target when one is set, else the skill level, which is what generation
pitches it at. So an account with no targets is offered moves too, and
Apply then writes one target for that kind and leaves `skill_level` alone.

**The rule uses reviewed work, not mastery tiers.** `LevelSuggestion`
moves an unlocked kind one rung along junior, mid-level and senior
(`LevelSuggestion::LADDER`). Principal engineer is set only by hand, so no
suggestion leaves it or leads to it. A step up needs the kind's latest five
results at its current level, at least four of them rated solid or better
by the AI, and fewer than two of the latest three self-rated too hard: the
AI rating proposes and the engineer's own rating can veto. A step back
mirrors it: at least two of the latest three self-rated too hard (two of
two qualifies) propose one rung down, and the AI vetoes it when it rated
every one of those solid or better. Those too-hard results must also span
two distinct valid concept/bucket identities; missing tags prove no breadth.
A step back is shown alone, before any
step up. Step ups for several kinds share one card when they start from the
same level, so every kind it lists moves to the same one; registry order
picks that level, and the other kinds wait for a later card. Each kind is
judged on its own results only: there is no lead kind and no bundle, so a
kind without its own five results is never offered a step up. Locked kinds
are omitted; exclusions remain a scheduling preference.

`LevelSuggestion::Evidence` uses `AdaptationHistory.each` over the last
180 user-local calendar days (today minus 179 inclusive), preloading
exercises in cursor batches without a global response-count cap. Identifiable
supplementary bug hunts supply no up/down evidence, cannot clear a veto,
advance newest dates or occupy that window. Other weekend core work keeps
its effects. Only assessed,
un-eased sections with a `pitched_at` stamp, an AI rating and the current
`ReviewedSectionResults::RUBRIC_VERSION` stamp contribute, because the AI rating now
decides alone and only a rubric grade rates against the stated level.
Raising `RUBRIC_VERSION` restarts suggestion evidence and strict workload
proof, but basic workload completion/recovery retain unversioned grades.
Historical bug exclusion may change pending proposals without rolling back
applied levels. The AI rating's calibration for these moves is unverified,
and suggestions require an explicit Apply.

The selector applies `.reviewed` and the shared
`ReviewedSectionResults.with_current_rubric` SQL prefilter before loading
responses and exercises. Neither proves strict eligibility; the full Ruby
projection still rejects malformed, inactive, skipped, eased or unstamped
sections. Candidate batches use `AdaptationHistory::BATCH_SIZE`, independent
of the calendar evidence window. Each kind keeps at most one result per
date, and an offer requires its newest result within the last 30 days
(today minus 29 inclusive).

**Opportunities do not guarantee qualification.** A kind still needs five
normal results of its own for an up offer. Enrolled Automatic two-section
sets provide bounded variety opportunities within capacity; unanswered,
eased, stale or old-rung work cannot qualify. See
`protected-practice-opportunities.md` for the cadence and CI simulations.

**A cutoff keeps the same work from proposing another move.**
Not now records each kind's current rung and the newest retained strict result
date, falling back to the user's today, so an offer returns only on newer
results at that rung, five of them for a step up. Any change to a kind's
rung, for every account, records the destination rung and today's date in
the user's zone (`LevelChange#record_cutoffs`): a target set, edited or
cleared, and a skill-level change, which moves every kind without a
target. A rung that did not move records nothing, and a move to principal
engineer records nothing. The first-run track choice records nothing. So
results from an earlier stay at a rung never count again. Moves made before
these cutoffs existed left no trace, so `SeedLevelSuggestionCutoffs` gave
every existing account a cutoff for each kind at its rung on the migration
day, keeping any cutoff it already had: each account starts from five new
results, and no card appears for at least five reviewed days after deploy. Evidence through
a cutoff's date is ignored at its rung, and results at any other rung
never count. Every save that touches a target or the skill level runs
under the user-row lock (`ProfileUpdate#locked_save?`), and so does
dismissal, which merges into the reloaded map and keeps a later valid
cutoff at the current rung. Its earlier evidence read cannot undo a newer
dismissal or level-change cutoff. A different-level or malformed entry is
replaced; `LevelSuggestion.cutoff_date` is the shared reader for dismissal
and proposal filtering.

**The page posts the moves it showed, and the server checks them.** Apply,
Not now, a Keep set aside after Apply, and a Setup save opened from the
card's link send each move as a `LevelSuggestionStep`: the kind, the rung
it was shown at and the rung offered. `PATCH /profile` takes them as
`level_suggestion_steps` and the dismissal endpoint as `steps`. Under the
row lock, after the version check, each `from` must equal the kind's
stored rung, or the request gets the existing 409 and saves nothing; a
skill-level change bumps no `section_kind_preferences_version`, so without
this a card left open could move a kind down after the skill level rose in
another tab. A step the request does not save, or one that is not a
one-rung move, is a 422. The card reloads on a 409 once pending saves
clear, as it always did for a stale Apply.

**Event rows.** `level_suggestion_events` records `applied` rows with
source `suggestion` (a target change matching a checked step),
`setup_edit` (any other target change, Default included) or
`skill_level_edit` (a kind moved only because the skill level changed,
one row per kind, so a bulk move can be told apart), plus `dismissed` and
`removed` rows. `from_level` and `to_level` are rungs, so a reset to
Default records the skill level's rung, where #390 recorded nil. Each row
carries the evidence counts behind it, computed at write time, so they can
differ from the card's numbers when a review lands in between. Rows are
written only by rung-changing saves and the dismissal endpoint, which
writes a row only for a kind whose cutoff moves forward and labels it with
the `to` the card showed. A dismissal from a tab opened before steps were
sent falls back to the proposal recomputed at write time. A dismissal
whose user row fails validation answers the card's JSON 422 rather than
Rails' HTML error page.

**Setup and dashboard saves settle in place.** Apply changes only the kinds
still listed through the existing versioned profile endpoint, then
dismisses the ones set aside with Keep separately, with reason `removed`.
That second request is tracked as pending, but the two writes are not
atomic: its failure leaves the applied levels saved and the shared save
error visible. Not now dismisses every kind the card listed, with reason
`not_now`. A stale Apply or Not now (409) reloads only after pending saves
clear; a save still pending after ten seconds cancels the reload.

**After three answers, a proposal sends the user to Setup.**
`users.level_suggestion_answers` counts each Apply and Not now through
`POST /level_suggestion/answer`, for every account, which the dashboard
sends once the save has succeeded. A lost count delays the switch to Setup
without undoing the choice; its warning says the choice was saved and need
not be repeated. Below
`LevelSuggestion::IN_PLACE_ANSWERS` (3) a proposal applies in place. From then
on its main button links to Setup's Exercise mix with the proposed kinds
marked and the level named (`?suggested[]=…&suggested_level=…`), and the
user changes the level there, so they learn where the control lives. Setup
renders each marked kind's step, and choosing the marked level sends it
once. Not now still dismisses in place, and a card sent to Setup has no Keep
buttons, since the choice is made there. A proposal naming an
excluded kind keeps applying in place, because Setup disables an excluded
kind's difficulty and the user would have nothing to change. The threshold
is a starting value, not a measured one.

**Suggestions can be turned off and back on.** Every proposal links to the
"Suggest level changes" switch at the top of Setup's Exercise mix
(`/setup?show=level_suggestions#level-suggestions`, which renders the mix
open and moves focus to the switch). While it is off the dashboard
computes no proposal; turning it back on resumes them with every cutoff as
it was. Reads span the same 180-day range in cursor batches. Ineligible rows
cannot advance newest result dates, and other kinds cannot evict this
kind's evidence. Each kind's current-rung and explicit-cutoff rules still apply.

**Renamed from the track.** This was `TrackGraduation`, for junior-track
accounts only. The endpoints moved to `POST /level_suggestion/dismissal`
and `/answer`. `AddLevelSuggestionColumnsToUsers` and
`AddLevelSuggestionAnswersToUsers` copied the track columns into
`level_suggestions`, `level_suggestion_cutoffs` and
`level_suggestion_answers`. For one release the old columns stayed in the
table, ignored by `User`, the old `/learning_track/…` paths routed straight
to the new controllers, and `PATCH /profile` still took the old
`track_suggestions` key, so the old code and tabs opened before the deploy
kept working. `RemoveTrackLeftoversFromUsers` (#394) then dropped the
columns, and the old paths and key went with it.

Generation, review, both judges, `ConceptMastery` and `KindDifficulty`
never read track or suggestion state;
`spec/services/level_suggestion_isolation_spec.rb` pins that separation and
byte-identical generation/judge calls for equal difficulty settings, on or
off the track and with suggestions on or off.

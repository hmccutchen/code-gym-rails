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
every one of those solid or better. A step back is shown alone, before any
step up. Step ups for several kinds share one card when they start from the
same level, so every kind it lists moves to the same one; registry order
picks that level, and the other kinds wait for a later card. A daily kind
is judged on its own results only. A rotated kind is judged on its own
results or on the window it shares with the other rotated kinds, described
below. There is no lead kind: a daily kind's results never move another
kind. Locked kinds are omitted; exclusions remain a scheduling preference.

`LevelSuggestion::Evidence` preloads exercises for the latest 60 submitted
responses with stored review data. Only reviewed responses and answered,
un-eased sections with a `pitched_at` stamp, an AI rating and the current
`ReviewedSectionResults::RUBRIC_VERSION` stamp contribute, because the AI rating now
decides alone and only a rubric grade rates against the stated level.
Raising `RUBRIC_VERSION` restarts suggestion evidence, as it does for the
competency gate. The AI rating's calibration for these moves is unverified,
and suggestions require an explicit Apply.

**Rotated kinds share one window.** A rotated kind fills about one
three-section day in eight, so five results of its own take about 40 days,
and the 60-response read holds about seven of its appearances. Left to its
own results it almost never earned a card (#712). So the kinds the account
does not hold daily (`LevelSuggestion.pooled_kinds`, every kind outside
`DailyKinds.for`) share a window at each rung, `LevelSuggestion::PooledWindow`:
the latest five results across the rotated kinds at that rung, each kind's
results counted only at its current rung and after its own cutoff. A result
enters the window only when its kind was outside the daily kinds its own day
was planned with (`Result#rotated`, from the row's `plan_notes`, as the
competency gate reads it), so a swap or a change of the Daily sections
setting never turns a former daily kind's dense history into pool
evidence. Results from one day keep registry order, which decides the fifth
place when two rotated kinds tie on a four-section day. When four
of the five are solid or better, the card lists each rotated kind that has a
result in the window, has no result there below solid, is unlocked, and has
fewer than two too-hard ratings among its own latest three. A kind with no
result in the window waits, so no kind moves on other kinds' work alone. A
locked kind's results still count in the window. A rotated kind with five
results of its own at the rung is judged on those alone, pass or fail, so
more evidence about a kind never lowers the standard it is held to.

On three-section days the first card for rotated kinds can come after five
reviewed days, the pace of the daily kinds. On a two-section day the
coverage exception adds about one rotated section every five weekdays, so
five pooled results take about five weeks. One pool for all rotated kinds
was chosen over one per slot group: per-group pools compare more alike
kinds, but the thirds would need about 10 days, the fourths about 14, and
pattern, alone in its group, would stay at about 45. The cost is that a
solid result in one kind counts toward a move in an unlike one; the
requirement of a kind's own solid result in the window, Keep on the card
and the per-kind step back limit it. A step back still reads only the
kind's own results.

A pooled move's step carries `pooled: true` and the window's favourable
count, which the card shows. Its event row carries the kind's own counts
like any other row. An own move needs a full window and a pooled move
needs a short one, so a `suggestion` row was a pooled move exactly when
its `window_size` is below five.

**A cutoff keeps the same work from proposing another move.**
Not now records each kind's current rung and the newest reviewed response
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
it was. The submitted dashboard's evidence read is capped at 60 responses,
so it stays about flat as history grows: about 32 ms at 60 reviewed days
and 38 ms at 250, measured in a development sandbox.

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

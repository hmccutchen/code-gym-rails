# Pausing generation

`User#paused_generation_at` (nullable timestamp; nil is active) suppresses only generation the user didn't ask for — the hourly hand-out (`EnqueueDueGenerationsJob`, and the scheduled per-user job it enqueues, which reads the pause again when it runs; both ask `ScheduledGeneration.users`) and `DashboardController#show`'s auto-trigger. It never gates submitting or reviewing: `ResponsesController` has no pause check, so once a row exists for today the submit → review chain runs regardless of pause state or weekday. The toggle is `PATCH /account/toggle_generation`, the one action that pauses or resumes at a person's request; the Account page's buttons post to it, and so do the two controls on the dashboard's automatic-pause line (see "Pausing after unopened sets" below). The hourly hand-out is the only other writer of a pause, and both go through `User#pause_generation!`. Each button posts the state it wants (`paused=0`/`1`) rather than asking for a flip, so a double-tapped Resume stays a resume instead of the second request re-reading an already-unpaused user and pausing it again; with no param posted the endpoint still flips, keeping its original contract. Days fully inside a pause create no `DailyExercise` row at all, so they are non-events to `User#recent_exercise_history` and `#current_streak` rather than skips. The one day that *does* leave a row is the day the pause began (or an explicit `/generate` while paused). **A set left unfinished when the pause began follows the user forward**: `DashboardController#show` calls `User#carry_held_set_forward!` on a day with no set, which re-dates the held, still-unsubmitted exercise — and the draft `DailyResponse` autosave left on it, which must move too or `#create` would build a second response for the same exercise — to `Date.current`, so the pause gives time to finish rather than hiding the set at midnight. Once it is submitted, `#held_exercise` finds nothing, the paused day stays empty and nothing generates, which is what the pause is for. `User#resume_generation!` performs the same recovery (`#recover_held_set`, shared) and then lifts the pause. The row lock also settles the race against a concurrent generation, and does it through the foreign key rather than directly: inserting today's exercise needs a FOR KEY SHARE lock on the same `users` row that `with_lock` holds FOR UPDATE, so a generator either committed before the lock (and the `exists?` check sees it) or blocks until after it and loses its own set to the unique index, which `GenerateDailyExercisesJob` already treats as "generated concurrently". Resume wins, which is the right way round — the held set carries the user's draft answers and a fresh one would not. The move takes both locks through `DailyExercise#with_response_locked`, the one exercise-then-response order every writer of both rows uses, so it and `RegenerateExerciseJob` serialize but cannot deadlock, and it re-reads the response under its lock, since `#held_exercise` read it outside any lock and a submit can commit in between; a submitted response ends the move, so a finished session keeps its day. It still sits in a SAVEPOINT catching both `RecordNotUnique` and a `date`-taken `RecordInvalid` (uniqueness is enforced twice, and the model validation raises first), so that were it ever to fail it rolls back only itself and the pause still lifts. Recovering the set also clears a same-day `last_generation_error`, since `/generate` is not pause-gated and a failed attempt while the held set sat at an earlier date would otherwise leave "Couldn't generate a new set" rendered above it — the banner `persist_failure` exists to avoid. The whole method runs in the user's own zone rather than the caller's, unlike the read-only history and streak readers, since it writes a date that has to be the user's today. That move both makes the set reachable (every "today's exercise" lookup is `for_date`, so at its original date it renders nowhere and `#create` 404s) and drops it out of both signals at once, since `recent_exercise_history` filters `date: ...Date.current` and `#current_streak` exempts today — no separate "exclude paused days" rule exists or is needed. Scoped to exercises dated on or after the pause, so a day abandoned *before* pausing stays abandoned; skipped entirely if an exercise already exists for today, so an explicit `/generate` while paused is never overwritten. Both regeneration columns clear on the move, because they describe the row's *day* rather than the set: `regenerated_at` would hide the Generate-new-set button behind a claim the dashboard states outright and that is no longer true ("You've already generated a new set today"), and a leftover `regenerating_since` is worse than cosmetic — `RegenerateExerciseJob` gates on `exercise&.regenerating_since` after resolving `for_date`, and re-checks that claim under the exercise row lock before it writes, by value rather than presence (the claim's timestamp is the worker's token, so a later click's claim is not mistaken for its own) — a claim `carry_forward` cleared mid-call means the generated set is discarded, and every release is guarded the same way, so a retry stranded from the pause day cannot replace the carried-forward `problem_set` or destroy the draft response the move preserved. **At most one set can ever be carried forward**, because `[user_id, date]` is unique — so a user who stranded several (paused Monday, clicked `/generate` on Tuesday, resumed Wednesday) gets the newest one back and the older ones stay where they are — **still breaking `#current_streak`**, not merely counting as skips: a past weekday holding an unsubmitted exercise hits that method's `exercised.include?(day)` break. Recovering one set does not repair a streak an older stray still zeroes. That is a limit of re-dating rather than a gap to close: two sets cannot both be today. Re-pausing does not move the floor `#held_exercise` searches from — `User#pause_generation!` stamps a pause only when one isn't already running — so a second Pause cannot walk that floor past the set the first pause stranded. The same limit is why the move is skipped outright when today already holds an exercise. **Accepted consequence:** finishing a carried-forward set counts toward the completion-window signal and the streak for the resume day, not the day it was generated.

## Pausing after unopened sets

Decided by the owner on 2026-11-11, before the app was shared with people
who use their own provider key. An account that stopped visiting used to get
a set every weekday, billed to its key, until its owner paused or deleted it.

**The rule.** If three sets in a row go unopened, generation pauses. The
count is `UnopenedSets::PAUSE_AFTER`.

**What unopened means.** A set is unopened when all of these hold:

- its day has ended in the user's time zone;
- `opened_at` is empty, so the dashboard never showed it to its owner and
  no resume has acknowledged it;
- it has no `daily_responses` row, so nothing was saved against it.

A set the user opened and left blank is not unopened. Neither is one with a
single autosaved keystroke. A set whose day is still running is not unopened
either, so it stops the run for now.

**What "in a row" means.** The last three sets by date. A day with no set is
skipped: it neither counts toward the three nor resets the run.

| Day | Counts toward the three? | Resets the run? |
|---|---|---|
| Set generated, never opened or saved | yes | no |
| Set opened or saved, submitted or not | no | yes |
| Generation failed, so no set exists | no | no |
| Weekend, or a day already paused | no | no |

An account with fewer than three sets is never paused by this rule.

**Where it is decided.** `UnopenedSets.pause?` is a pure decision object. It
takes each recent set's date, whether it was opened and whether a response
row exists, plus today's date in the user's zone, and reads no database.
`DailyExercise.latest_openings` reads those values for it.

**When it is asked.** The hourly hand-out (`EnqueueDueGenerationsJob`) asks
before it would enqueue a scheduled generation, so only for a due account
with no set today. On yes it pauses the account with source `automatic`,
enqueues nothing and logs one line with the user id.
`ScheduledGeneration.users` already leaves paused accounts out, so later
runs skip it.

**Not while a migration is pending.** Railway starts the worker while the
web service's pre-deploy step is still migrating, and the worker waits only
for a schema (`.claude/rules/deployment.md`). The first hand-out after a
deploy could therefore read sets that `RepeatUnopenedSetPauseFills` had not
stamped yet, and pause every active account with three of them. So the
hand-out asks `SchemaWait.migrations_pending?` once per run and skips the
pause check, and nothing else, while the answer is yes. Generation and
nudges still run. The check compares the migration files with the versions
the database has recorded. It does not use Rails' `needs_migration?`, which
raises on a migration dated after the clock. A run that skips the check
logs one warning, so a migration stuck pending cannot switch the rule off
unseen.

**Decided again under the lock.** The hand-out reads the sets with no lock
held, to avoid locking every due account each hour. When that read says
pause, `User#pause_for_unopened_sets!` takes the user row lock and asks
again: no set for today, and the last three still unopened. A set the
person generated by hand in between, or a resume in between, leaves the
account running. `PracticeGeneration.commit_new` writes a set under the same
lock, so the second read cannot miss one.

A set the user asks for from the dashboard is shown to them when it lands,
which stamps it, so it resets the run.

**Recording that a set was opened.** `DailyExercise#mark_opened!` writes
`opened_at` in one `UPDATE ... WHERE opened_at IS NULL`, with no callback and
no change to `updated_at`. `DashboardController#show` calls it for the set it
renders. A set still being generated or regenerated shows the spinner, so it
is not stamped. The held set a paused user is shown is stamped like any
other. A set opened from a push reminder needs no stamp of its own, because
the reminder links to the dashboard. `GET /dashboard/status` stamps nothing.

**Resume ends the run.** Decided by the owner on 2026-11-12. Clearing the
pause alone left the three unopened sets as the account's three latest, so
the next hand-out paused it again whenever no new set existed yet: a resume
on a weekend, a resume from the Account page, or a fresh generation that
failed. And once one new set arrived, a single unopened set paused again,
because the two old ones still counted. Resume has to give three fresh
chances.

So `opened_at` means "first shown on the dashboard, or acknowledged by
resuming generation". `GenerationPause#clear_generation_pause!`, which every
resume goes through, stamps the resume time on the user's sets that count as
unopened: `opened_at` empty, no response row, dated before today in the
user's zone (`DailyExercise.acknowledge_unopened!`). It is one `UPDATE` with
no callback and no change to `updated_at`, in the same transaction as
clearing the pause and under the user row lock, so a crash cannot leave one
without the other. The lock order is user, then exercises, as everywhere
else.

- **Why the existing column.** A separate "acknowledged" marker would have
  needed another release that only adds a column, because the worker can
  start before the web service has migrated.
- **Why "dated before today".** It is the same condition `UnopenedSets`
  counts by, so the stamp and the decision cannot drift;
  `DailyExercise.unopened_before` states it in SQL, and a spec holds it
  equal to `UnopenedSets.unopened?`. Today's own set is left alone: nobody
  has been shown it, the dashboard will stamp it honestly on the next visit,
  and it cannot count as unopened until its day ends, when it is the first
  of three fresh chances. The stamp runs after `#recover_held_set`, so a
  held set carried forward to today is dated today by then and stays
  unstamped for the same reason.
- **Every such set, not only the last three.** Older ones behind an opened
  set never counted, so stamping them changes no decision, and one condition
  is simpler than two.
- **Any resume, whatever the pause's source.** A manual pause whose last
  three sets went unopened would otherwise be paused automatically by the
  first hand-out after resuming.
- **"Keep it paused" acknowledges nothing.** It only changes the source.

The cost is in counting. A count of sets opened, taken from `opened_at`,
slightly overcounts for an account that was paused and then resumed: its
unopened sets carry the resume time though nobody was shown them.

Sets that existed before the column hold their `created_at`, written by
`AddUnopenedSetPauseColumns` and again by `RepeatUnopenedSetPauseFills`
(`docs/code-notes/db/migrate/20261112140000_repeat_unopened_set_pause_fills.md`).
Without those fills every earlier set would read as unopened.

**Who paused.** `users.generation_pause_source` holds `manual` or
`automatic` (`User::GENERATION_PAUSE_SOURCES`), and is empty while generation
runs. `User#pause_generation!(source:)` is the one writer of a pause, and
`#clear_generation_pause!` clears the source together with the pause time;
`#resume_generation!` calls it. Both writers are in the `GenerationPause`
concern, so the pair of columns is written in one file.

**The pause time is the authority.** The spec first asked for a validation
that refused a source without a pause time, or a pause time without a
source. It was dropped: rows written by the release before this one can hold
either state, and a validation on `User` would then refuse every unrelated
save for those accounts, a settings change included. The readers settle it:

- a pause time with no source, or with a value outside the list, reads as a
  manual pause (`#generation_pause_kind`);
- a source with no pause time is ignored;
- `#generation_paused_automatically?` is true only when the pause time is set
  and the source is `automatic`.

**A running pause keeps its time.** `#pause_generation!` on an account that
is already paused never moves `paused_generation_at`, for the reason given
above for re-pausing. It changes the source at most, and only towards
`manual`: the hand-out reaching an account its owner has just paused leaves
that pause manual. The method answers `:paused` or `:kept`, and
`AccountsController` maps that to its message.

**What the user sees on the next visit.** While the pause is automatic, the
dashboard shows one line above whatever state it is in:

> Generation paused after three sets in a row went unopened, so your key
> isn't spent on sets you don't see.

with two controls, both plain forms that work without JavaScript:

- **Resume** posts `paused=0`. It clears the pause and returns to the
  dashboard, which then does what it does for any account with no set: on a
  weekday it starts generating today's.
- **Keep it paused** posts `paused=1`. The account is already paused, so
  only the source changes, to `manual`, and the line goes away.

Both post to `PATCH /account/toggle_generation` with `return_to=dashboard`.
The action returns to the dashboard for that exact name and to the Account
page for anything else. It takes a fixed name and no URL, so the parameter
cannot send the browser to another site.

The line shows in every dashboard state, including a weekend and a day with
a set on the page. `MissingSetState` puts the weekend ahead of the pause, so
the line is drawn outside it, above `#dashboard-content`, and that object is
unchanged. The Account page's paused note says which kind of pause it is.

**Nothing is carried forward on resume.** `User#held_exercise` only looks at
sets dated on or after the pause. The hand-out pauses on a day with no set,
and the three unopened sets are dated before it, so they keep their dates,
are acknowledged as above, and the user starts with a fresh set.

**No push or email is sent.** The person isn't looking, so the line waits
for them on the dashboard.

**The words and the count.** The line and the Account note say "three" in
words. `spec/requests/automatic_pause_spec.rb` fails when
`UnopenedSets::PAUSE_AFTER` stops matching them.

## Holding the schedule for a key that keeps failing

Decided with the pause rule. When a morning generation failed, the hand-out
used to try again every hour until midnight, whatever the reason, so a
revoked key was called up to sixteen times a day, every weekday. Those
failures create no set, so the pause rule never reaches such an account.

**The rule.** After two generation failures in a row that the provider
classified as a bad key or as out of credit, the schedule stops covering the
account. The two can be one of each. `KeyHold`, a pure object, owns the rule:
the kinds are `KeyHold::KINDS`, the count is `KeyHold::AFTER`, and
`.counts?(kind)` and `.held?(count)` answer from plain values. `User` and
`ScheduledGeneration` both read it, so neither names the other for this
rule.

**Why two and not one.** A provider can reject a good key once during an
incident. Two in a row is a real answer.

**Why those kinds.** They are the two failures that waiting cannot fix. A
rate limit, an outage, a timeout and a setup problem leave the count alone,
whatever it stands at.

**Recording it.** `users.generation_account_failures` counts them.
`User#record_generation_failure!` raises it by one for a counted kind.
`GenerateDailyExercisesJob` calls that inside `persist_failure`, which writes
only while the job still holds its claim and the day has no set, so a job
whose claim was taken over cannot count a failure the newer job will report.
`User#record_generation_success!` sets the count back to zero, and so does
`User#store_api_key`, which `ApiKeysController#update` calls when it stores
a key. Switching to another stored key (`User#use_provider`) resets it too,
because the count describes one provider's key. Saving other preferences
with the provider unchanged leaves it alone. Pressing "Try again" clears the failure message and leaves the count.

**What stops.** `ScheduledGeneration.users`, the single authority for which
accounts the schedule covers, leaves out an account at or past the count.
That list also decides who gets the afternoon nudge, since the hand-out
sends it to the same accounts. So
the hand-out enqueues nothing for it, and a scheduled job already in the
queue checks again and does nothing.

**What still runs.** Anything the user starts: opening the dashboard on a
day with no set, "Try again", and `POST /generate`. Each is one call. If the
key works again that call succeeds, the count goes back to zero, and the
schedule covers the account the next morning. If not, the user sees the
existing bad-key or out-of-credit message.

**A regeneration.** `RegenerateExerciseJob` replaces a set that already
exists, so it is not the morning generation. Its success sets the count
back to zero, because a generation the user started worked. Its failure is
not counted. An account with today's set still needs the schedule for the
afternoon nudge, which the hand-out sends from the same list of accounts,
and two failed presses of "Generate a new set" would otherwise end that
day's nudges.

**This is separate from the pause.** The hold never sets
`paused_generation_at`, shows no pause line and leaves the Account page's
button alone. The user's signal is the failure message they already get.

**Adding credit doesn't lift the hold by itself.** The app can't see a
provider balance. The user's next visit makes the one call that finds out.

**Known gaps.**

- Gemini never reports out of credit. An empty balance there reads as a rate
  limit, which doesn't count, so a Gemini account reaches the hold only
  through a rejected key.
- An account that is both paused and held, and resumes with a held set
  carried forward, has today's set and a count still at the hold. It gets no
  nudge that day. Its next successful generation clears the count.

# The duck thread is stored

Each section's duck thread is stored on the server in `duck_threads`, so it
survives a reload and follows the engineer to another device. The duck itself
is unchanged: the same instructions, the same request, the same markup and
controls.

**One row per exercise, not a column on the response.** The duck usually runs
before any answer is saved, so the response row often doesn't exist yet.
Storing the thread there would mean the duck creates that row, and a row
created only by the duck changes four things the engineer would notice: the
next day's size (`SectionCount` reads a missing row as a skipped day and a
present one as zero answered), a `0/3 answered` line in the generation prompt
(`User#recent_performance` reads unsubmitted rows), the afternoon nudge
(`PushNudgePlan` reads the row's `updated_at` as activity), and an unsent
offline draft, whose token names the row's id. A `duck_threads` row, unique on
`daily_exercise_id`, changes none of them. `threads` is keyed by section like
`answers`, and each entry holds `turns`, `version` and `cleared`.

**`DuckThread` is the one authority for a section's thread.** The controller
asks it for the turns, the user-turn count, the stored size and the version,
and never reads the JSON. `version` goes up on every append and every clear,
including a clear of an empty section.

Every ask and Clear names the set the page shows by its draft scope, read
from the answer form. A page showing a set that is no longer today's
(regenerated, or yesterday's tab still open), or a page whose version is
behind the stored thread, is refused before anything is billed or written,
with the 409 text a stale autosave gets: "This page is out of date. Refresh
it". A reload brings the page level with the server. The duck's older
"out of step — clear it to keep going" text is gone, because on a second
device it told people to wipe a thread that was fine.

After the reply, the append is stored under the owner's user row lock
(`FOR SHARE`), then `DailyExercise#with_response_locked`, then the row lock:
the same user-then-exercise order as `User#carry_forward`. A Clear takes the
same locks. Under them each writer re-checks what may have moved while it
waited and returns a named outcome: the new version, `:deleted` (the account
was deleted), `:submitted` (the day was submitted) or `:stale` (the set was
regenerated or the version moved). The controller answers `:submitted` with
the after-submit text and the rest with the refresh text. So a Clear, a
regeneration, a submit or an account deletion that lands while a reply is on
its way drops the reply, as Clear already drops one on the page today, and a
Clear never erases a submitted day's thread or a newer set's thread. Clear
always wins over a reply.

`draft_scope` stamps the row with `DailyExercise#draft_scope`; a regenerated
day has a new scope, so its old thread reads as empty and is overwritten on
the next write. Start over keeps the row but empties every section and moves
its version, so a tab still showing the old turns is told to refresh rather
than lining up with a new thread at a reused version.

One cost is accepted: two devices asking at the same version both pass the
check before the call and both bill, and the second reply is dropped at the
lock. One page disables its controls while it waits, and the request limit
bounds trial accounts.

**The cap is counted from the stored thread.** Six user turns a thread, and
Clear starts a new one, so nobody gets fewer turns than before. A reload no
longer gives a fresh allowance, because the reload now restores the thread;
Clear is the reset, as the cap text has always said. Counting on the server
closes the security audit's A4 (forged assistant turns, a cap reset by an
empty `thread`): a posted `thread` is ignored.

**Pages loaded before the deploy kept the old behaviour for one release.**
The service worker caches nothing, but an open tab or the home-screen app,
which Safari restores from its back-forward cache, keeps running the old
controller until a real reload. That controller posts its own `thread` and no
`version`. Read as version 0, its first message would succeed with the duck
blind to the turns on screen, and every later one would be refused as out of
step. So for one release a request with `thread` and no `version` took the old
path unchanged: the posted thread was the history and the cap, and nothing
was read from or written to `duck_threads`, so forgeable turns couldn't enter
the record. Each use logged `[duck] legacy thread shape user <id>`, and the spec gated
the path's removal on that line being absent for 7 days, and at least 14 days
after the deploy. With the path gone, such a page sends no draft scope, so it
gets the refresh text before any call, and a reload moves it onto the new
script.

**The table and its readers ship together.** `.claude/rules/deployment.md`
has a new column ship a release before code reads it, because the worker
waits for a schema, not for pending migrations. Web is safe: its pre-deploy
runs `db:migrate` before the new code takes traffic. The worker's only reader
is the 03:17 UTC sweep, so the exposure is a deploy in that minute, where the
job fails once and runs again the next day.

**Threads are kept 365 days.** Submitting doesn't delete a thread; nothing
renders it after submit, and the duck refuses to run or clear once the day is
submitted. `SweepDuckThreadsJob` runs daily at 03:17 UTC and deletes rows
whose exercise is dated more than `DuckThread::KEPT_FOR` ago. Start over
empties the day's thread, as it deletes the response, and account deletion
deletes every row. A rolled-back release has no cleanup in
`User#anonymize!`, so an account deleted during a rollback keeps its threads
until the sweep runs on a release that has it. At a heavy rate (three sections, six exchanges each, every
weekday) a year is about 1.9 MB and 260 rows per account; a light user stores
about 160 KB. The worst case, every turn at the byte cap on four sections
every day, is about 60 MB a year, and the trial limit bounds it for house-key
accounts.

**Archiving cleared turns was considered and declined.** The record has no
reader, so completing it is speculative, and an archive would turn a record
bounded at one thread per section into one bounded only by how often someone
clears. A per-section `cleared` count is kept instead. It is the one signal a
Clear carries, that someone ran a thread out or started again on the same
problem, without keeping what they typed. Nothing reads it.

**The privacy choice.** These are transcripts of what people typed while they
were stuck, kept for a year and read by nothing. On this app they include
trial and invited accounts, so they are other people's data, not only the
owner's. That is accepted on these terms: they are deleted with the account,
filtered from logs and `inspect` (`threads` matches the `thread` entry in
`filter_parameter_logging.rb`), scoped to their owner, and kept out of every
provider prompt but the duck's own. `duck_thread_isolation_spec` holds that
for generation, review, the judges, mastery and planning (`app/services`,
`app/jobs` and the mastery and verdict models); the dashboard's duck partial
is the only other reader. Giving them a
reader, or a longer window, is a new decision, not an extension of this one.

**User-facing text.** The app has no privacy page. The account page's danger
zone ("Your exercise history is kept anonymously for team statistics") stays
true, because threads are deleted with the account. Nothing tells someone that
what they type to the duck is now kept for a year, and a chat box that used to
vanish on reload invites the opposite assumption. This change adds no copy,
since it changes no markup. A one-line disclosure near the duck or on the
account page should ship before or with this deploy, as its own copy change.

**Clear and ask go through `CodeGymRequest.send`, not the save queue.** The
"one way to send a request" pattern names `CodeGymSaveStatus.queue` for a save
that must not overlap another. Here the server's version check makes an
overlap safe, and the queue would put duck failures on the page-wide save
banner, which is new UI. The page also waits for a pending Clear before it
sends the next ask, so an ask doesn't carry a version the Clear is about to
retire, and a Clear that fails puts the thread back on the page, so the page
never hides turns the server still holds.

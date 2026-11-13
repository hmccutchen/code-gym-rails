# app/models/privacy_notice.rb

`PrivacyNotice` holds the numbers the privacy page (`GET /privacy`,
`app/views/privacy/show.html.erb`) states, so the page's text, in
`config/locales/en.yml` under `privacy.show`, never carries a number of its
own. `.facts` is the one list the controller hands the view.

## Numbers read from the code that sets them

- `duck_days`: `DuckThread::KEPT_FOR`, which `SweepDuckThreadsJob` enforces.
- `unopened_sets`: `UnopenedSets::PAUSE_AFTER`, the run of unopened sets that
  pauses generation.
- `session_days`: the session store's `expire_after`
  (`config/initializers/session_store.rb`). The cookie's expiry moves forward
  on every request that reads the session, so the page says you stay signed
  in that long after your last visit. `.days_rounded_up` rounds a part day
  up, so a setting of 36 hours reads as 2 days and the page never claims
  less time than the setting.

## Numbers the code cannot know

`LOG_DAYS` is how long Railway keeps server logs (7 days on the current
plan), a setting outside this repository, so it is written here by hand.
When the Railway setting changes, change the constant with it.

The page states nothing about database backups, because Railway backups are
off. Turning them on means adding a line to the page, and a constant here,
saying how long they keep a copy, in the same change.

## What the page leaves out

The owner asked for the deletion section to stay short and plain. It names
server logs, the shared concept write-ups and copies held outside Coding
Gym. It leaves out the other leftovers `docs/decisions/deleting-an-account.md`
lists: cache entries that hold an email, IP address or user id until
`config/cache.yml`'s `max_age`, finished jobs cleared a day later, and a job
that fails after deletion and stays in the failed-jobs list. It also leaves
out that request logs carry IP addresses and that background work logs a
user id. "Don't include your email address" is a claim about the logs only,
and it holds: they carry IP addresses and user ids, never the address. The
rate limit cache does hold email addresses, for up to `max_age`, and the page
no longer mentions it.

## Voice

The page speaks for the app, with no first person and no channel to write
to, because it stands alone inside the app. `spec/requests/privacy_spec.rb`
fails on "I", "me" or "my" outside the quoted "Delete my account" button.

It reads `DuckThread::KEPT_FOR`, so `duck_thread_isolation_spec` lists this
file as allowed, next to `AccountData`. It reads only that constant, never a
thread, and it reaches no generation, review, judge, mastery or planning code.

# app/models/privacy_notice.rb

`PrivacyNotice` holds the numbers the privacy page (`GET /privacy`,
`app/views/privacy/show.html.erb`) states, so the page's text, in
`config/locales/en.yml` under `privacy.show`, never carries a number of its
own. `.facts` is the one list the controller hands the view.

## Numbers read from the code that sets them

- `duck_days`: `DuckThread::KEPT_FOR`, which `SweepDuckThreadsJob` enforces.
- `unopened_sets`: `UnopenedSets::PAUSE_AFTER`, the run of unopened sets that
  pauses generation.
- `cache_days`: `max_age` in `config/cache.yml`, read through
  `Rails.application.config_for(:cache)`. The rate limit entries that hold an
  email address or an IP address live in that cache, and Solid Cache removes
  an entry once it is older than `max_age`.

## Numbers the code cannot know

`BACKUP_DAYS` (how long Railway keeps database backups, 6 for its daily
backups) and `LOG_DAYS` (how long Railway keeps server logs, 7) are settings
on Railway, outside this repository, so they are written here by hand.
`spec/models/privacy_notice_spec.rb` fails unless both are whole numbers of
days. When either Railway setting changes, change the constant with it.

## Why the page names the logs' IP addresses and the cache

Rails' request log prints each request's client IP address on its
`Started` line, and Railway's HTTP logs carry it too, so "never an email
address" alone would have read as "nothing that identifies you". The
sign-in rate limits key their cache entries on the email address and the IP
address, and those entries outlive a deletion until `max_age`, so they are
listed with the other things deletion leaves behind
(`docs/decisions/deleting-an-account.md`, "The two leftovers").

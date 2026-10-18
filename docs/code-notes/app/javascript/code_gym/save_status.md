# app/javascript/code_gym/save_status.js

## Purpose

The autosaves on the dashboard and /setup report through this module, so a
rejected write tells the engineer instead of vanishing. The page's control
keeps whatever the user set, because snapping a slider back under their hand is
worse than the problem this solves. By default, the banner says the change did
not reach the server; a caller can supply wording for a bookkeeping failure
after the user's change was saved.

One exception belongs to the caller, not this file. A save refused because
another tab got there first comes back carrying the state that is actually
stored, and /setup puts that on screen. Keeping the user's value there would
leave the page showing something the server has refused and will keep
refusing, which is the false display this component exists to stop.

The layout's one-shot time-zone detection deliberately does not report here.
Nothing the user did triggers it, so a banner would name a failure they took no
action to cause, and it runs again on the next page load anyway.

The layout loads this through `javascript_importmap_tags`, so it is a deferred
module that imports `code_gym/request` rather than reaching for a global.
Every page script now imports it. `app/javascript/application.js` still puts
it on `window.CodeGymSaveStatus`, because system specs drive the module through
that name inside `execute_script` and `wait_for_function`, which cannot import
a module, and because the bootstrap
(`app/assets/javascripts/code_gym_bootstrap.js`) publishes the name at parse
time, so the module has to take it over when it loads. Its generic failure
wording is rendered onto `<body>` as a data attribute, since a module cannot
read a translation. The banner markup is `shared/_save_status_banner`, rendered
in `<body>`, so `render()` looks the elements up when it runs and waits for
`DOMContentLoaded` if a carried message arrives before they exist.

## `#save-status-announcer`

The visible banner is toggled with `hidden`, and screen readers often stay
silent about a live region that appears with its text already in it. This copy
is always in the page, so a failed save is always announced, and assertively
(`role="alert"`), since the engineer's work did not reach the server.

## `failures`

Failures are keyed by control rather than held as one flag. /setup saves three
different things to one URL, and without a key a successful time-zone save
would clear a warning the exercise-mix save had just earned, while the
rejected checkbox still looked saved.

## `issued`

Guards against two saves of the same control finishing out of order, where a
slow failure would otherwise overwrite the result of the newer save that
succeeded after it.

## `requests`, `probes`, `pending()`

These count work the page shows but the server has not stored yet: a request on
the wire, or a delayed save a page registered through `watch()`.
Pull-to-refresh waits on `pending()` so a reload cannot drop an edit mid-save.

## `reloadWhenSaved()`

A page that answers a refusal by reloading must not reload over a save that
has not landed. `reloadWhenSaved(stranded)` polls `pending()` every 200 ms and
reloads once nothing is left. A save that hangs or fails must never cost an
edit to a forced reload. So after ten seconds, or when a save under any key but
the caller's own `conflict` key was reported failing during the wait, it calls
`stranded` instead, which hands the reload to the user and leaves the failed
selection on the page to retry. `reportedAt` records when each key last
failed. The conflict key is left out because the refusal that started the wait
reports under it, and so does any later save from the same out-of-date page. The level suggestion card and the exercise mix both
use it. Pull-to-refresh keeps its own loop, because it polls faster, cancels
when the pull ends and resets its spinner instead.

## `queue()` and `queued()`

A control whose saves must not overlap queues them under its key. Without
`latest`, every save goes out in order, which Setup's controls need: the
exercise mix's next save carries the version the one before it moved to. With
`latest`, saves asked for while one is in flight collapse into a single save,
which the dashboard needs, since each of its saves carries every answer. A body
given as a function is read when the save is sent, so it carries the state as
it is then; returning `null` drops that save. The next save is sent a task
later, not a microtask, so the reply's own handlers have updated whatever the
next body is built from (the mix's version, again). Waiting saves count toward
`pending()`.

`offline` retries a save that got no reply at all (the fetch rejected), and
shows the given sentence instead of the generic one while it waits. It may be
a function, read on every failed attempt, so a retry already waiting shows
the caller's current wording. Only the
dashboard's answers pass it. It waits for the browser's `online` event or a
timer (`RETRY_DELAYS_MS`, 5 to 30 seconds), whichever comes first, then reads
the body again, so the retry carries the newest answers. A refusal, a 5xx and
the signed-out redirect all got a reply and are never retried. The line stays
busy while it waits, so `pending()` stays true and pull-to-refresh will not
reload over the unsent save. Every attempt goes through `save()`, so the
`issued` ticket check still applies to each one.

A lost connection can also mean the server stored the save and only the reply
was lost. Retrying is safe for answers because `ResponsesController#create`
accepts the same payload twice. It would be wrong for the track proposal's
answer count, which increments on every request, and that is why retrying is
opt-in per queue rather than the default.

`quiet` keeps a queued save's failures out of the banner. The nav name editor
shows its own "couldn't save" line beside the field, and the layout's one-shot
time-zone detection is something the user never asked for, so neither should
raise the banner. Both still queue, under `name` and `time_zone`, so an older
write can't land after a newer one; Setup's time-zone select shares the
`time_zone` key with the detection.

`line` puts a save on another key's queue while its failures still report
under its own key. Setup's track select saves on the exercise mix's line
(`line: "exercise_mix"`): a track change can clear targets and move the
version, so a mix save sent beside it would carry the old version and get a
409. On one line the two go out in turn, and a mix save waiting behind the
track reads its body after the reply has been applied. `queued(key)` names a
line, so `queued("exercise_mix")` also counts a waiting track save. `latest` collapses only
into a waiting save of the same key, so one control never replaces another's
body.

## `report()` and `clear()`

A failure that is not a save, such as a refused submission, still belongs in
the banner, so callers can report one under its own key.

## `save()`

The optional fifth argument, `failureMessage`, replaces the wording for every
failure: a dropped connection, a refusal and a session redirect. The track
proposal uses it for its separate answer-count request: the choice was saved,
the count could not be updated, and the user need not repeat the choice. Keys,
pending requests and out-of-order replies work the same way with or without
it.

`save` resolves with `{ ok, status, data }`, so a caller able to act on a
particular refusal can. Callers that cannot simply ignore it; the failure has
already been reported either way.

`fetch` follows redirects, so a request made after the session expired arrives
as the login page: status 200 and `ok` true, for a save that stored nothing.
Neither endpoint redirects on success, so a redirect can only mean the write
did not happen.

The request itself goes through `CodeGymRequest.send`, which reads the CSRF
token safely, parses JSON only when it can, and decides what the banner may
say: the server's sentence when the reply is the app's own, the module's one
signed-out sentence after a redirect, and `GENERIC` otherwise. A body function
that throws drops its save rather than stalling the key's queue. A dropped connection's
browser string ("Failed to fetch") is never shown.

## `CARRIED` and `carry()`

A caller that reloads in answer to a refusal navigates before the banner it
just set can be read, so the message has to reach the page that replaces this
one. It goes through sessionStorage rather than a query parameter: the reload
is a plain `window.location.reload()`, and a parameter would survive in the URL
and announce itself again on every later load.

The stored message is bound to the path, because the reloaded page is the only
one meant to read it. A caller that sets a message and then never reloads (a
refused navigation, a closed tab) would otherwise leave it for whatever page
this partial renders on next, which could be days later and about nothing the
reader did.

Private browsing can refuse the sessionStorage write. The reload still happens,
and the page it lands on says nothing, which is where it started.

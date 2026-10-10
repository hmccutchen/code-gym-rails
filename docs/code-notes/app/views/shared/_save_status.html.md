# app/views/shared/_save_status.html.erb

## Purpose

The autosaves on the dashboard and /setup report through this partial, so a
rejected write tells the engineer instead of vanishing. The page's control
keeps whatever the user set, because snapping a slider back under their hand is
worse than the problem this solves. The banner says the change did not reach
the server.

One exception belongs to the caller, not this file. A save refused because
another tab got there first comes back carrying the state that is actually
stored, and /setup puts that on screen. Keeping the user's value there would
leave the page showing something the server has refused and will keep
refusing, which is the false display this component exists to stop.

The layout's one-shot time-zone detection deliberately does not report here.
Nothing the user did triggers it, so a banner would name a failure they took no
action to cause, and it runs again on the next page load anyway.

The layout renders this partial ahead of `yield :page_scripts`, the same way it
renders `shared/_push_script`, so a page's own script can rely on
`window.CodeGymSaveStatus` existing by the time it runs.

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

## `csrf()`

The lookup is optional-chained for the same reason `api_keys/edit`'s script is:
with forgery protection off, Rails renders no csrf meta tag at all, and a throw
here would stop the save silently, which is the failure this file exists to
surface.

## `save()`

`save` resolves with `{ ok, status, data }`, so a caller able to act on a
particular refusal can. Callers that cannot simply ignore it; the failure has
already been reported either way.

`fetch` follows redirects, so a request made after the session expired arrives
as the login page: status 200 and `ok` true, for a save that stored nothing.
Neither endpoint redirects on success, so a redirect can only mean the write
did not happen.

A failure can answer with an HTML error page rather than JSON, and parsing that
throws, hence the inner catch. Only a message the server actually wrote is
shown; anything else falls back to `GENERIC`, which is why the rejection path
ignores its own error. A dropped connection rejects with a browser string
("Failed to fetch"), which is a developer's sentence and not one to show an
engineer.

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

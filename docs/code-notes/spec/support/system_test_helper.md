# spec/support/system_test_helper.rb

## wait_for_js_condition rides out a navigation

The poll asks the browser a question every 50ms. A page that navigates
between two of those asks destroys the execution context the next one lands
in, and Playwright raises rather than answering. The condition is usually
about the page being arrived at, so the right answer is to ask again until
the deadline; `level_suggestion_spec` waits on exactly that shape and failed
about three times in a hundred navigations before this.

Only the navigation messages are swallowed. A `ReferenceError` in the
expression itself still raises on the first ask, so a typo in a condition
fails fast instead of timing out.

`Target closed` is not one of them. It means the page, context or browser
is gone, and asking the same page again cannot bring it back, so swallowing
it would turn a crash into an unrelated timeout at the end of the wait limit.

## `PollingHelper#wait_for`

The one way a system spec waits on something Capybara can't see, such as a
database write or a value the page sets. It raises on timeout, because the
copies it replaced returned silently and the assertion after them then
reported a stale value, so a slow save read as a wrong one (#456). It reads
the monotonic clock, since several examples run inside `travel_to`, where
`Time.current` never passes a deadline. It returns the block's value, so a
caller can wait for and use the same result.

## `Capybara.default_max_wait_time`

Twenty seconds, and specs pass no `wait:` of their own beyond the
deliberately short negative checks (`wait: 0`, `wait: 2`). The failures in
#456 were fixed waits of 5 to 10 seconds running out on slow runs, in CI as
well as locally. A wait that succeeds returns as soon as its condition holds,
so the longer limit costs a passing run nothing; it only makes a real
failure take longer to report. `wait_for` and `wait_for_js_condition` use the
same value, so the suite has one wait to tune.

## `visit_with_todays_set` ends with `wait_for_js`

Text on the dashboard is rendered by the server, so seeing it says nothing
about `answer_form_controller` having connected. An example that typed or
clicked straight away raced the modules, and on a loaded run it lost.

`wait_for_js` waits for `html[data-js-ready]` and then for every
`[data-controller]` element to have its controller connected.
`application.js` also sets the marker when it gives up after ten seconds with
a controller still missing, so the marker alone would let an example run
against a page whose controller never arrived.

## The draft key comes from `draft_store.js`

`JavascriptReadyHelper::DRAFT_KEY` is read from the `const KEY = "..."` line
in `app/javascript/code_gym/draft_store.js`, the key's one owner, and loading
the spec support raises if that line changes shape. Specs reach the stored
copy through `draft_key_js`, `stored_draft_js`, `draft_absent_js`,
`wait_for_draft_cleared` and `wait_for_answers_settled` instead of writing
the key out. A copied key would keep every wait for the copy to be `null`
passing at once after a rename, so those waits would stop guarding anything
(#501).

`wait_for_draft_cleared` and `wait_for_answers_settled` are different waits.
The first holds once no copy is kept on the device; the second also needs
`CodeGymSaveStatus` to have no save queued or on the wire, since a queued
save can still write a copy back. `spec/conventions/system_spec_waits_spec.rb`
fails on the key or a string-keyed `localStorage` call in a system spec.

## `FetchStubHelper` stubs one path

`stub_fetch(path, reply)` replaces `window.fetch` so a request whose path is
`path` gets `reply`, a JavaScript expression evaluated on every matching
request, and every other request goes to the fetch that was in place before.
The reply can use `url`, `options` and `passThrough`, the fetch it replaced, so
a slow reply is `"new Promise(...).then(() => passThrough(url, options))"`.
The path is compared with the request's resolved pathname, so an absolute URL
or a query string still matches, and `/profile` doesn't match `/profiles`.
`prefix: true` matches every path under it, for a route with a parameter such
as `/daily_kinds/:place`. Stubbing a second path wraps the first stub, so both
stay in place.

The wrappers cover the common replies: `fail_requests_to` (a 500 with the
app's error JSON), `drop_requests_to` (the request rejects the way a lost
connection does) and `redirect_requests_to_login` (a reply that was
redirected, the way an expired session answers). `break_the_network` rejects
every request, for a spec about the whole device being offline.

Before this, about twenty specs built their own replacement, and three copies
of `fail_requests_to` already differed in which URLs they matched (#514).
Specs whose stub holds a reply until released, counts calls, matches on the
request body or method, or swaps fetch inside one evaluated script keep their
own: their timing and matching are what they test, and the helper covers only
"this path answers like this".
`spec/conventions/system_spec_waits_spec.rb` fails on a spec that redefines the
helper names, builds a one-expression path stub, or writes a redirected reply.

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
it would turn a crash into an unrelated timeout ten seconds later.

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


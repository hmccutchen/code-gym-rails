# spec/support/system_test_helper.rb

## wait_for_js_condition rides out a navigation

The poll asks the browser a question every 50ms. A page that navigates
between two of those asks destroys the execution context the next one lands
in, and Playwright raises rather than answering. The condition is usually
about the page being arrived at, so the right answer is to ask again until
the deadline; `level_suggestion_card_spec` waits on exactly that shape and failed
about three times in a hundred navigations before this.

Only the navigation messages are swallowed. A `ReferenceError` in the
expression itself still raises on the first ask, so a typo in a condition
fails fast instead of timing out.

`Target closed` is not one of them. It means the page, context or browser
is gone, and asking the same page again cannot bring it back, so swallowing
it would turn a crash into an unrelated timeout ten seconds later.

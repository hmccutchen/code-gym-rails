# `SpendCap`

A dollar limit for a script that makes billed calls, passed as
`--max-cost` to `script/draft_key_samples.rb` and required there with
`--run` (owner's decision, 2026-10-30). `#check!` takes the worst-case cost
of the next call and raises `SpendCap::Reached` when the amount already
spent plus that worst case would pass the limit, so the run stops before
the call is sent, not after. `#record` adds a finished call's real cost and
prints the running total with the call's purpose.

It knows nothing about providers or prices: the caller works out both
amounts (`KeySampleDrafts.request_bound` and `.call_cost`), so the rule
stays the same whichever script uses it.

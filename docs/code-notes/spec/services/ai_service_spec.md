# spec/services/ai_service_spec.rb

## `REVIEW_OVERHEAD_SECONDS`

The review timeout budget adds a minute of headroom for work the provider's time excludes: usage writes, parsing, thread scheduling and the final save.

## `#full_problem_set`

The helper pads every third and fourth kind with an inert placeholder section, so an example that leaves the rotation roll unstubbed still finds its rolled section in the payload.

## `"single-shot purposes"`

`SINGLE_SHOT_PURPOSES` is listed in full rather than derived, and the group checks it against `AiService::CALL_PROFILES.keys`, so a new purpose fails the group until it is listed here or named as conversational. That a profiled purpose has a real caller is held by `ai_service_request_spec`, which drives one caller per purpose and fails when none sends a request.

## `DUCK_RESPONSE_MAX_TOKENS`

An explanation plus a guiding question did not fit in 250 tokens, so the cap is 400. The duck's prompt withholds the answer; the cap does not.

## `"#generate_judged_exercise"` `before` block

The `and_call_original` stub on `WeightedRoll.pick` drops the suite-wide `RealSource::WEIGHTS` pin to `:toy`, so the block restores that pin explicitly afterwards.

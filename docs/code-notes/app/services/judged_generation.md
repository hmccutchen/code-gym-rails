# app/services/judged_generation.rb

## `.call`

The `finish` callable is called exactly once, as `finish.(set, dropped_concepts:, judge:, unhosted:)`.

## `#call`

`ProblemSetIngest.prune_to_expected_keys` prunes a deep copy. The draft keeps every section's concept, which the finish step's logs and the unhosted-concepts list read.

## `#judge_all`

No thread writes to the set. Each thread returns `[key, outcome, section]` from `#judge_outcome`, and `#judge_all` assembles the results after joining them.

## `#resolve_rejections`

Returns one `[key, section_or_nil, outcome]` per rejected key. `#resolve_rejection` returns `[section_or_nil, outcome]`, where nil means a drop. Its `retries` count includes only retries that the judge actually judged.

## `#rejudge`

Returns `[section, outcome, settled]`. `settled` is false only when the judge rejected the retry.

## `#record_attempt`

When the judge could not answer, the method still appends an empty entry to each retry list, so the lists stay aligned with one entry per judged retry.

## `#judge_with_fallback`

Returns `[verdict, ms]`, or `[fallback_reason, ms]` when the judge could not answer.

## `#fallback_detail`

For a kind the judge solves blind, the value `JudgeVerdict` refused can be the solve itself, so the fallback log carries only the reason code and never the error message.

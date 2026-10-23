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

A re-judge fallback keeps the retry, except one with reason `deadline` (`ProviderError::DeadlineError.judge_fallback_reason`), which drops the section through `#unjudged_retry`. The retry replaces a section the judge already rejected, so only a judge that answered may ship it, and a deadline stop leaves no time for another retry. A first-pass judge stopped by the deadline still keeps the draft, since that section was never rejected.

## `#record_attempt`

When the judge could not answer, the method still appends an empty entry to each retry list, so the lists stay aligned with one entry per judged retry.

## `#judge_with_fallback`

Returns `[verdict, ms, identity]`, or `[fallback_reason, ms, identity]` when the judge could not answer, where the fallback's identity also carries `unsolved_detail`.

## `Provider#judge_identity`

A value beside the callables, the provider key and the model `judge_section` routes to, so a `Solve` can say who judged it. This departs from "provider calls as callables" (`.claude/rules/patterns.md`) in the way `ReviewGrading::Provider#provider_key` already does: it is a fact about the provider, not a call, and a callable returning a constant would only hide that.

## `#judge_with_fallback`, the third value

Alongside the verdict or reason it returns the judge's identity from the same `Provider` it called (`judge_identity`, a hash of `judge_provider` and `judge_model`), plus `unsolved_detail` on a fallback. Taking the identity from the provider that judged keeps one factory call per judge call.

## `#fallback_detail` and `#refusal_message`

Only a `JudgeVerdict::Invalid` message is logged, for every kind, and it is the message a `Solve` keeps as `unsolved_detail`, cut to `REFUSAL_DETAIL_LIMIT` characters in both places, since a message can echo a judge-written value through `inspect`. `JudgeVerdict`'s messages name a missing or unknown value and never quote the submitted `better` (`judge_verdict_spec` words every refusal path with several values of `better` and expects one message). Any other error class keeps its message out of the log, since a provider's error body can echo the section, the key included.

## Solves

Each judge pass on a kind with `judge_solve_options` becomes a `JudgedGeneration::Solve`, kept on that kind's `SolveChain` and handed back on `AiService::JudgedSet#solves`. They never enter `outcomes` or the `finish` call, because `outcomes` is the `[difficulty_diagnostics]` payload and a solve carries the answer key.

`shipped` and `never_shown_reason` are decided from the control flow, never by comparing sections afterwards:

- `#judge_outcome` settles the chain at attempt 0 when the draft is kept, edited or unjudged.
- `#rejudge` settles it at the retry's number when the retry is kept or edited, and `#unjudged_retry` does when a re-judge fallback keeps the retry. A deadline stop settles nothing.
- `#confirmed_edit` tells the chain which version of the attempt is its candidate: the edit check when the edit was kept, the pre-edit draft when it was reverted (with `#revert_reason`, the same three tests that decide the revert).

`#call` tells each chain whether its kind is in `dropped`, the list that becomes `dropped_sections`, and `SolveChain#solves` turns the settled attempt and that fact into the two columns: see its own note.

The chains are built per planned kind in `#initialize`, before any thread starts, so each thread only touches its own kind's chain and the hash is never written concurrently.

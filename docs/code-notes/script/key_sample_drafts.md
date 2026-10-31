# `KeySampleDrafts`

Drafts sections for the sampled key read between the two stored-keys PRs, run
as `script/draft_key_samples.rb KIND OUT_PATH`. The owner is the app's only
user and their days rarely hold `security_review`, `plan_review` or
`pseudocode_to_code`, so those three kinds are read from drafts
(`docs/decisions/stored-answer-keys.md`, "The rarer kinds are read from
drafts"). `KINDS` lists them. `code_review` (`TRIAGE_KIND`) is drafted too,
with or without `--triage`, which adds only the blind solve
(`docs/code-notes/script/key_triage.md`). A `code_review` drafted like the
other kinds wouldn't match a real one: its fixed concept could contradict
the plan's rolled content mode, and its judge edit would skip the scenario
restore `JudgedGeneration` does for a `RealSource` section. So each kept
`code_review` takes the next mode in `KeyTriage::MODES`, its concept comes
from that mode's vocabulary, and `.plan_for` gives the draft a plan with
that mode, no `RealSource` and one file, since multi-file waits for launch
B. The owner asked on 2026-10-30 for a smaller `code_review` set without
the solve, which is why drafting and solving are separate.

## The path

Each draft calls `AiService#retry_section`, the route a judge rejection takes
on a real day, with one concept and one rung fixed and the kind locked at
that rung through `ForcedConceptDrafts.rung_draft`. So `ProblemSetIngest`,
`PlantedKey` cleaning and the `[planted_key]` line (logged `attempt=retry`,
outside the stop rule's count) are the production ones. The prompt is the
retry prompt, not the first-draft one a day mostly ships: it asks for one
section, with the line saying the concept is fixed because a section was
rejected, and none of the lines comparing with other sections. Drafts show
whether the generator plants a correct key for the kind; they don't
reproduce a first draft. The draft is then judged by `#judge_section` on its
own route, and a prose edit is applied with `JudgeVerdict#apply`.

Rungs follow the kept sections, so a rejection doesn't skip one: the first
four kept sections cover every rung. Concepts cycle through the kind's
selectable vocabulary, without `other`, shifted once per pass through the
rungs so each concept meets each rung.

A rejected draft, a draft whose key ingest dropped (never sent, unusable or
too long; the `[planted_key] attempt=retry` log line says which), and a provider, verdict
or connection failure are counted, not kept, and another draft is made, up to
`ATTEMPTS_PER_SECTION` drafts for each section asked for. A section ingest
refuses raises `ProviderError::InvalidResponseError` and counts as a failure.

## The triage solve

With `--triage`, each kept section gets one more call after its judge,
`solve_section`, which `.service` adds beside the drafting routes. A solve
that fails counts as a failure, and its section is left out like a rejected
draft. The entry gains the mode, the outcome and the solver's reply, and the
file holds only `KeyTriage.sheet_sections`, every disagreement and unlocated
section and one agreement per mode, plus the summary.

## What it writes

The draft user is an unsaved `User`, so `DailyPlan` and `recent_performance`
read no history and the draft lands in no day. `.service` subclasses
`ClaudeService` to keep usage in memory for the cost line instead of writing
`ApiUsage` rows. The run is wrapped in `ReviewBaselineExport.read_only`, so a
write the override misses fails loudly instead of landing, and
`.refuse_production!` stops the runner in production.

`.reserve_out_path!` creates the output file before any billed call. It
refuses a missing directory, an existing file, and a path inside the
repository, resolving symlinks in the directory. The file is rewritten after
each kept section and once more when the run ends, even on Ctrl-C, so an
interrupted run keeps what it paid for. It holds answer keys, so it is
deleted after the read, like the key sheet.

## The spend cap

`--max-cost DOLLARS` is required with `--run`, and builds a `SpendCap`
(`docs/code-notes/script/spend_cap.md`) that `.service` hands to its
overrides. Every bound comes from one formula, `.bound`: the input at three
characters a token, which errs high for code, plus the call's full output
cap, at its route's price. The plan's total uses it too, so the plan and the
cap can't disagree. A model with no price raises instead of counting as
free.

- **Before each section,** `draft_one` checks `#section_bound`: the draft,
  the judge and, with `--triage`, the solve together. So a stop falls
  between sections, and no paid draft is thrown away for want of its judge
  or solve. That needs about $0.36 of headroom for a `code_review` section,
  so a run can stop up to that much short of the cap.
- **Before each call,** `call_and_log` checks that call's own
  `.request_bound`, as a backstop for a prompt longer than the plan
  measured.
- **After each call,** `log_usage` adds the reported usage's cost and prints
  the running total. A timed-out call reports no tokens though the provider
  may have billed it, so it is counted at its bound and the line says so.

When a check fails, `SpendCap::Reached` ends the run before anything is
sent: the sections already kept stay in the file, and the tally's `stopped`
line, printed and written, says what it stopped on. A retry the client makes
on a 429, a 5xx or, for a call that isn't long-running, a timeout goes
through no override, so it isn't checked again. A failed request is rarely
billed.

## The plan

Without `--run` it prints the most calls it can make, before
`ClaudeService`'s own retries on a connection error, 429 or 5xx, and a bound
with every call at its output cap (`ClaudeService::MAX_TOKENS` for the retry,
`CallProfiles::JUDGE_MAX_TOKENS` for the judge, the same `MAX_TOKENS` for
a solve, which sets no cap of its own) and no caching, from `.bound`. With `--triage` the
plan adds one solve per draft, since a failed solve discards its section
and another draft follows. The retry's
input is measured from the prompt a real retry sends, ladders included, by a
service that stops at the provider call. The judge's input is measured over
`FakeService`'s canned section. Both are counted at three characters a
token. Real drafts write
far less than the cap, so the run's own cost line, from the reported usage,
is the number to record.

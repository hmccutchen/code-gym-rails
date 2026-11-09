# Daily mastery reconciliation

Protected-practice P-C added a policy-2 interpreter and version-2 envelopes
with initiation off; P-A enables new protected-practice enrollment after
the compatibility deployment gate. Existing v1 receipts and operations retain the
policy described here, including eased retention. Mixed journals dispatch
each operation by policy and preserve the extended request map through
v1 replay and manual commands. See `protected-practice-opportunities.md`
for enrollment, exact v2 behavior and the P-C rollback floor.

## Activation and compatibility

`ConceptMastery::INITIATE_RECONCILIATION` is true in release A, following
release C's verified web and worker deployment and removal of pre-C writers.
C keeps the default false: untouched users reached by C retain per-batch
orchestration and write no reconciliation state.
The shared projection filters retired/off-vocabulary tags and uses each
section's bucket identity; default-off does not preserve obsolete tag writes.
Under the
user lock, an uncached existence check for any response receipt or open
mastery suffix selects reconciliation for that entire user. The receipt
used as the enrollment signal is decoded, as is the current receipt.
Every selected open suffix is decoded before applying any effects. No mode
decision is cached during a provider call.

The default controls initiation only. Manual drill commands, admission and
Learn controls always honor stored suffixes. A complete receipt survives
suffix compaction, so returning from activation A to C cannot disable an
already-enrolled user's writer.

## One contribution, replaced at its original position

`DailyEvidence` projects submitted, answered, validly assessed sections
through the existing mastery-kind and closed-vocabulary authorities.
Contributions have response/concept/bucket identity. Their grade is the
least favourable grade and every contributing self-rating must be
favourable for mastery. No rubric or rung requirement is added.

`DailyResponse#mastery_tag` owns the strict kind/vocabulary/bucket identity
leaf shared by contributions and skip candidates. Their answered, assessed
and reviewed selection stays outside that leaf. Skip exclusion still sees
answered mastery-eligible tags even with an invalid grade. Reinforcement's
historical nil-bucket fallback and hostability selection remain separate.

Partial effects are immediate. A successful sibling replaces the same
contribution, then the retained operations after it are folded again.
Replacement preserves the first application's UTC microsecond timestamp,
local review date and immutable work date. Later reviews keep their own
position and clocks. A first-ever late review is applied when it arrives;
this is not a historical rebuild.

`Transition` is the v1 authority and shared retention primitive for the nine mutable
fields: tier, streak, last rating, cooldown, first mastery time, retention
interval and date, drill time and group. Both writers use it. Standard
steps down after three stagnant attempts; reduced pauses after two, with
two later core sessions to return. Retention starts at seven days, doubles
only when due on the work date, caps at sixty, and schedules from the
recorded local review date. Comfortable eased success still starts
retention under v1. Policy 2 changes all-eased comfort as described in
`protected-practice-opportunities.md`; all-history checkpoints (#264)
remain outside this release.

The curated `RealSource` retention entry follows the extracted
`Transition#retention_interval` at its existing list position. The obsolete
method no longer resolves. This changes that excerpt's source identity, so
it may be offered as unseen; no source-history backfill or pool reordering
is introduced. Generation's captured inputs and retry reuse are unchanged.

## Closed persisted formats

Only the exact JSON object `{}` denotes unused state. JSON null, arrays,
scalars, unknown versions and malformed envelopes raise `ArgumentError`;
they never select a legacy fallback or get reset.

`DailyResponse.decode_mastery_application` owns the version-1 receipt:

```json
{"version":1,"legacy_sections":[],"processed_sections":["pattern"],
 "session_counted":true,"skip_attempts":[["ruby_rails","memoization"]]}
```

Successful invalid grades and walkthroughs are processed without becoming
assessment evidence. Failures are not processed. Skip attempts are unique
per response/concept/bucket even when their first effect is a no-op.

`Reconciliation` owns the version-1 suffix: `version`, `baseline` (exactly
`Transition::FIELDS`) and `operations`. Its closed operations are `review`,
`session`, `skip`, and `drill` with `set` or `clear`. The action schema is
selected only under `drill`; `set` and `clear` are never top-level types.
Dates use ISO dates;
timestamps use UTC ISO timestamps with six fractional digits. Operations
contain only identity, evidence and explicit clocks/intent: no answers,
provider prose, answer keys or credentials. Both JSON columns are filtered
from request parameters and Active Record inspection.

An open suffix starts at the earliest still-pending same-concept answered
occurrence. Stored invalid grades and skipped walkthroughs are terminal,
not pending retries. Prefix compaction moves irrevocable operations into
the baseline. Once no review remains pending, the suffix becomes `{}`.
The response receipt remains. A long-abandoned partial can retain an
unbounded suffix; there is no arbitrary history-window truncation.
The v1 codec intentionally reads the current closed kind, grade,
self-rating and tier authorities. Retiring or renaming kinds, or changing
those tokens or their semantics, requires preserving compatibility or a
deliberate migration of both durable receipt tokens and open suffix
data/policy before rollout. Receipts outlive suffix compaction. Freezing
decoding alone cannot preserve replay under incompatible policy.

## Clocks, countdown and administrative operations

The service preserves the first assessed-core transition check and the
model requires a newly successful assessed core section as well. A
supplementary-only batch never consumes cooldown. Session attempts are
retained for every already-open suffix, including currently standard rows:
a correction can make a formerly ineffective tick meaningful.

Mastery eligibility must imply adaptation eligibility for every registered
kind and supported code-review mode. This puts a day's own session before
its first mastery contribution; a replacement cannot leave that session
behind its own contribution. An invariant spec pins the implication.
A future mastery-only kind requires a separate ordering decision, rather
than removing either first-core guard or inserting hypothetical ticks.

Skip attempts retain their original work/review dates and re-evaluate the
due and positive-interval predicates during the fold. A concept answered
anywhere on the response is excluded. No row is created for a skip.
The next date is the later of work and review dates plus the interval.

## Drill reservations and intent

`ConceptDrills.for` combines active rows with
`Reconciliation.restorable_drill`. Restorable intent starts with the suffix
baseline and follows explicit set/clear commands only. An explicit Stop
permanently releases older intent; a later Start establishes new admitted
intent with its own timestamp/group.

The existing cap covers active plus reserved requests. A group counts once
across both kinds of member, with the existing vocabulary/language slice.
An entirely reserved group still holds its slot. Group admission can absorb
reserved lone members, and a member can rejoin a reserved group.
Planning and reinforcement continue to read materialized columns only.

Reserved repeat Starts return false without reactivation. Active repeats
retain their exact stamp and group, never re-add cleared members, and do
not override a pause. Accepted single Starts retain their end-pause meaning;
group Starts never end a pause. Concrete command targets are frozen when
accepted. Replay never repeats admission or group expansion.

Concept Stop resolves the current accepted group. Group Stop reaches only
current/restorable members of that group, never a concept explicitly
restarted alone after an earlier Stop. Commands follow commit order; a
genuinely later concept Stop stops the current request.

Learn marks reserved members “review pending”, explains that they are not
currently prioritized, and keeps Stop available. Held-slot refusal and
repeat messages use the same server projection. An abandoned review can
hold a slot until completion or explicit Stop; that cost is visible.

`ConceptDrills.start` and `.start_group` return an `Outcome` with
`started`, `already`, `already_reserved` or `full` status and the admission
projection captured under the user lock. The controller maps that outcome
without another query, including the names and reservation facts on cap
refusal. It describes the accepted command even if another command or
review commits before rendering. Existing `.start!` and `.start_group!`
delegate to those commands and retain true/false and `LimitReached`;
the outcome API is the deliberate HTTP-facing exception, not a change to
the bang-method contract.

Corrupt selected in-slice suffixes fail Learn index/detail and drill actions
explicitly. They are not omitted from the cap or replaced with invented
capacity. This release adds no partial-library fallback or automatic repair.

## Transaction and historical cutoff

All writers take user → exercise when needed → response → mastery rows in
ascending ID order. Review uses no exercise lock. Paid calls occur before
locks. A fresh locked user serializes persistence without reloading the
provider-bearing user used for the call. The response is reloaded and its
claim token checked before merging. All mastery, suffix, receipt, review
and failure writes share the response transaction.

Authoritative format validation stays inside the user/response locks,
after the provider call. Pre-existing corruption can therefore reject
storage after a call; retries can incur additional calls until the data is
repaired. The caller's claim is released and the transaction rolls back.
This release adds no preflight and makes no zero-billing guarantee.

`record_review!` requires the caller's actual pre-merge review keys. On
first enrollment they become an immutable legacy prefix. Existing
materialized mastery is the baseline; those keys are not applied again.
Previously assessed core evidence initializes the countdown receipt.
Historical pre-#717 ticks are neither inferred nor repaired.

A wholly unreviewed old submission receives new semantics. A fully
reviewed old submission remains untouched. A partially reviewed old
submission keeps its already-applied effects and gains a new contribution
for newly accepted evidence. Only contributions first applied by the new
writer have the complete order-independence guarantee.

## S / C / A deployment and rollback gates

S's additive columns shipped separately in PR #728, migration
`20261106062129`. Its web and worker deployments were verified before C
implementation; C neither repeats the migration nor activates initiation.
S's ordinary prepared-read additive-DDL caveat does not mean Rails `lock!`
prepares its query; no global query/retry workaround is added.

Before A, record fresh Railway evidence for both web and worker: current
deployment ID, SUCCESS status and commit hash at C or a verified descendant.
Every pre-C process capable of writing must be REMOVED or positively
terminated, including replicas and one-off consoles. Expand deployment
history if two entries do not account for all live writers. A health check,
elapsed time, merged PR, schema waiter or CI success is insufficient.

A is a separate source change setting initiation true. Mixed C/A writers
serialize under the user lock and honor durable enrollment. After A,
verify both services at A or a descendant, obsolete deployment removal,
and a fake-review straddle smoke in an owned preview or test environment.
This retains the original accepted design's preview/test allowance. The
project-scoped environment inventory after C contained only production,
so the activation smoke uses an owned local test database; it does not
claim a Railway preview or production test writes. No paid production probe
or historical UPDATE is needed. Keep #726 open until activation and its
deployment are verified; staged PRs use `Refs #726`.

Rollback from A to C is supported. Rollback before C, deletion of receipts,
or reverting S after state exists is unsafe. If deployment access/evidence
is missing, keep initiation false and A unmerged. C's local passing tests
are not production activation evidence. Final full suites run in CI.
Follow the review process in `CLAUDE.md` before publication. CI remains
advisory, not branch protection.

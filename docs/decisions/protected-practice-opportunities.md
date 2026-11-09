# Protected practice opportunities

## Activation and compatibility

P-C implemented #712, #714 and #716 with
`PracticePolicyMode::INITIATE_PRACTICE_POLICY = false`. P-A sets it to true
after the verified P-C web/worker rollout and removal of older writers,
so untouched users enter protected practice on their next qualifying write.
P-S supplied `concept_masteries.practice_requests`; activation adds no
migration. The existing reconciliation initiation switch stays true.
The source default does not establish that the activated deployment is
complete; the post-activation gate below still applies.

The uncached mode reader validates every nonempty receipt, journal, request
map and schedule note before choosing the writer under the user lock. Any
v2 receipt, v2 journal, nonempty request map or policy-2 schedule note keeps
the user enrolled regardless of the initiation switch. Unknown or malformed
nonempty state raises before writes. Exact `{}` alone means unused.

Scheduler assignments and service entries validate their owning kind through
`ConceptBucket.valid_kind_identity?`: the closed concept/bucket pair must be
recordable by that registered kind under a supported exercise language.
Historical service may belong to a currently unselected kind. Validation
does not depend on the user's current language or today's host restrictions.

Existing response receipts retain their policy. A response first received
after enrollment gets a v2 receipt; its already-reviewed legacy prefix is
grandfathered. A v2 journal has the nine v1 state fields plus
`practice_requests`, and every review operation has an explicit policy.
Upgrading an envelope labels old operations policy 1 without adding an
`eased` field or changing their clocks. Policy-1 transitions pass extended
state through. Replacement retains the original operation position, UTC
microsecond timestamp, work date and user-local review date. Compaction
folds each operation with its own policy. There is no history rebuild or
request backfill.

## Requests and retention

Requests live on a user's concept/bucket mastery row, keyed by registered
kind. Each entry has exactly `mode`, `source_response_id` and `requested_at`.
Modes are `support`, `simplified` and `normal_retry`. The source and timestamp
come from the original review operation, including after correction.

- Solid/strong with too-hard requests wording/organization support.
- A weak grade with too-hard requests simplified reasoning.
- Comfortable eased success requests a normal retry.
- Comfortable normal success clears that kind's request.
- Solid/strong with a missing self-rating preserves the entire existing
  request, including its source and timestamp; it earns no normal retry.
- Weak-but-not-hard after a retry changes it to support, including when
  the self-rating is missing. Support keeps normal cognitive demand and takes
  that weak operation's original source and microsecond timestamp, never
  the correction or replay clock. It does not assume an effort rating.
- Other evidence retains existing intent. These per-kind changes preserve
  unrelated requests and do not skip the ordinary aggregate weak-grade effect.

All-eased comfortable success returns an unpaused row to standard and resets
stagnation. It never grants or grows retention or clears an admitted drill;
earned retention fields stay byte-for-byte unchanged. A paused row keeps its
pause/countdown and gains the request. Mixed normal/eased comfortable
evidence can earn retention once while an eased kind still needs its retry;
a weak sibling prevents the aggregate retention effect.

`Transition` remains the authority for ordinary retention and the v1
interpretation. Single/group Start, Stop, re-Start, countdown and skip
operations preserve requests through reconciliation. Admission counts active
plus restorable drill intent; scheduling sees only active drills.

## Opportunities within the chosen size

`PracticeEvidence` counts the first two submitted sets that have an assessed
answered core section and no unanswered assessment for an answered core
section. Fixed sets count. Skips need no walkthrough; supplementary bug
hunts do not count. This readiness check has no rubric/rung requirement.
Capture carries validated readiness and asks only for the current regular
kinds' latest informative verdicts. The history reader stops when both needs
are settled. A missing verdict still requires a full scan, and an old weak
verdict survives intervening neutral or eased work without a row/date cap.
Pending requests load separately. Mandatory durable-mode scans remain.

Once ready, a newly inserted Automatic two-section set repeats variety,
pair, pair. Variety replaces one place; it never adds workload. Other sizes,
fixed settings and one new-pair acknowledgement pause the phase without
resetting it. With an empty eligible pool the pair remains and the variety
phase is consumed. Exclusions have no fallback override, and a daily fourth
keeps every fourth sibling unavailable even when that daily kind is omitted.

The last informative weak or too-hard assessment protects a regular kind.
A comfortable normal assessment clears that protection; comfortable eased
work does not. Protect the sole struggling kind. With both or neither
struggling, alternate the omission, beginning with the later place.

Eligible optional kinds keep one stable order across rounds. Seed it by
retry/support need, due checks, active drills, least recent exposure and
weighted ties. Pool edits preserve surviving order. In a stable pool of N,
each kind appears within N variety opportunities, or 3N new eligible sets.
Fixed/large sets and explicit pair acknowledgement do not spend that cursor.

`PracticeSchedule::Assignments` matches the whole chosen set through the
shared augmenting matcher in `SharedConcept`. Kind-specific requests keep
their host. Maintenance can move to an uncontested host before consuming a
protected kind's practice turn. A contested host alternates practice and
maintenance, starting with practice; maintenance alternates retention and
drill, starting with retention. Practice orders by last practice service,
then retry/simplified/support/reinforcement, source time and vocabulary.
Maintenance does not give a different simplified request practice credit.
Due checks retain overdue priority; drills retain their existing order.
Shared-concept reinforcement uses remaining hosts only.

## Captured plans and persistence

`PracticeGeneration.capture` locks the user, reads mode and settings fresh,
and freezes the schedule context before the provider call. No lock spans
HTTP. A new-set commit locks the user again, validates all durable formats,
then compares settings, mode, latest exercise and predecessor continuation.
A same-date duplicate returns the winner; an obsolete different-date result
is discarded as superseded. No failed/duplicate/superseded call spends a
turn or silently purchases another generation.
An explicit settings edit can discard an already-billed draft, including
for an inactive user. New-set generation records its existing retryable
message; regeneration keeps the old set, draft and notes and releases only
its own claim. Neither path retries automatically or spends a cadence turn.

The captured date controls weekday mode, the workload cutoff and the stored
work date. Initial delivered-history, retention due/overdue, inactive
coverage and featured-concept reads still use their live clocks. Capture is
not an all-read historical snapshot.

Replacement locks user, exercise, then response and checks the original
claim token and replace blocker. It reuses the original optional turn where
settings still permit it. It may change displayed kinds and assignments,
but preserves original sequence, phase, regular-pair acknowledgement and
the entire continuation. Start over uses the same path. Moving a held set
changes no schedule metadata. A regenerated legacy row receives no schedule
note and invents no variety turn; its active adjustment stamps can still
describe the regenerated content.

`plan_notes["practice_schedule"]` is format 1, policy 2: positive sequence,
readiness boolean, registered regular/selected kinds, nullable phase,
optional omitted kind, concept/bucket/reason/adjustment assignments, and a
continuation containing next phase, stable order/cursor, last omission and
bounded service records. Service records retain current competing practice
identities only. They are scheduling history, not grades or a second target.
Historical rows without this field keep the legacy reader behavior.

## Generation, grading and pages

One resolved adjustment per selected section controls both prompt and ingest.
Normal retries override reduced-tier fallback. Locks suppress all easing and
review-gap help without deleting requests. Provider-supplied stamps are
stripped. Only simplified reasoning stamps `eased: true`; every active
section receives the server's `practice_adjustment`. Assigned concepts are
checked from the initial draft as well as retries. Extra provider sections
cannot restore an omitted kind.

An optional gap is one normalized missed-point string, at most
`PracticeEvidence::GAP_LIMIT` (300) characters, fetched through the owner's
response relation and checked against kind/concept/bucket. It is quoted as
data. Arrays of objects, foreign responses and mismatched tags supply no
gap. No answer, full review or planted key is copied. Diagnostics store
assignment identity/mode, never this prose or its source response.

Kinds own their format guidance. Parsons keeps order grading; pseudocode
still asks the learner to write a plan; hidden concepts and planted answers
stay hidden and planted counts do not change. Judges strip server stamps
and graders use their existing explicit context fields.

Inactive pages and prompts retain legacy wording. Enrolled Welcome, Setup,
Learn and swap copy describes replacement within capacity and competing
drills. A dashboard variety note names a replacement only when the stored
selection and delivered active kinds agree, and qualifies the next-pair
statement with unchanged settings. Delivered simplification shows only
“Practice adjusted from your reviewed feedback.” It names no diagnosis,
hidden concept or retry promise. A dropped replacement earns no compensation.
Invalid optional policy copy, dashboard notes and picker consequences show
explicit unavailable text and log only record/user identity and error class.
They never substitute legacy promises. Strict writers still validate every
signal; Learn still refuses corrupt selected reservation suffixes rather
than inventing library contents or capacity. Targets never change
automatically; #720's preview/Apply/version and target-preservation behavior
is unchanged.

## Proposal evidence

`LevelSuggestion::Evidence` now reads the last 180 user-local calendar days,
inclusive of today minus 179, in preloaded cursor batches. It projects the
existing strict current-rubric, stamped, normal, answered core evidence and
keeps one result per kind/date. There is no global response-count cap.
Offers require the newest own-kind result on or after today minus 29.

The existing five/four up rule and two-hard/latest-three down rule remain.
A lower offer also requires two distinct valid concept/bucket identities
among those too-hard results and the existing weak-AI condition. Missing
tags cannot prove breadth. Rung cutoffs, locks, grouping, precedence and
explicit Apply remain unchanged. Other kinds and elapsed time cannot
manufacture an offer.

## Delivery and evidence

P-S must be deployed before P-C reads the new column. Before P-A, verify web
and worker SUCCESS at P-C or compatible descendants and stop all older
writers, replicas and one-offs. Only a separate activation change may flip
initiation. After any v2 state exists, P-C is the rollback floor, including
after journal compaction. P-A → P-C stops new enrollment and continues
enrolled users; deleting receipts/requests/notes is not a rollback.
After P-A, verify both services and removal of older instances again before
closing #712, #714 or #716. PRs reference those issues without closing them.

CI specs cover mixed-policy corrections, real PostgreSQL locking,
opportunity bounds, weekday proposal dates, and actual rendered prompt
measurements. `PRACTICE_MEASUREMENT` lines report bounded results, including
first/fifth dates, realized pools/gaps and ladder/practice-block characters.
Token estimates use characters divided by four; they are estimates, not
provider billing. The existing ladder ceiling is unchanged. No local
behavioral execution or measurements were authorized for P-C development;
CI results and independent reviews must be recorded before release.

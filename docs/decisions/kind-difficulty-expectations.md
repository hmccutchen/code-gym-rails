# Kind-owned difficulty expectations

Issue #718 makes the existing rung meanings concrete for every exercise
format. It changes prompts, not level selection, workload, mastery,
graduation, numerical grades or evidence eligibility.

## Authority and composition

`KindDifficulty::LEVEL_DEFINITIONS` remains the single shared standard:
junior makes the concept visible in a small scenario; mid-level requires
close reading to find its application; senior makes a stated constraint
or interaction matter; principal weighs costs at system scale. These
describe depth of reasoning, not how long an answer or artifact must be.
For a named-pattern question, finding the application does not mean hiding
the pattern's name.

Each kind owns `RUNG_GUIDANCE`. `ExerciseSection.difficulty_definition`
takes `rung:`, optional generation `mode:`, and optional review `section:`.
It returns a small immutable value with the effective `rung` and concrete
`expectation`; `standard` reads the shared meaning for that rung, and the
string form joins standard and expectation. Within a configured level,
generation groups equal effective rungs, names each kind's expectation,
then groups concept/text pairs by their actual owner sets. Shared guidance
appears once; kind-only guidance has a narrower heading even when other
kinds share its effective rung. The section judge, review
and unanswered walkthroughs use the same value's string form. Shared
prompts never branch on kind or mode.

The code-review bug-hunt hook resolves context through the existing
`BugHunt.mode?` and `BugHunt.section?`. It reads `Prompt::RUNG_LINES` and
`RUNG_FOR`, including the existing principal-to-senior mapping. It never
reads the hidden key. A historical section without `purpose` uses the
ordinary definition. The other kinds need no stored fields.

Design comparison reuses its existing `RUNG_GUIDANCE` unchanged. Its old
generation-only rung rendering is removed, as is the duplicate bug-hunt
rung line in the format instructions. The format instructions, schemas,
grading notes and principal comparison grading exception remain.

Concept ladders now refine a baseline that is always present. Previously,
the shared standard was phrased as a fallback for an unlisted concept,
and most kinds had no explicit expectations. A ladder cannot override a
kind's format or expectations. Locks, easing and retention rules still
apply as before.

`GenerationLadders` selects reference text at the definition's effective
rung and keeps each kind's ownership. This repairs the inherited principal
bug-hunt lookup, which previously paired a senior-equivalent expectation
with principal reference text. The generic/no-pick API can offer one concept
to both a principal bug hunt and an ordinary principal kind; each keeps its
own text in either input order. Normal picked-gotcha plans still exclude
the trap's concept from other kinds. Missing references add no guidance.
No configured target, captured rung, `pitched_at`, reference record or
historical eligibility changes.

Shared expectations describe the task, rather than telling a generator
to pitch it or telling a grader to conceal missed ambiguities. Answer-hiding
rules remain in the generation format. The judge no longer needs a second
principal-as-senior exception paragraph; its answerability, key safety
and prose-only editing contracts are unchanged.

## What varies, and what stays fixed

The exact prompt wording lives on the kind classes, not in this table.

| Kind | Progression in reasoning | Format retained |
| --- | --- | --- |
| Code review | Visible local issue; trace calls/data; explain a constraint-sensitive fix; weigh the fix's system costs | Application, test, schema and multi-file artifacts; no new file count or defect requirement |
| Design comparison | Explicit deciding fact; apply a requirement; connect system facts to structure; weigh both pieces' costs | Two working, equally readable pieces; the stated facts decide |
| Pattern | Direct application; derive application from requirements; adapt to an interacting constraint; weigh boundary costs | Named pattern, self-contained question, workable structure and calling interface; no snippet |
| Challenge | Direct implementation; derive steps; satisfy interacting requirements; weigh costs of the stated behavior | Any supplied starter; no unstated production features required for credit |
| Architecture | Explicit tradeoffs; infer tradeoffs; weigh interacting constraints; weigh system costs on both sides | Short scenario, viable alternatives, all stated constraints, defensible alternative answers |
| Security review | Visible path from input to unsafe use; trace input; account for stated deployment/behavior; weigh mitigation costs | One exploitable vulnerability and a mitigation, never a wider audit |
| Parsons | Direct data dependencies; trace state/control flow; interacting dependencies; ordering under a system constraint | Supplied coherent blocks, existing block count and Ruby-computed rating; no written answer |
| Plan review | Plain flaws; connect steps to the request; trace constraint interactions; weigh consequences and correction costs | Existing planted count and category breadth at every rung |
| Ambiguity hunt | Concrete missing behavior; trace realistic use; gaps at requirement interactions; consequential system choices | Full requested planted set, hidden key, clarification rather than invented requirements |
| Pseudocode to code | Direct decomposition; derive decomposition; preserve interacting requirements; weigh costs in a bounded plan | The engineer writes the plan first, at least one stated missable requirement, no supplied code/signature/example |

Bug hunts retain their separate concrete scale: the first suggested input
fails at junior, an apparently successful input masks another failure at
mid-level, and an edge case or trap in the obvious fix distinguishes
senior. Principal uses senior here. The bounded puzzle never becomes a
system-design question.

Existing format sizes remain with their current authorities, including
`CodeReview.file_range`, `AmbiguityHunt::PLANTED_COUNT` and the distinct
ingest bounds. The shared junior phrase "one instance" does not reduce a
format's planted set or architecture's plural constraints.

## Offline calibration, 2026-11-06

This is an offline reading of synthetic repository exercises and answers,
not provider output from this change. No provider was called, no user's
key or private exercise was inspected, and no new exercises were generated.
The existing six files under `spec/fixtures/review_calibration/` contain
20 answers including the comparison's two extra answers. Each was read
against the old and composed definitions and the unchanged actual-problem
rubric. The expected reasoning is:

| Fixture | Complete | Partial | Missed |
| --- | --- | --- | --- |
| `pattern_export_permission` | Central policy used by controller, job and API; owner/account-admin permission remains subordinate to suspension, including at job execution | Centralizes the rule but omits suspension, an essential stated condition | Controller-only check leaves the job/API rules duplicated and omits suspension |
| `design_comparison_shipping_rates` | B, monthly carrier additions, and the extension principle connected to the unchanged dispatch method | B and monthly additions, but no explanation of the structural principle | A justified only by readability, not the stated rate of change |
| `challenge_discount_code` | Lookup, unknown/expired rejection without mutation, percentage reduction, zero floor and persistence | Finds and applies a code but omits expiration and the zero floor | Merely stores the submitted code; never applies the discount |
| `code_review_n_plus_one` | Locates the customer load inside the view loop, explains query growth and supplies controller eager loading | Correct diagnosis, no fix | Pagination/index advice leaves the per-order customer lookup |
| `ambiguity_hunt_workout_export` | Clarifies format, range, deleted/archived inclusion and timezone; large-export delivery is a legitimate additional question | Clarifies only format/range; inclusion and timezone remain unanswered | Chooses an implementation without asking about any planted gap |
| `security_review_sql_like` | Explains input changing SQL structure and uses parameter binding; wildcard escaping preserves literal-search semantics | Identifies SQL injection but supplies no mitigation | Index/performance advice does not close injection |

The complete answers remain at least solid, partial answers developing,
and missed answers beginner under the existing notes. The ambiguity
answer's additional valid question can earn strong. The exact solid/strong
boundary for other complete answers is not resolved by this offline
reading, and no live rating is claimed.

The comparison's `vague_correct_pick` has no deciding fact and is below
solid; whether it is beginner or developing remains the fixture's allowed
ambiguity. `other_pick_sound_reason` earns developing under the existing
note because it connects monthly additions to A but chooses against the
key. There is a real fixture limitation: both pieces delegate to rate
classes and both require editing a carrier list. The answer's claim that A
avoids a new class is inaccurate, and the key's preference for a registry
over a branch is less decisive than an independent requirement could make
it. This ambiguity predates #718; the reused comparison expectations do
not resolve it, and the fixture/key were not rewritten to claim agreement.

### Shipping fixture correction, 2026-11-09

#732 corrects that synthetic fixture without changing either code snippet
or any expected rating. The scenario now states that changes to
`ShippingQuote#cost_cents` require checkout recertification, while carrier
registration and individual rate classes can change without it. Both pieces
still need a new rate class and a carrier-list edit. B keeps that edit in
`RATES`; A puts it inside `cost_cents`. The key's open/closed claim applies
to the calculation method, not to the whole class.

The complete answer connects this constraint, the code and the principle.
The partial answer names B and the constraint but omits the structural
explanation and principle. The missed answer still argues only readability.
The alternative A answer now correctly describes a small branch addition
and a new rate class, tied to monthly carrier additions; it overlooks the
decisive recertification cost. Its expected `developing` rating follows the
existing non-principal other-pick rule, not the former false claim that A
avoids classes. The vague matching-pick range is unchanged.

The calibration runner spec checks that the corrected constraint and
decoded alternative reason reach the grader. Its fake-provider run checks
fixture plumbing, not grading quality. No new live-provider calibration,
rating agreement or cost measurement is claimed. The actual-problem rule,
four rating meanings, principal comparison exception, `RUBRIC_VERSION`
and historical eligibility remain unchanged.

### Other fixture limits

The discount fixture does not specify failed saves, nil expiry or rounding.
Those are not new essential requirements. Likewise, the export fixture
does not state scale interactions despite its senior stamp. It remains
graded on the four actual gaps, not on invented senior requirements.
The historical pattern fixture's title does not literally name the
pattern, unlike today's generation schema; this does not change what a
working answer to its self-contained question must cover.

### Adjacent-level and missing-format cases

These are additional hand-written offline cases, not generated samples or
automated claims about a provider's judgment:

- **Named pattern, junior → mid → senior:** a question titled "Policy
  object" asks for one export rule. At junior the callers and rule are
  explicit; at mid the engineer works out which callers need that same
  interface; at senior a stated suspension-at-execution rule interacts
  with scheduling. A policy taking the requesting user and report and
  checking the current account state covers the senior case. An
  owner/admin-only check misses suspension. Moving checks only into the
  controller misses the shared-rule task. Keeping the title at mid does
  not make the exercise invalid.
- **Code review, junior → mid:** compare a customer lookup directly inside
  the shown order loop with the same lookup inside a shown `customer_name`
  helper. Eager loading and explaining the repeated lookup completes
  either task; diagnosis without a fix is partial, and optimizing the
  sort alone misses it. Mid adds tracing, not more defects or a requirement
  for more files. At senior, a stated stale-cache constraint can make a
  cache-only fix incomplete; without that stated fact it is not a miss.
- **Bug hunt, mid → senior/principal:** `nums.each { |n| nums.delete(n) if
  n.even? }` promises to remove every even number. Alternating values
  can work while adjacent even values expose the shifted-index skip.
  Explaining mutation during traversal and replacing it with a correct
  selection completes the answer; merely naming mutation lacks the fix;
  tracing only the successful case misses the trap. An adjacent-input
  failure can fit mid or senior depending on what input the purpose first
  suggests: this is a genuine boundary overlap, not a crisp classifier.
  Principal must not demand distributed-system analysis of this puzzle.
- **Architecture, junior → mid → senior:** offer inline notification
  (30ms, one request path) and a queue (15s delivery, another operational
  dependency), with checkout under 150ms and notification within 30s.
  Both are viable. Junior states the latency/dependency tradeoffs;
  mid asks the engineer to derive them. Senior states that a burst raises
  inline work to 80ms and queue delay to 25s, making the same two budgets
  interact with headroom. Either reasoned choice can be complete; naming
  only checkout speed omits the delivery budget; asserting "queues are
  always best" supplies no reasoning. Principal weighs the stated
  system costs, without lengthening the brief or adding hidden budgets.
- **Plan review, junior → senior:** a request asks for CSV export of
  completed days while keeping notification opt-ins. The proposed plan
  writes exports from a read callback, builds an unrelated analytics
  dashboard, and emails everyone. Complete pushback explains the read-side
  effect, rejects the dashboard expansion and preserves consent; finding
  only the dashboard is partial; approving it for speed misses the task.
  Junior makes those conflicts direct. A senior variant states that
  consent can change between scheduling and sending, requiring execution-
  time reasoning while retaining the same flaw categories and count.
- **Parsons, mid → senior/principal:** six blocks form `def unique_ids(ids)`,
  initialize `seen`, open an accumulator loop, skip a seen ID, record and
  append an unseen ID, then close the loop/method. Trace the repeated-ID
  case to order the blocks. The exact order remains strong, a two-position
  swap solid, a three-position cycle developing, and a reversed order
  beginner under the existing Ruby displacement rule. This deliberately
  differs from free-text essential-gap grading. A harder retry-safe
  consumer can test acknowledgment ordering through the same bounded
  format, but must not ask for a written design argument or extra blocks.
- **Pseudocode, junior → mid → senior:** ask the engineer to merge
  overlapping or touching intervals and return an empty list for empty
  input. Complete reasoning sorts and folds intervals with the stated
  touching rule and handles empty input; initializing from the first
  interval without the empty case is partial; returning only sorted
  intervals misses merging. Junior states the stages' behavioral needs
  directly, mid leaves their decomposition to the engineer, and senior
  can state a stable-label rule for equal starts that interacts with the
  fold. No level supplies a plan to translate. Generated-code syntax and
  unstated input validation do not become essential requirements.

These cases support retaining `ReviewedSectionResults::RUBRIC_VERSION`
and all historical eligibility. They do not prove equal difficulty across
kinds or provider adherence. No changed grade meaning was identified;
the known comparison ambiguity and overlapping bug-hunt boundary remain
limitations for independent review.

## Prompt size and available ladder coverage

The existing exhaustive `MAX_LADDER_GUIDANCE_CHARS` spec measured **53,668**
characters at the merged-main base, **53,940** at the first implementation
and **53,943** after review corrections: **+275 characters** from base,
**+3** from the first implementation. The ceiling remains **54,000**, with
the original assertion intact and **57 characters** of headroom. These are
differences of maxima, not every shape's change, measured tokens or dollars.
They exclude other prompt text, including the newly shared judge definition.
Removing the old comparison and bug-hunt rung lines also removes
duplication outside the measured block.

Both maxima use JavaScript, application-code mode, four sections
(`code_review`, `design_comparison`, `pattern`, `challenge`), and only
code review locked. Before, their levels were respectively junior,
principal, mid, senior; after they are junior, principal, senior, mid.
Every offered ladder entry is filled to
`ConceptReference::MAX_LADDER_RUNG_LENGTH`. The spec enumerates its
existing default-pair day shapes, languages, modes and all rung/lock
assignments; it does not fetch private exercises. Mode is now forwarded
to the measured renderer, so the bug-hunt definition is measured too.
Set `MEASURE_DIFFICULTY_BLOCK=1` when running that example to print the
maximizing shape.

The unchanged enumeration covers 28 default-pair shapes and 43,136 rung
assignments across both languages and all modes. Lock-subset maximization
and the separate exhaustive lock-overhead check remain. Synthetic ladders
now use the real builder's kind-keyed representation and the real renderer's
grouping, with no vocabulary or branch removed to fit the budget.

One additional valid fixed-four shape was measured separately:
`pattern`, `challenge`, `design_comparison`, `parsons_problem`. Its 2,048
assignments across both languages and all modes, with lock subsets
maximized, peak at **47,802** after corrections versus **47,795** at the
first implementation and **47,508** at base. Headroom is **6,198**.
The current maximum uses JavaScript/application code, levels senior, mid,
principal, junior respectively, with pattern locked. This is bounded
customized coverage, not an enumeration of every customized list or order.
The later same-rung ownership correction was remeasured at these same
default and customized maxima and shapes; neither worst-case maximum rose.

Coverage was read locally from shared `ConceptReference` identity and
nonblank-ladder metadata only, on PostgreSQL **14.22 (Homebrew)**. The
denominator unions all selectable vocabularies across both languages,
supported modes and all rungs, without user exclusions, featured-concept
withholding or a particular bug-hunt pick. It deduplicates
`(bucket, concept)` pairs: **123** total (45 Ruby, 46 JavaScript,
15 architecture, 4 plan review, 5 ambiguity hunt, 8 pseudocode).

`code_gym_rails_development` has 15 matching reference rows and **0/123**
complete ladders. `code_gym_rails_test` is empty outside test transactions:
0 references and **0/123** complete ladders. Completeness requires all
ladder fields nonblank, matching `ConceptReference#ladder?`. These local
figures say nothing about current production coverage and do not replace
the explicitly historical October report. No backfill or preparation job
was run or authorized.

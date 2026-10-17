# Daily kind swap: the in-place alternative

Status: considered, not chosen. On 2026-10-16 the swap was scoped to saving
the pair and starting with the next set
(`2026-10-16-daily-kind-swap-design.md`). This file keeps the design for a
swap that replaced today's unanswered section right away, as it stood before
that decision, so nothing is lost and it can be built later on top: every
part of it is additive to PR 0, 1 and 1b.

It is historical. It was written against `abf0892`, before #408, #411, #413
and #415 were built, and its snapshot and gate claims predate them. Where it
disagrees with the main spec, the main spec wins. Its section numbers refer
to its own text, and its "PR 2" and "PR 3" are not the main spec's. "The
brief" is the feature request the main spec describes.

## 3. What a swap does to today's exercise

A swap always saves the new pair under the user-row lock and bumps
`section_kind_preferences_version`, so an Exercise mix open in another tab gets
the usual 409. What happens to today's row depends on its state:

| Today's state | Effect on today | Why |
|---|---|---|
| No row for today (weekend, or paused with nothing held) | None. The pair applies from the next generation | Nothing to replace |
| Generating, regenerating or another swap running (`regenerating_since` fresh, or the first generation queued) | None. The pair applies tomorrow (`reason: busy`) | The in-flight work already chose its kinds, and the claim allows one paid rewrite of the row at a time |
| This set's one swap is already used (`swapped_at` set) | None. The pair applies tomorrow (`reason: set_swapped`) | One replacement per set (section 4) |
| Response submitted, reviewing or reviewed | None. The pair applies tomorrow | Submitted work is never replaced (`one-reviewed-response-invariant`) |
| Not submitted, and the outgoing section **answered** (`DailyResponse#answered?`) | None. The pair applies tomorrow | Your choice: finished work is not replaced |
| Not submitted, outgoing section **unanswered**, and the incoming kind is **already in today's set** as an optional section | None, and nothing is generated. The pair applies tomorrow | Generating would duplicate a section the user already has. Promoting the existing section without removing the outgoing one would leave the day's daily places in a state no plan produced |
| Not submitted, outgoing section **unanswered**, incoming kind not in today's set | **Replace in place:** generate one section of the incoming kind, swap the key in `problem_set`, set `plan_notes["daily_kinds"]`, and drop the outgoing key from `answers`, `section_ratings` and `concept_tags` | Matches "generates a new problem right away". Discarding would shrink the day, and keeping both would break the count. An unanswered draft is not evidence (`personalization-loop.md`) |
| A held set carried forward to today | Same as the rows above. It is an ordinary row for today once `carry_held_set_forward!` has moved it, which `DashboardController#show` does before the card renders | One rule for every row dated today |

"Answered" is `DailyResponse#answered?`, the one authority. A typed but
unanswered draft in the outgoing section is discarded, and the confirm text
says so.

### Reuse, and what is new

- **`RegenerateExerciseJob` is not a fit.** It regenerates the whole set,
  destroys the response, runs once a day (`regenerated_at`) and resets
  `generated_at`, which invalidates every draft. A swap must keep the other
  sections' answers.
- **The swapped section goes through judged generation, exactly as a first
  generation does (D4, decided).** `JudgedGeneration.call` already judges
  whatever `draft.kinds` holds, so it takes a one-kind `Draft` unchanged: the
  same judge, the same `judge_retries` (2, because the incoming kind is a
  daily kind of the plan once PR 1 moves the retry count onto the plan), the
  same re-judge of an edited design comparison, and the same drop rules.
- **The draft for that one kind** comes from a public
  `AiService#generate_swapped_section(user, exercise, kind)`:
  - it builds the plan with `DailyPlan.for(user, language: exercise.language)`
    after the new pair is saved, so the incoming kind's group, reinforcement and
    retention selection come from the normal rules;
  - it renders `GenerationPrompt#render(only: kind)` with no fixed concept and
    ingests one key (`expected_keys: [kind.key]`) with the usual stamps
    (`pitched_at`, `eased`). That is the shape `retry_section` already uses, so
    the two share one private one-kind draft method;
  - it hands `JudgedGeneration` a `finish` callback scoped to the one kind:
    the kind's difficulty diagnostics and the judge outcome, not the whole
    plan's retention and shared-concept logs, which describe sections the swap
    did not generate.
- **A swap lands only on a judged keep.** `JudgedGeneration` ships a section
  unjudged when the judge call itself fails (`judge_with_fallback` returns a
  reason, and the outcome records `fallback:`). First generation needs that,
  because otherwise the user has no day. A swap already has a section to fall
  back to, today's outgoing one, so `SwapSectionJob` treats an outcome with a
  `fallback` (on the first judgment or on a retry's), or a dropped section
  (`AllSectionsRejectedError` on a one-kind set), as "not replaced". Today
  stays intact, the pair stays saved, and the reply says the change starts
  tomorrow. One case still lands: a design comparison whose edit re-judge
  fails reverts to the unedited draft that the first judgment kept, which is
  what first generation ships too. This is the one place a swap reads the
  outcome more strictly than first generation, and the PR says why.
- **Concepts may repeat today's other sections.** The fresh plan doesn't know
  today's other concepts. A known limit, logged and not prevented.
- **`ApiUsage` gets a new purpose, `swap_section`**, for the draft call only,
  so swaps can be counted apart from `generate_exercise`. It adds a
  `CALL_PROFILES` entry with `RETRY_READ_TIMEOUT` (one section, like a retry)
  and the per-provider routing entries, routed like `generate_exercise`. A
  swap's judge and retry calls keep the existing `judge_section` and
  `retry_section` purposes, so those rows can't be told apart from first
  generation's; the swap's own row and the `[swap_section]` log line carry the
  count. The characterization spec requires one request snapshot per purpose
  per provider.

### Calls and time for one judged swap

Counted as `ApiUsage` rows, one per `call_and_log`; Faraday's retries on a 429
or 5xx happen inside one call and add no row:

| Path | Rows | Kinds |
|---|---|---|
| Judge keeps or edits | 2 (draft, judge) | any kind except design comparison |
| Judge edits a design comparison, re-judged | 3 | design comparison |
| Judge rejects, both retries used, last retry kept | 1 + 1 + 2 × (retry + judge) = **6** | any kind |
| Same, last retry is an edited design comparison and is re-judged | **7** | design comparison |

**The worst case is 7 rows** for a design comparison and 6 for any other kind,
and it holds whether the swap lands or not. An unusable draft (refused at
ingest) enters the same retry path with one judge fewer, so it stays under 7.

Wall time, from the code's own formula (`worst_case_call_seconds(t) = 3t + 46`,
with `RETRY_MAX = 2`, `RETRY_MAX_INTERVAL = 8`, `OPEN_TIMEOUT = 10`):

- **Worst case:** draft 316 s + judge 181 s + 2 × (retry 316 s + judge
  181 s) + re-judge 181 s = **1,672 s, about 28 minutes** if nothing cut it
  short. For comparison, `JUDGED_GENERATION_BUDGET` is 2,302 s, about 38
  minutes. The swap deadline below caps the job at 497 s, so this figure is
  the budget the deadline cuts down, not a time a swap can take.
- **Typical,** from `two-stage-generation.md`'s estimates for one retry cycle
  (retry 15-40 s, judge 5-15 s, re-judge 5-10 s): a one-section draft is about
  15-40 s and its judge 5-15 s, so a kept swap takes about **20-55 s**, one
  retry cycle adds about 20-50 s, and the second adds about the same. Those
  are estimates, not measurements; the first week's `ApiUsage` rows replace
  them.

### Claim and lock order

`SwapSectionJob` runs this sequence. No step nests the user row around the
exercise row; that order exists only in `carry_held_set_forward!`.

1. **Controller, under `current_user.with_lock`:** validate and save the pair,
   bump the version and write the event row. Release the lock.
2. **Controller, under `exercise.with_response_locked`:** check the table above
   (row dated today, not submitted, outgoing section unanswered, incoming kind
   absent, no fresh claim, `swapped_at` nil). If the swap goes ahead, take the
   claim with `claim_regenerating!(swapped_at: nil)`, the same conditional
   update `/regenerate` makes with `regenerated_at: nil`. Release.
3. **Job:** the paid call, outside any lock.
4. **Job, under `exercise.with_response_locked`:** re-check the claim token and
   every condition from step 2. The user may have answered the outgoing
   section or submitted while the call ran.
   - If they all still hold, write `problem_set`, `plan_notes["daily_kinds"]`,
     `swapped_at` and the response's three maps, then release the claim, all
     in one update.
   - If any changed, release the claim and drop the generated section. The
     cost is spent, and the usage row records it.

**The claim reuses `regenerating`** (`regenerating_since`) instead of adding
a column. It is already the lease on "a paid call rewriting
this row's set". `DashboardController#show`/`#status` already show the
generating page and poll while it is fresh, and `RegenerateExerciseJob`
already refuses while it is held, so a swap and a regeneration can't overlap.
The swap does **not** set `regenerated_at` (a swap doesn't use up the day's
regeneration) and does **not** touch `generated_at`, so `draft_scope` and every
other section's draft stay valid. A swap shows its own pending card rather
than the full-page generating state (below). Sharing one claim between two
purposes is a deviation from the claims pattern, and the PR states why: one
lease is what keeps a swap and a regeneration from rewriting the same row at
once.

**A swap has a wall-clock deadline.** The retry budget stays as decided, but
the job never starts a call it can't finish in time:

- **The rule.** Before each provider call, the job checks whether that call's
  own worst case (`worst_case_call_seconds` of its read timeout) still fits
  before the deadline. If it doesn't, the job makes no further call: it
  releases the claim, leaves today intact, sets the event's outcome to
  `failed` and the reply reads "starts tomorrow". This is slightly stricter
  than "check the clock, stop at the deadline": checking only the start time
  would let a call begun just before the deadline run 316 s past it, so the
  claim window would have to cover that overrun. Checking the call's worst
  case makes the deadline a hard ceiling on the job.
- **Where it lives.** The draft call is the job's own. The judge and retry
  calls run inside `JudgedGeneration`, which reaches them through the
  `Provider` struct of callables. The swap hands `JudgedGeneration` a provider
  factory whose callables check the deadline first and raise
  `AiService::DeadlineError` (an `AiService::Error`). `JudgedGeneration` needs
  no change: a judge that raises becomes a fallback (not replaced, under the
  judged-keep rule) and a retry that raises returns nil and drops the section
  (not replaced).
- **Measured from the claim,** not from job start. The claim's timestamp is
  already the job's token, and a slow queue pickup then eats into the
  deadline instead of extending how long the claim must stay fresh.
- **Value: `SWAP_DEADLINE = worst_case_call_seconds(RETRY_READ_TIMEOUT) +
  worst_case_call_seconds(READ_TIMEOUT)` = 316 + 181 = 497 s, about 8.3
  minutes.**
  - Derivation: it is the worst case of the first judged pass, one draft plus
    one judge. Under the fit rule, the first pass runs to the end at its
    worst case whenever the job is picked up at once, so a slow but working
    provider still gets one judged answer. A slow pickup comes out of the same
    497 s. If pickup plus a worst-case draft leaves less than 181 s, the judge
    isn't started, and the swap ends as "starts tomorrow".
  - Retries run only in the time left. With the typical estimates in "Calls
    and time" (draft 15-40 s, judge 5-15 s), the full budget fits: both retry
    cycles and the re-judge finish by about 3 minutes, and each call still
    passes the fit test when it starts (a retry needs 316 s left, a judge
    181 s).
  - With a slow provider (a 120 s draft, 40 s judges), the first retry fits
    but the second doesn't start, and the swap reports "starts tomorrow". That
    is the intended trade: in a degraded state a swap spends fewer calls and
    gives up sooner.

**The staleness window is sized from the swap deadline and the existing
single-stage gap.** `REGENERATION_STALE_AFTER` is 6 minutes, and its comment
says it must exceed `GENERATION_READ_TIMEOUT` (300 s) plus job pickup. Main
already breaks that: a single-stage regeneration's draft retries a 429 or 5xx
after a full 300 s read, so its worst case is `worst_case_call_seconds(300)` =
946 s. Once a claim goes stale, three things go wrong:

- `#show` and `#status` stop reporting it, so the page shows the old section
  while the job is still running;
- a second swap or a regeneration can take the stale claim, and the first job
  then finds a different token under the lock and throws its paid result
  away;
- a job with no deadline can land later, onto a page the user went back to.

PR 2 therefore sets `REGENERATION_STALE_AFTER = [worst_case_call_seconds(
GENERATION_READ_TIMEOUT) + JOB_PICKUP_MARGIN, SWAP_DEADLINE].max`, with
`JOB_PICKUP_MARGIN` at 60 s, the margin the 6-minute value already assumed
(360 s − 300 s). That is 1,006 s, about **17 minutes**, and it is set by
regeneration's existing gap, not by the swap. The swap needs only 497 s,
because its deadline is measured from the claim. A worker that crashes
mid-call holds the claim for 17 minutes instead of 6; the PR says so. The
38-minute judged-regeneration window belongs to PR 4, which creates it.

**The card shows its own pending state; the rest of the day stays
interactive.** Reusing the `regenerating` claim is what would force a
full-page generating state: `DashboardController#show` renders
`dashboard/_generating` in place of the whole day whenever `regenerating?` is
true, and `#status` reports "pending" for the whole row. The claim can stay
the single lease for mutual exclusion, with the page told which kind of
rewrite holds it:

- **Two nullable columns on `daily_exercises`, `swapping_place` and
  `swapping_kind`,** set in the same update that takes the claim and cleared in
  the same update that releases it. A fresh claim with `swapping_place` nil is
  a regeneration, and the page goes full-screen as today. A fresh claim with a
  place set is a swap.
- **`#show` renders the day normally,** with the outgoing card replaced by a
  `responses/_swapping_section` card: the place's heading, "Making a new
  Architecture section", a polite live region and `aria-busy="true"`. That
  card carries the existing `generating` Stimulus controller, pointed at
  `#status`, which now answers `{status: "swapping", place:}` for a swap
  claim. On `ready` or `failed` the controller reloads the page, as it does
  today.
- **The outgoing section can't be answered while it is being replaced.** It
  isn't on the page, and `ResponsesController` refuses a save for that key
  while the swap claim holds, with the existing `render_section_error` path.
  Every other card answers and autosaves as usual. `RegenerateExerciseJob`'s
  and the controller's existing claim checks still keep a regeneration out.
- **Submit is not blocked.** The user may submit while a swap is pending.
  `submit_blocker` is unchanged, so it counts the pending place as an
  unanswered section, as it would any skipped one. Submit and the job's final
  write both run under `with_response_locked`, so whichever takes the lock
  first wins:
  - **Submit first:** the job's re-check finds the response submitted,
    abandons the section, releases the claim and records `outcome: failed`.
    `swapped_at` stays nil, but the set is submitted, so that doesn't matter.
    The submitted day holds the outgoing section, unanswered, which is what
    the user saw when they submitted.
  - **The swap first:** the day now holds the incoming section, unanswered.
    The submit that follows counts it as unanswered, which matches the page
    the user submitted from, since that page showed the pending card in that
    place.

  Either way the submitted dashboard renders what was submitted and ignores
  a claim that is still fresh. Neither order loses an answer: the outgoing
  section couldn't take one, and the incoming one never reached the page.
- **Longest takeover of the card:** typically 20-55 s, about 3 minutes with
  both retry cycles, and never more than `SWAP_DEADLINE` (497 s, about 8
  minutes) from the claim while the worker is alive. If the worker dies, the
  card stays pending until the claim goes stale, 17 minutes. After that,
  `#show` sees a stale claim and renders the outgoing section again, and the
  next swap or regeneration can take the claim.

## 4. Cost control

What main has today:

- **No per-user cap on daily generations for own-key accounts.**
  `ProviderCallLimits` (60 an hour, 300 a day) covers the conversational calls
  only and is skipped for own-key accounts. `/generate` is 3 an hour for
  everyone, and `/regenerate` is once a day, enforced by
  `claim_regenerating!(regenerated_at: nil)`.
- **Trial (house-key) accounts** are being turned off, so every account will
  be own-key. Until then, `TrialAllowance` wraps their calls unchanged, and the
  swap adds no trial-specific path.
- **`ApiUsage` writes one row per call**, but regeneration logs as
  `generate_exercise`, so it can't be told apart today.

### One swap per daily set (D3, decided)

Today's replacement is allowed once per daily set. The user answers the set
they have, or swaps once and answers that. Choosing a kind for tomorrow
stays unlimited, because it saves a row and calls no provider.

- **Worst-case spend is 7 calls per set.** That is the judged swap's worst
  case from "Calls and time" (a design comparison rejected twice whose last
  retry is edited and re-judged); any other kind tops out at 6. A set gets at
  most one swap that lands, so a user can't run up 28 calls an hour by
  swapping repeatedly.
  - A failed swap doesn't use the allowance, so the true bound is 7 calls per
    *attempt*, with attempts one at a time. See "A failed swap" below.
- **The allowance belongs to the exercise row, as a column:
  `daily_exercises.swapped_at`** (nullable), next to `swapping_place` and
  `swapping_kind`.
  - The controller takes the claim with `claim_regenerating!(swapped_at:
    nil)`. That is one conditional `UPDATE` on the exercise row, the same
    shape as `/regenerate`'s `regenerated_at: nil`.
  - The job sets `swapped_at` in the same `with_response_locked` update that
    lands the section.
  - So the check and the write both sit on the row and the lock that already
    order the job.
  - Counting the exercise's `daily_kind_swaps` rows instead would mean
    reading a user-scoped table inside the exercise lock, and counting
    `outcome: landed`, a value the job writes later. That is a second place
    for the rule to live.
- **A held set carried forward keeps its allowance.**
  - `User#carry_forward` moves the row's date and clears `regenerated_at`
    and `regenerating_since`. It does **not** clear `swapped_at`.
  - A set that was never swapped keeps its one swap across the weekend. A
    set that was swapped on Friday stays swapped on Monday.
  - This is a deliberate difference from regeneration, which is once per
    *calendar day*, and `carry_forward` resets that on purpose
    (`pausing-generation.md`). The swap is once per *set*, and carrying a set
    forward doesn't make it a new set.
- **A failed swap does not use the allowance, matching regeneration
  exactly.**
  - `RegenerateExerciseJob` sets `regenerated_at` only in the update that
    lands the new set.
  - On an `AiService::Error` or an invalid record, `#release` frees the claim
    and leaves `regenerated_at` untouched. Its comment says "regenerated_at
    stays untouched so a failed attempt doesn't use up the day's one
    regeneration".
  - A superseded run and a run that finds the set reviewed also leave it nil.
  - The swap does the same. `swapped_at` is written only when the section
    lands. A provider error, a judge fallback, a drop, a deadline stop, a
    superseded claim or a re-check that finds the section answered or the day
    submitted all leave it nil.
  - **Whether that is right.** For a provider error it is: the user didn't
    get what they asked for and shouldn't lose the chance. There is one gap,
    and it is larger for the swap than for today's regeneration:
    - A failed single-stage regeneration costs at most 1 call.
    - A judged swap that fails because the judge rejected the draft and both
      retries can cost the full 7 calls. It can then be retried, at 7 again.
    - Attempts run one at a time, and each costs at least one draft and one
      judge, so this is bounded by how fast the user clicks, not by any rule.
    - PR 4 opens the same gap for judged regeneration (an
      `AllSectionsRejectedError` leaves `regenerated_at` nil).
  - The proposal was to keep the two rules identical, as the brief asked, and
    to add one narrow exception to both later if the logs show repeats: a run that ended
    because the judge rejected everything uses the allowance, and every other
    failure doesn't. The `[swap_section] outcome=failed reason=` log and the
    `outcome` column make that measurable before deciding.
- **The swap's allowance is separate from regeneration's.** A set can take one
  regeneration and one swap, in either order.
  - **Swap, then regenerate.** Regeneration rewrites the same row, so the
    new set inherits `swapped_at` and can't be swapped again. Regeneration
    leaves `swapped_at` alone, so the row's limit stays at one of each.
  - **Regenerate, then swap.** The regenerated set was planned from the
    current pair, and the swap is still available.
  - **What this lets through.**
    - The worst case for one set becomes one swap (7 calls) plus one
      regeneration: 1 call today, or a judged day's worst case of about 18
      after PR 4.
    - A user can change both daily places in one day: swap place 1 (it
      lands), save a new kind for place 2 (it saves for tomorrow), then
      regenerate. Regeneration plans from the saved pair, so today gets
      both new kinds. That spends the day's regeneration and throws away
      every answer, as regeneration always does, so it was left open.
    - No other case the separation lets through was found.
- **No swap-specific rate limit.** The claim already serializes swaps, and the
  per-set allowance bounds them, so `SWAP_GENERATIONS_PER_HOUR`, the hourly
  count and its copy are gone.
- **When the set's swap is used,** a later swap still saves the pair, and the
  event row records `today: "tomorrow", reason: "set_swapped"`. The reply
  says: "Saved for tomorrow. Today's set has already had its one swap." The
  card's trigger stays enabled, because choosing for tomorrow still works.
  The picker shows that line above the options before the user picks.
- **A failed call mid-swap leaves today intact,** under the judged-keep rule in
  section 3:

  | Failed call | What the code does today | Swap outcome |
  |---|---|---|
  | The draft (`swap_section`) | The error reaches the job | Not replaced |
  | The first judge | `judge_with_fallback` keeps the section unjudged, with a `fallback` reason | Not replaced: a swap lands only on a judged keep |
  | A retry (`retry_section`) | `JudgedGeneration#retry_section` returns nil and the section drops; a one-kind set raises `AllSectionsRejectedError` | Not replaced |
  | A retry's judge | Fallback as above, on a retried section | Not replaced |
  | A design comparison's edit re-judge | Reverts to the unedited draft that the first judgment kept | **Lands.** It was judged |

  In every "not replaced" case the job releases the claim and leaves
  `problem_set`, `plan_notes`, `swapped_at` and the response untouched. The
  pair is already saved, in its own transaction before the claim. The page
  shows the failure through the same wording path as regeneration
  (`what-a-person-is-told-when-a-provider-fails`), with a new
  `provider_failures.outcomes.swap`: "today's section wasn't replaced. Your
  new choice starts tomorrow, and you can still swap this set once." A
  deadline stop uses the same sentence. The calls made before the failure
  keep their usage rows.
- **The `swap_section` purpose** makes the volume measurable:
  `ApiUsage.where(purpose: "swap_section")`.


## 7. UI

**Placement.**

- **The control can't go in the card's `<summary>`.** `_section.html.erb:7`
  forbids a control inside the summary.
- **It goes in a row directly after the `kind_about` disclosure,** on the first
  `DailyKinds::COUNT` cards only, in both the answer form and the submitted
  dashboard.
- **On the submitted dashboard,** the control states that the change starts
  tomorrow before the user confirms.
- **History never shows it.**

**Markup.**

- **The trigger** is `<button type="button" aria-expanded aria-controls>`,
  labelled "Swap Code review". The pattern matches the duck thread toggle.
  `type="button"` matters because the card sits inside `#gym-form`, where a
  default button would submit the day.
- **The picker** is a `<fieldset>` with a `<legend>` ("Choose the kind for this
  daily place") and one radio per kind. Each label holds the kind's name, and
  the `SectionKindGuide` summary and example are tied to the radio with
  `aria-describedby`. The guide body is extracted from `responses/_kind_about`
  into a partial both use, so #391's text has one home.
- **The radios carry `form="daily-kind-swap"`,** pointing at an empty form
  outside `#gym-form`. Otherwise they would post with the day's answers.
  Their `change` still bubbles to `answer-form#change`, which ignores anything
  outside `[data-field]`.
- **A `daily-kind-swap` Stimulus controller** posts through `CodeGymRequest.send`.
  It first waits for the answers queue through `CodeGymSaveStatus.queue`, so
  an in-flight autosave lands before the server checks "answered". The server
  replies with its outcome. The page holds no copy of the table in section 3:
  the outcome and its sentence come from the server.

**Picker states.**

- **Options:**
  - the current kind is checked and marked "Now";
  - the other daily kind is disabled, with "Already a daily section";
  - while the other daily kind is a fourth, the two remaining fourths are
    disabled, with "Only one of Plan review, Ambiguity hunt and Pseudocode to
    code can be a daily section." The names come from `ExerciseSection.fourths`;
  - a kind already in today's set reads "In today's set. Starts tomorrow";
  - every other kind is available.
- **Consequences, shown before Confirm.** Each sentence below is rendered by
  the server into the option it applies to, tied to that radio with
  `aria-describedby` alongside the guide text, and repeated as the confirm
  sentence when that option is selected. The browser decides none of them.
  - *Choosing a fourth* (D1), naming its two siblings: "Ambiguity hunt and
    Pseudocode to code won't appear on their own while Plan review is a daily
    section. Swap one of them in to get it back."
  - *Choosing a fourth*, for the shared concept: "Your two daily sections will
    no longer look at the same idea from different sides on the same day."
    This wording is deliberate. It is the dashboard's existing
    `dashboard.shared_concept` phrasing, and it says nothing about why the
    sections share a concept, since that would expose the mastery tier
    (`shared-concept-on-a-real-struggle.md`). It is shown only for pairs
    holding a fourth. Those are the pairs where `SharedConcept` can never
    apply; other pairs may share less often, but not never.
  - *A kind with a stored weight* other than the default: "You set Challenge to
    appear more often in Exercise mix. That setting does nothing while
    Challenge is a daily section, and applies again if you swap it out." The
    sentence uses "less often" for a weight below 1.
  - *A kind the user excluded*: "You turned Challenge off in Exercise mix. As a
    daily section it will be in every set anyway. The setting applies again if
    you swap it out."
  - *The outgoing kind, at two sections.* This is the strongest consequence,
    so it is shown as a visible warning paragraph directly above Confirm,
    not only as option description text, and Confirm points at it with
    `aria-describedby`. Its wording depends on why the day has two
    sections:
    - **The Daily sections setting is fixed at 2:** "Your Daily sections
      setting is 2, so after this swap Code review won't appear at all. Swap
      it back, or raise the setting in Setup, to see it again." This is
      exact, because coverage never runs on a fixed setting.
    - **Automatic, and today's planned size is 2** (the row's
      `plan_notes["size"]`): "Your sets have two sections right now, so after
      this swap Code review will appear about once every 8 weeks, as an extra
      section. Swap it back to have it every day."
      - The figure is computed from `CoverageException::GAP_WEEKDAYS`,
        `CAP_WEEKDAYS` and the number of optional kinds the new pair leaves,
        and rounded to whole weeks. It isn't a stored number.
      - A second sentence follows: "Your two daily sections are also what
        decides when your sets grow." This is the gate-growth point above,
        stated without exposing any rating or tier.
    - **Three or more sections:** no warning. Section 6's simulation puts
      every optional kind within 11 days there.
- **Confirming** opens the picker without a pre-selection change. Confirm
  stays disabled until a different kind is picked. When today's outgoing
  section has a typed but unanswered draft, the server renders the confirm
  sentence "This replaces today's Code review section and its unsaved draft."
  into the picker.
- **Saving:** both buttons are disabled and a polite live region says
  "Saving…".
- **Replacing:** the reply says `replacing` and the page reloads. The day
  renders normally with the outgoing card replaced by the pending card from
  section 3, which polls `/dashboard/status` and reloads when the swap lands
  or fails.
- **Saved for tomorrow:** the reply says `tomorrow` with a sentence naming why
  (answered, submitted, already in today's set, busy, or this set's one swap
  already used). The picker
  closes, the sentence is announced, and focus returns to the trigger.
- **Error:** the reply comes from `render_json_error`, the message shows in the
  save-status banner, the picker stays open and focus stays on Confirm.

**Keyboard and VoiceOver.**

- Tab reaches the trigger, and Enter or Space opens the picker. Focus moves to
  the checked radio, the arrow keys move between radios (native behavior), and
  Tab reaches Confirm and Cancel.
- Escape or Cancel closes the picker, sets `aria-expanded="false"` and returns
  focus to the trigger, as `nav_menu_controller.js` does.
- VoiceOver reads the trigger's state, the legend, each option's name with its
  guide text as the description, and the disabled reasons. The outcome is
  announced through the live region.
- A system spec covers keyboard open, arrow, confirm, Escape and focus return,
  plus one VoiceOver-relevant check that the radios carry `aria-describedby`
  pointing at the guide text.

**Discoverability.** Nothing on main would tell a new account that the swap
exists. Two small additions, both static copy with no new state:

- **One line on the welcome page,** under the track buttons, after
  `welcome.note`, in a new `welcome.daily_sections` key: "Every set starts
  with two daily sections, Code review and Design comparison. You can swap
  either one for another kind from its card." The names come from
  `DailyKinds::DEFAULT`.
- **A first-time hint on the first daily card's swap row,** answer form only:
  "New: you can swap this daily section for another kind." It shows while
  the account has no `daily_kind_swaps` row and fewer than 5 submitted days.
  Both are existing reads, so nothing is stored to dismiss it. After that the
  trigger's own label carries the feature.

Snapshots: the welcome page has no page snapshot, so the line is covered by a
request spec and `spec/system/welcome_spec.rb`. The fixture account has no
swaps and at most one submitted day, so `dashboard_unsubmitted.html` gains the
hint along with the control; `dashboard_submitted.html` gains the control
only.

**Exercise mix.** "In every set" lists the user's daily kinds with their
difficulty controls only. A kind that is daily drops out of its group's
weight and exclusion rows. `code_review` and `design_comparison`, when not
daily, show as single-kind groups with difficulty only, like `pattern`. Setup
does not get a swap control; that stays on the cards.

**Snapshots that change.**

- **Page snapshots:** `dashboard_unsubmitted.html` gains the control and the
  first-time hint on the `code_review` card, and `dashboard_submitted.html`
  gains the control. The fixture day is code review,
  pattern and challenge, so only one card is daily and the fixture shows the
  default-pair markup. Add a fixture with a swapped pair to the same spec.
  `setup.html` should not change for a default account. If it does, that is a
  regression to investigate, not a rebaseline.
- **Request snapshots:** three new files, `<provider>__swap_section.json`.
- **Prompt snapshots:** every existing file stays byte-identical (written
  before #415, which rewrote all 263 to name sections by kind). New shapes
  are a one-kind swap prompt, and a full prompt for a non-default pair (for
  example `pattern` + `architecture`, and `code_review` + `plan_review` for a
  pair holding a fourth).


## 8. Events

Log swaps for analysis in a table of their own, shaped like
`level_suggestion_events`. It records what was asked, what happened to today
and, for a replacement, how it ended:

```
daily_kind_swaps
  user_id     bigint   not null, indexed
  place       integer  not null   # 0-based index into the daily list
  from_kind   string   not null
  to_kind     string   not null
  today       string   not null   # replacing | tomorrow
  reason      string             # for tomorrow: answered | submitted | in_set | no_set | busy | set_swapped
  outcome     string             # for replacing, written by the job: landed | superseded | failed
  created_at  datetime not null
```

- **One row per accepted swap,** written in the same user-row lock as the
  pair. A refused request (invalid kind, stale page) writes nothing.
- **The job writes `outcome` once, for `replacing` rows.** It receives the row's
  id as an argument and writes the outcome in the same
  `with_response_locked` transaction that lands or abandons the section.
  - `landed`: the judged section was written.
  - `superseded`: the claim token changed under the lock.
  - `failed`: a provider error, a judge fallback, a drop, a deadline stop, or
    a re-check that found the outgoing section answered or the day
    submitted.

  The job also logs `[swap_section] user= place= outcome= reason=` with the
  cause of a failure. `outcome` stays null on `tomorrow` rows, and on a
  `replacing` row whose job never finished.
- **Why a second write is acceptable here.** `level_suggestion_events` writes
  each row once because its outcome is known at the moment of the click. A
  swap's outcome is decided minutes later, after paid calls, so the table
  either takes a second write or can't count successful replacements. The
  second write is narrow:
  - one column, null to a value, once;
  - made by the one job that owns the claim, inside the lock that already
    orders it against every other writer of that exercise;
  - read by no app behaviour at all. The per-set allowance lives on
    `daily_exercises.swapped_at`, not in this table.

  A lost write (a worker killed after the call) leaves null. Null reads as
  "unknown", never as "landed", so counts of successful replacements can't be
  inflated. `ApiUsage` can't stand in for it, because its rows carry no link
  to a swap.
- **Validations** follow `LevelSuggestionEvent`: kinds in `ExerciseSection.keys`
  and enums with an `inclusion` check.


## Open decisions

- **D1. Decided: (a), at most one fourth among the daily kinds.** `DailyPlan`
  runs a separate one-concept track for exactly one fourth kind
  (`fourth_track`, `FOURTH_SLOT_CAPACITY`). While a fourth is daily, the
  optional `fourth` group sits out, and coverage can't add a sibling either
  (section 2). Its two siblings then appear only by swapping, and the pair
  never shares a concept. The picker states both before Confirm (section 7).
  Two daily thirds are fine.
- **D2. Decided: a swap generates even while generation is paused.**
  Pausing stops generation the user didn't ask for, and a swap is asked for.
  A carried-forward row is treated like any other row dated today.
- **D3. Decided: one swap per daily set,** like regeneration's once a day.
  The allowance lives on `daily_exercises.swapped_at`, is set only when a swap
  lands (as `regenerated_at` is), survives a carry-forward, and is separate
  from regeneration's. The worst case is 7 calls per landed swap, and failed
  attempts can repeat (section 4). There is no hourly limit.
- **D4. Decided: the judge always runs.** A swapped section goes through
  judged generation exactly as a first generation does, with the same retry
  budget (section 3). Regeneration moves to judged generation too, as its own
  PR after the swap work (PR 4 below).


## PR split

0. **Schema only.** Add `users.daily_section_kinds` (`jsonb`, default `[]`),
   `daily_exercises.swapping_place`, `swapping_kind` and `swapped_at`
   (nullable), and
   `daily_kind_swaps` with its nullable `outcome`. Nothing reads any of them. It ships a release ahead,
   because the worker's pre-deploy waits for a schema, not for pending
   migrations (`tracks.md`). It should not share a release with the
   `learning_track` drop.
1. **Per-user layout, no visible change.** Covers `DailyKinds`, the layout,
   `plan_notes["daily_kinds"]`, row-aware `resolved_keys` and every reader in
   section 2, `judge_retries` moving to the plan, text from the pair,
   Setup's groups and the validations. `CompetencyGate` is left for PR 1b; it
   reads `DailyKinds::DEFAULT` where it read `ExerciseSection.fixed`, which is
   the same pair. A default account stays byte-identical,
   and the existing prompt, page and request snapshots prove it. Specs set a
   non-default pair directly on the user. Docs and rules updates:
   - `generation.md` and `design-comparison-the-second-fixed-section.md`;
   - `planning.md`, `competency-gate.md`, `coverage-exception.md` and
     `shared-concept-on-a-real-struggle.md`;
   - `level-suggestions.md:37-42`;
   - `request-flow.md:37`, `patterns.md:55` and `file-map.md`;
   - a new `docs/decisions/daily-kinds.md`, with its entry in `planning.md`.

   **1b. Per-day pairs in `CompetencyGate`.** `Day` carries the row's
   `plan_notes["daily_kinds"]`, entries are tagged daily or not, the growth
   window reads tagged entries, and `Evidence#optional_state` uses the row's
   pair (section 5). Nothing can swap at this point, so every stored day holds
   the default pair, and the interim state between PR 1 and PR 1b is the
   behaviour main has today. The PR carries the before-and-after check:
   `CompetencyGate.plans` over production-shaped fixtures must give identical
   counts, reasons and evidence before and after, for accounts with and
   without a growth or a brake in their history. It also carries a spec with
   a hand-built history whose pair changes partway, showing that a swap
   neither reclassifies earlier days nor resets an earned size. It updates
   `competency-gate.md`.
2. **The swap, server side.** Covers `PATCH /daily_kinds/:place`
   (`DailyKindsController#update`), the `DailyKindSwap` outcome object, the
   event row, the `swap_section` purpose, profile, routing and snapshots,
   `AiService#generate_swapped_section` sharing `retry_section`'s one-kind
   half, `SwapSectionJob` with `SWAP_DEADLINE` and the deadline-checking
   provider factory, the `outcome` write, the per-set allowance
   (`swapped_at`), the failure wording, `REGENERATION_STALE_AFTER` re-derived
   to 1,006 s (section 3), and the swap-claim columns read by `#show`,
   `#status` and the answer saves. Request specs cover one example per
   outcome.
3. **The card control.** Covers the partial, the `daily-kind-swap`
   controller, the extracted guide partial, the picker's consequence
   sentences, the pending card, the welcome line and first-time hint, the page
   snapshots and the system specs.

4. **Judged regeneration, after the swap work and separate from it.**
   `RegenerateExerciseJob` calls `generate_judged_exercise` in place of
   `generate_unjudged_exercise`. Everything else about regeneration stays:
   once a day, refused once reviewed, the response destroyed, and a new
   `generated_at`. `AllSectionsRejectedError` is an `AiService::Error`, so the
   job's existing rescue keeps today's set and records the failure with no new
   branch. Weekend "generate anyway" sets stay single-stage; that is a
   separate question.
   - **How much longer it takes.** Today's regeneration is one draft call.
     Judging adds a fan-out of judges and up to two retry cycles, run in
     parallel across sections, so the day waits on the slowest section, not on
     their sum. From `two-stage-generation.md`'s estimates, one retry cycle
     adds about 55-155 s over the draft and a daily kind's second cycle about
     20-50 s more, so a regeneration takes up to about 3.5 minutes longer. By
     the code's own worst-case formula, it goes from 946 s (one draft) to
     `JUDGED_GENERATION_BUDGET`, 2,302 s.
   - **Whether the generating page fits.** The poller sizes its attempts from
     `[JUDGED_GENERATION_BUDGET, REGENERATION_STALE_AFTER].max / 3 + 1`, which
     already allows for the judged budget, so it needs no change. Regeneration
     keeps its full-page generating state, which suits a rewrite of the whole
     day.
   - **The window question lands here.** PR 2's 17-minute window covers a
     single-stage regeneration. A judged regeneration's worst case is
     `JUDGED_GENERATION_BUDGET`, 2,302 s (about 38 minutes), and a window that
     long would let a crashed worker block swaps and regeneration for 38
     minutes.
   - **Recommendation: regeneration gets a deadline too,** with the same
     fit-before-each-call rule and the same deadline-checking provider factory
     PR 2 builds:
     - `REGENERATION_DEADLINE = worst_case_call_seconds(GENERATION_READ_TIMEOUT)
       + worst_case_call_seconds(READ_TIMEOUT) + JOB_PICKUP_MARGIN` = 946 +
       181 + 60 = 1,187 s, about 20 minutes, measured from the claim. That is
       the worst case of its first judged pass, the same derivation as the
       swap's, plus pickup, because the 300-second draft is too long to let a
       slow pickup eat into it.
     - `REGENERATION_STALE_AFTER` becomes `[REGENERATION_DEADLINE,
       SWAP_DEADLINE].max`, 1,187 s.
     - A regeneration that reaches its deadline drops only the sections whose
       retries no longer fit, as any failed retry does, and lands the sections
       already kept. It doesn't keep the old set, as a swap keeps its outgoing
       section, because throwing away a judged day over one late retry costs
       the user more than one dropped section. If nothing was kept,
       `AllSectionsRejectedError` keeps today's set through the existing
       rescue.
   - **Updates** `two-stage-generation.md` and `generation.md` ("Weekend sets
     and `RegenerateExerciseJob` stay single-stage"), and the
     `regenerate_exercise_job` code note.

PR 2 and PR 3 could merge into one. Keeping them apart lets the server rules
be reviewed without markup in the diff. PR 1b can go in any time after PR 1
and must merge before PR 2. PR 4 depends on PR 2's deadline machinery.


## Risks

- **Stored days must resolve with their own pair.** A miss in any reader
  that still uses the global layout would silently drop a section from a
  stored day with two thirds. PR 1 adds a spec that greps `app/` for
  `ExerciseSection.slots`/`.fixed` outside the layout's own file, in the style
  of `trial_isolation_spec`.
- **Gate behavior on old data.** Tagging entries per day must give exactly
  today's sizes for every account that never swapped. PR 1b checks it with
  `CompetencyGate.plans` over production-shaped fixtures, before and after.
- **A swapped-out kind nearly disappears on two-section days.** The simulation
  in section 6 puts it at about once every 6-8 weeks. The picker says so, but
  the product may want a different answer, which would mean changing coverage
  for everyone.
- **Swap concepts may repeat.** A swapped section's concept may repeat one of
  today's other sections, since the fresh plan doesn't know them.
- **Spend.** A landed swap costs at most 7 calls, once per set. Failed
  attempts don't use the allowance, so a set whose swaps keep failing on
  judge rejections can be retried at up to 7 calls each, one at a time. The
  same is true of judged regeneration after PR 4. The `swap_section` purpose
  and the `outcome` column make repeats visible, and nothing alerts on them.
- **The two-section trap.** A pair holding a kind the user keeps finding hard
  holds an Automatic account at two sections (section 6). The exits exist, but
  the automatic one needs level suggestions switched on.
- **A longer claim window.** A worker that crashes mid-call now holds the claim
  for about 17 minutes instead of 6 (20 after PR 4). In that time neither a
  swap nor a regeneration can start. A crashed swap shows its pending card,
  and a crashed regeneration shows the full-page generating state and then
  the slow hint.
- **A deadline turns slow-provider swaps into "starts tomorrow".** It is
  intended, but it can surprise a user. The copy says the replacement still
  counted.
- **Stricter landing than first generation.** A judge fallback keeps today's
  outgoing section instead of shipping an unjudged one. A provider outage
  therefore turns every swap into "starts tomorrow", which is the intent.
- **Race with autosave.** The page flushes the answers queue before posting,
  and the job re-checks "answered" under the lock. A section answered mid-call
  keeps the user's work and wastes the swap's calls. The pending card hides
  the outgoing section, so this needs a page that was stale before the
  swap.
- **Comment budget.** `exercise_section.rb` (279 lines) and `daily_plan.rb`
  are near their limits. The layout may need its own class
  (`ExerciseSection::Layout`) to stay under 300 lines and 5 comments.


## Verification plan

- Each PR runs the unit suite
  (`bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`), and PR 1 runs
  it in full, since it touches shared authorities (`ExerciseSection`,
  `DailyPlan`, `ProblemSetIngest`).
- `spec/system` runs once before each PR opens; PR 3 adds the keyboard and
  focus specs.
- `bundle exec rubocop` and `bin/comment-check`.
- Prompt, page and request snapshots: PR 1 must pass with **no** snapshot
  update (written before #415, which rewrote every prompt snapshot). PR 2 and PR 3 update only the files named in section 7, and each
  diff is read before committing.
- Isolation specs: `level_suggestion_isolation_spec`, `trial_isolation_spec`
  and `section_kind_guide_spec` (the swap job must not read
  `SectionKindGuide`).
- Lock and claim specs for `SwapSectionJob`: superseded by a regeneration,
  answered mid-call, submitted mid-call, stale claim and provider failure.
- `JudgedGeneration` outcomes for a one-kind draft: a keep lands, a fallback on
  the first judgment doesn't land, a drop doesn't land, and an edited design
  comparison whose re-judge fails lands unedited. A spec derives
  `SWAP_WORST_CASE_CALLS` (7) from `judge_retries` and `rejudge_edits?`, so the
  number in this spec can't silently go stale.
- Specs assert that `REGENERATION_STALE_AFTER` is at least `SWAP_DEADLINE`,
  and at least the single-stage regeneration worst case plus pickup. PR 4
  changes the second to `REGENERATION_DEADLINE`.
- Deadline specs drive the provider factory with a fake clock: a call whose
  worst case doesn't fit is never made, the claim is released, today is
  untouched and `outcome` is `failed`. A typical-speed run with both retry
  cycles finishes inside the deadline.
- Pending-card specs (request and system): a swap claim renders the day with
  one pending card, a save for the outgoing key is refused, and other cards
  still autosave. A regeneration claim still renders the full-page state.
- Submit during a swap, in both lock orders: submit first leaves the outgoing
  section in the submitted day and the job records `failed`; the swap first
  leaves the incoming section unanswered in it. Neither loses an answer.
- Allowance specs: a landed swap sets `swapped_at` and a second swap saves for
  tomorrow with `reason: set_swapped`. Every failure path leaves it nil, as
  `regenerated_at` stays nil on the same paths (one shared example group
  run against both jobs). `carry_forward` keeps it, and regeneration neither
  clears it nor is blocked by it.
- A pure `CompetencyGate.plans` spec for the two-section trap (section 6).
- A rotation simulation spec ports the section 6 run onto the real
  `SectionRotation` with fixed seeds. It asserts the 11-day bound at sizes 3
  and 4 for every reachable pair, and that a daily fourth's siblings never
  appear. If a change breaks the bound, that is a decision to make, not a
  constant to raise.
- The `critical-reviewer` agent runs on each PR before it leaves draft, with
  this design as its input.
- After PR 2 deploys, `ApiUsage.where(purpose: "swap_section")` grouped by
  `failure` is the first week's check.


## Scope option: a tomorrow-only swap

This section is for the scope decision: what changes if a swap only saves the
pair and never touches today's set. Every swap then takes the "tomorrow"
path.

**What stays the same.** PR 0's `users.daily_section_kinds`, all of PR 1 (the
per-user layout, per-day pairs in `plan_notes`, row-aware `resolved_keys`),
all of PR 1b (the gate), the picker and its consequence copy, the
discoverability line and hint, the Exercise mix changes, and every finding in
sections 5 and 6. Those are needed by any swap, because the pair still
changes and still steers planning, rotation and growth.

**What goes away.**

| Area | Removed |
|---|---|
| Schema (PR 0) | `daily_exercises.swapping_place`, `swapping_kind`, `swapped_at`; `daily_kind_swaps.today` and `outcome`. The event row is written once |
| Generation | `SwapSectionJob`; `AiService#generate_swapped_section` and the one-kind draft method it shares with `retry_section`; the judged-keep landing rule and its asymmetry with first generation |
| Provider plumbing | The `swap_section` purpose, its `CALL_PROFILES` entry and routing entries, three request snapshots and the one-kind prompt snapshot |
| Time limits | `SWAP_DEADLINE`, `AiService::DeadlineError` and the deadline-checking provider factory. `REGENERATION_STALE_AFTER` no longer depends on the swap. Main's existing 946 s gap is still a bug, and it is still worth a small PR of its own |
| Concurrency | Sharing the `regenerating` claim between two purposes (a documented pattern deviation), the race with autosave and submit, and the `busy` reason |
| Allowance | The per-set allowance and its interaction with carry-forward and regeneration (section 4 shrinks to a paragraph) |
| Page (PR 3) | The pending card, the `swapping` state in `#status`, the refused save for the outgoing key, the outgoing-draft confirm sentence, the failure copy. Section 3's state table collapses to one sentence: the pair applies to the next set |
| Specs | The deadline, pending-card, submit-order, allowance and judged-outcome groups in the verification plan |

**Size.** PR 2 goes from the largest PR in the plan to a controller, its
outcome object, the validation and the event row. PR 3 loses its only async
state. The parts removed are also the ones that took the most review here:
the claim, the deadline, the stale window and the landing rule.

**Spend.** Zero provider calls per swap. The only paid path left is
regeneration, which keeps its own once-a-day rule.

**What the user gives up.**

- **Seeing the new kind today.** It appears in the next set: tomorrow on a
  weekday, after the weekend otherwise. A held set carried forward still
  holds the old pair, because it was planned before the swap.
- **The workaround is regeneration.** It plans from the saved pair, so
  "swap, then generate a new set" gives today a set with the new kind. It
  costs every answer typed so far and the day's one regeneration, and it is
  one call today (judged after PR 4). The picker can offer it in one line
  when regeneration is available and nothing is submitted: "Want it today?
  Generate a new set (this replaces today's answers)." It is the existing
  button.
- **Skipping still works.** A user who doesn't want today's daily section
  can leave it unanswered, since `submit_blocker` only needs one answered
  section.

**Moving to in-place later is additive.** The columns, job, deadline, card
and allowance described above can land on top of the tomorrow-only build,
with no change to PR 0-1b and no migration of the pair. The event rows from
the tomorrow-only build would measure the demand first: how often a swap is
followed by a regeneration on the same set.

**Decided 2026-10-16: build tomorrow-only first.** It carries every
part of the feature that changes what the user practises, at no spend and
with the riskiest code left out. The regeneration path covers "today" for
people who really want it, and the events show whether in-place is worth
its cost.

## The two-section gate analysis

This was first written here as part of the swap. Its final form is
`2026-10-16-two-section-gate-hold-note.md`.

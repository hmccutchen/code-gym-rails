# `bug_hunt`, a fourth `code_review` mode

`bug_hunt` is a short puzzle: one line saying what the code is meant to do
(the goal), then 5 to 10 lines of core Ruby or core JavaScript holding one
planted language trap. The engineer answers what's wrong, why, and how to
fix it. On some days the input the goal suggests first gives the right
result by accident, such as deleting from an array while iterating over it
when the values to delete never sit next to each other.

## A mode of `code_review`, not a kind

It sits beside `application_code`, `test_file` and `schema_review`
(`docs/decisions/code-review-content-modes.md`), so it is a shape of a kind
the engineer already knows, not a second kind that looks like the first.
Rotation, the swap sheet and Setup's Exercise mix are untouched. That
follows the owner's multi-file decision of 2026-10-29
(`docs/decisions/multi-file-code-review.md`). The cost is that no per-user
setting turns it off or weights it (owner's decision).

## What the owner decided (2026-11-02)

- **Weekends only (owner's decision, 2026-11-05).** Every weekend set's
  `code_review` is a `bug_hunt` (`WEEKEND_CODE_REVIEW_MODE_WEIGHTS`), and a
  weekday never rolls one (`CODE_REVIEW_MODE_WEIGHTS = { application_code:
  0.30, test_file: 0.29, schema_review: 0.41 }`, the earlier weekday split
  with `bug_hunt`'s 0.20 spread in proportion). A bug hunt is short and
  light, which suits a weekend. It replaced a 0.20 share of every judged day
  (2026-11-02), which was about one weekday set in five.
  - The owner found the old share hard to see: a bug hunt is a mode of
    `code_review`, so nothing in Setup names it or says how often it comes.
    A fixed day makes it predictable.
  - Weekdays now hold more `schema_review` (41% of `code_review` sections,
    up from 33%), so data-modeling retention gains host days. Weekends hold
    none, and on a `bug_hunt` day `code_review` hosts nothing (below).
- **Weekends are judged, so a bug hunt still never ships unjudged.** Weekend
  generation and regeneration used to be single-stage. They now take the
  judged path like a weekday (`docs/decisions/two-stage-generation.md`),
  since an unjudged `bug_hunt` would ship with nothing to reject code that
  is correct as written, a second trap, or code outside the core language.
  The cost is the judged path's provider calls and longer wait on a weekend
  set, which is generated only when the user asks for one. A trial account
  pays for it from the house key, under the same `/generate` request limits.
  - **Button-only (owner's decision, 2026-11-05).** Nothing generates a set
    on a weekend by itself: the morning job runs Monday to Friday, and the
    weekend dashboard only offers "Generate anyway". So most users will
    rarely see a bug hunt. Auto-generating weekend sets, or keeping a small
    weekday share, were offered and not taken.
  - **The day is read once.** `GenerateDailyExercisesJob#generate_for` takes
    the date before the judged run and stamps the row with it, so a run
    started late on Sunday writes Sunday's set, not a bug hunt dated Monday.
  - **How it is wired:** a model may not name `AiService`, so `DailyPlan.for`
    takes `judged:` from the path that called it and reads the day itself
    (`Date.current.on_weekend?`). An unjudged plan, which only
    `#generate_unjudged_exercise` and its script callers make now, rolls the
    weekday weights on any day.
- **Single-file.** A `bug_hunt` day never rolls multi-file and is never
  grounded in a `RealSource` excerpt.
- **Core Ruby and core JavaScript only.** No Rails, TypeScript, framework,
  DOM or Node API. JavaScript snippets are ES modules: strict mode, with
  `export` allowed.
- **No program output on the page.** Ingest refuses a result comment
  (`# =>`, `// =>`, `// ->`), and the prompt and the judge carry the rest
  of the rule.
- **The concept stays hidden until the day is submitted.**
  - Before submission, no section on the page shows the trap's concept:
    no concept reference, closed or open, and no featured marker.
    `DailyExercise#concepts_withheld_before_submission` lists it, from the
    kind's `concept_shown_before_submission?`, and the section partial
    checks every section's concept against that list.
  - The weekly featured-concept callout is left off the dashboard that day
    when it features the trap's concept (`featured_callout_shown?`). The
    Learn tab leaves its featured block off too
    (`featured_shown_beside_todays_set?`), reading today's set or a paused
    user's held one, so the missing callout can't be read against Learn
    (#680; it applies to every kind that hides its concept). Before the
    day's set exists, Learn still shows the featured block, since nothing
    says yet which concept a section will hide. That window is accepted:
    the set is generated at 8am or on the first dashboard visit, so it is
    short, and a featured concept seen then says nothing about a set that
    doesn't exist yet. Generation also keeps the week's featured concept
    out of the trap pick and out of the other hiding kinds (#687,
    `docs/decisions/the-weekly-featured-concept.md`), so these guards now
    cover only the rarer cases listed there.
  - Every other kind's vocabulary leaves out the picked trap's concept
    (`ConceptVocabulary.selectable_for_section(..., gotcha:)`), so the
    prompt never offers it to another section. `DayHosts` reads the same
    vocabularies, so no reinforcement entry, drill, retention check or
    coverage check on that concept is planned onto another section. It
    waits as `no_host`. The page check above also covers a provider that
    tags it anyway.
  - No shared concept is picked on a `bug_hunt` day, since `code_review`
    isn't a planning host.
  - The owner chose this over accepting the hint (2026-11-02).
- **`principal_engineer` is pitched exactly as `senior`.** A 10-line puzzle
  has no room for a decision at system scale.

- **Deploys:** Railway starts the web and worker services together, so a
  set generated by the new worker during a deploy's few minutes can be shown
  by the old web, with the concept visible and no goal line. The owner
  accepted that window rather than ship the weight in a second release
  (2026-11-02). Avoid deploying near 8am.

## The registry

`BugHuntGotchas` is a closed list per language, 11 Ruby and 12 JavaScript
entries, each tagged with a concept from its language's vocabulary.
- **The pick:** `DailyPlan` picks one never-seen-first, then the one seen
  longest ago, the same shape as `RealSource.pick`. The picked id is
  recorded in `plan_notes["bug_hunt"]`, outside the section. The trap is
  picked on every `bug_hunt` roll, so the planner and the prompt always see
  the same one, but it's recorded only when the day's plan includes a
  `code_review` section, even if the judge or ingest later drops it. An
  entry counts as seen only on a day that delivered its section
  (`BugHuntGotchas.last_seen_for`), so a dropped section doesn't use it up.
- **Order:** entries are appended, never inserted, since list order is the
  drain order.
- **Formatting:** every entry avoids traps a formatter rewrites, such as
  automatic semicolon insertion or `&&`/`||` precedence that Prettier wraps
  in parentheses.
- **Concepts:** existing concepts come first. The one addition is Ruby
  `array_mutation_pitfalls`, for the four Ruby mutation traps. The ladder
  size spec still passes with it, without raising
  `MAX_LADDER_GUIDANCE_CHARS`.

## The section

- **`purpose`:** one line of at most 160 characters. Ingest refuses a
  missing or multi-line purpose (`purpose_missing`) or a longer one
  (`purpose_too_long`), and deletes a `purpose` sent on any other mode. So
  the field marks a `bug_hunt` section, and `CodeReview.bug_hunt?` reads it.
- **`snippet`:** at most 10 shown lines after formatting
  (`BugHunt::MAX_LINES`, refused as `bug_hunt_too_long`). The prompt asks
  for lines under 45 characters where possible, never past 60, for the
  phone. That is guidance only.
- **The page:** the goal line as plain text, labelled "Goal:", and the
  snippet with numbered lines. The grader, the duck and the difficulty
  assessment see the same numbering (`CodeReview.snippet_context`), never
  the concept or the key.
- **The key:**
  - `issue`, `why_it_matters` and `fix`, as on every `code_review`.
  - An optional `witness` (`call`, `expected`, `returns`), written as code.
  - `looks_right_on`, asked for from `mid_level` up.
  - `fixed_snippet`.
  - **For an async trap,** the witness returns a snapshot of the state at
    the moment the call returns, never a live reference. A copy made in a
    `.then` comes after pending callbacks may have run.
  - **The quote check** reads only `issue`.

## Mastery: an exposure, not mastery evidence

A `bug_hunt` section tests one language rule in 10 lines. For a broad
concept such as `memoization` or `error_handling`, that is one facet, so
one puzzle shouldn't set the concept's tier or clear its retention
schedule.

- **What skips it:** `ConceptMastery.record_review!`,
  `User#concepts_needing_reinforcement` and `RungLedger` skip a section
  whose kind answers `mastery_evidence?` false. That includes deferring a
  skipped retention check: skipping a puzzle never defers one, and an
  answered puzzle doesn't stop a skipped section elsewhere from deferring
  its check.
- **Planning:** `code_review` is not a planning host on a `bug_hunt` day
  (`planning_host?`, read by `DayHosts`, with main-track capacity counting
  planning hosts only). So no reinforcement entry, retention check,
  coverage check or shared concept is planned onto a section that can't
  move it. Both hooks read one rule (`mastery_evidence_mode?`).
- **What still counts:** the section is an exposure, and it is still
  `code_review` evidence at its rung for the competency gate and level
  suggestions.
- **The cost:** on every weekend set, `code_review` carries no
  reinforcement or retention check. On a two-section day most code
  concepts then wait a day.

## Grading

- **The grading note works without the key,** since the grader doesn't
  read stored keys yet.
  - **Main point:** an input the goal covers that the code gets wrong, and
    why. An answer that says the code works, or traces only a looks-right
    input, misses it.
  - **A different trap** meets the main point only if it also breaks an
    input the goal covers.
- **When the grader reads keys** (PR 2), its keyed `code_review` note gains
  a fourth harm clause: in `bug_hunt` mode the harm is a wrong result, or
  an error, for an input the goal covers. An input outside the goal, a
  style point or a faster way is lesser.
- **The samples:** `bug_hunt` sections stay out of PR 2's single-file
  samples and calibration, and out of the #648 real-day quote test, filtered
  by `code_review_mode=bug_hunt` (`docs/decisions/stored-answer-keys.md`).

## The judge

- **Its task and guidance:** a `bug_hunt` section gets its own
  (`judge_task_for`, `judge_guidance_for`). The judge solves it first.
- **What it rejects:**
  - as `reasoning_failure`: correct code, a second trap, shown output, or a
    goal that gives the trap away
  - as `unstated_prerequisite`: non-core code
  - as `underdetermined`: an undefined call
- **What it may not touch:** `purpose` is not in `.prose_fields`.
- **When it can't answer:** a `bug_hunt` section is dropped, never shipped
  unjudged (`ships_unjudged?`, read by `JudgedGeneration` on the first pass
  and on a retry's re-judge). Every other kind keeps its draft. The judge is
  the only check that the code is wrong as written, which is why an
  unjudged plan never rolls the mode. The cost: on a judge outage the day loses its
  `code_review` section, and nothing replaces it (owner's decision,
  2026-11-02).

## The measurement (2026-11-02)

Before turning the mode on, the owner had drafts measured by running them
(`docs/code-notes/script/bug_hunt_measure.md`).

- **Drafting:** 66 calls and $2.88 under a $4 cap.
- **What it found:** the first Ruby run lost 16 of 22 attempts to purposes
  of 161 to 213 characters, because the prompt hadn't stated the limit. The
  prompt now states it.
- **The result:** all 23 drafts, one per registry entry, passed every check
  across 115 harnesses run with no network. In every draft the bug was
  real, the key stated the wrong result correctly, the looks-right input
  held, the fix worked, and the code was core-only.
- **What follows:** no sandbox is needed, and no entry was cut.
- **Line width:** 7 JavaScript drafts had a line past 45 characters, 1 past
  60. That is guidance only.

After the measurement, the Ruby runner changed so a snippet's top-level
names can't reach its comparison. The owner decided that needs no
re-measure (2026-11-02): only a snippet defining `wanted` or `finish` at the
top level could have been affected, and all 23 drafts passed.

A re-measure is needed when the `bug_hunt` prompt, an entry's rule, ingest's
`bug_hunt` checks, the judge's `bug_hunt` text, the drafting or judging
routes, `CodeFormat`, or the harness changes. `--entries` drafts only
changed entries. A change to one of these that leaves the drafts, their
formatted code and every check's verdict on them unchanged needs no
re-measure, and its PR shows why: for example, how `CodeFormat` joins its
reader threads (#655). A harness, ingest or judge change that could flip a
pass or a fail still needs one (owner's decision, 2026-11-02).

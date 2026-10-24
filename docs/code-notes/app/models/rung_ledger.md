# app/models/rung_ledger.rb

## Why `.for` reads every submitted day

The newest eligible verdict for each concept, bucket and rung wins, and a
later poor attempt releases a rung an earlier one held. `#held` picks the
highest rung still held and `#developing_toward` looks at every rung attempted
above it, so seeing a concept once says nothing about its other rungs.
Stopping early or capping history would change what `/progress` shows.
Walking oldest first gives the same answer only if a later verdict overwrites
an earlier one. A cached result stays correct only if its key changes with
every input. That includes a rule change or a SQL data fix, neither of which
moves `updated_at`. No cache is built (#518).

The memo below lowers the cost per submitted day, but `.for` still grows
linearly with account age: about 14ms at 100 days, 65ms at 500 and 125ms at
1000 on the harness below. Whether to remove that growth is still undecided
in #518.

## What it loads

Each response loads only `RESPONSE_COLUMNS`. Each exercise loads whole through
`.preload(:daily_exercise)`, since `DailyResponse#answered_concept_tags`,
`DailyExercise#active_section_keys` and `ConceptBucket.for` read its
`problem_set`, `plan_notes` and `language`.

Two narrower loads were measured for #518 and left out:

- A SQL projection of `problem_set` down to the fields the ledger and the
  answer rules read. Each kind's answer rule reads fields of its own
  (`answer_scaffold`, Parsons' `blocks`), so the projection would restate those
  rules in a second place. It also saved almost nothing: Postgres decompresses
  the whole jsonb value to read any key of it, and the projection measured
  17.9ms against 18.5ms for the whole column at 500 days.
- Selecting only `id language plan_notes problem_set` from the exercise. It
  saved about 4ms and 6,000 allocations at 500 days, but needs
  `ActiveRecord::Associations::Preloader`, which Rails marks internal, and a
  second list of the columns `DailyExercise` reads. Leaving `id` out of that
  list empties the ledger without an error.

## Where the time went

Measured for #518 with a throwaway spec: 500 submitted weekdays, each
exercise holding `FakeService::EXERCISE_PROBLEM_SET` (all ten kinds, about
4.9KB stored each) with random concepts, rungs and some eased sections, and
full reviews on each response. It counted real queries apart from query-cache
hits, record instantiations and allocated objects, and timed the median of 25
runs on local Postgres while other test runs shared the machine.

Most of the Ruby time was `ExerciseSection.key` rebuilding the kind's name
with `underscore` on every call, about ten times per `ExerciseSection.find`,
and `find` runs for every section of every day's answer check. The key is now
built once per kind and frozen.

| at 500 days | before | after |
| --- | --- | --- |
| real queries (cache hits) | 2 (0) | 2 (0) |
| records instantiated | 500 responses, 500 exercises | the same |
| allocated objects | 283,167 | 208,166 |
| Ruby time (median wall less median SQL) | 49-55ms | 36ms |
| median wall time | 81-98ms | 63-75ms |

The allocation counts repeat exactly from run to run. The wall times moved
with the load from other test runs, so they are the range across four runs
of each build. Every concept's held rung and `developing_toward` matched
between the two.

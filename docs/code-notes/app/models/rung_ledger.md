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

The two changes below lower the cost per submitted day, but `.for` still
reads every submitted response and its exercise, so its time still grows
linearly with account age: about 60ms at 500 days and 100ms at 1000 on the
harness below. #518 stays open on that point.

## What it loads

Each response loads only `RESPONSE_COLUMNS`, through
`DailyResponse.with_ai_ratings_only`. That scope swaps `ai_review` for a copy
holding only each section's `rating`, the one field of the review the fold
reads, through `ai_rating_for`. Postgres still reads the whole stored review,
but the review prose is no longer sent, parsed or kept in memory. A review,
or a section of one, that is not a JSON object is passed through as stored,
so a malformed row fails the same way it did with the whole column. The rows
are read-only, so the trimmed review can never be saved over the stored one.

Each exercise loads whole through
`.preload(:daily_exercise)`, since `DailyResponse#answered_concept_tags`,
`DailyExercise#active_section_keys` and `ConceptBucket.for` read its
`problem_set`, `plan_notes` and `language`.

Three narrower loads were measured for #518 and left out:

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
- Loading each verdict key's newest candidate rows in rounds. When every
  newer candidate for a key is unanswered or inactive, it reads every row
  anyway, one round per day: 60 such days took 120 queries.

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

### The ratings-only review

Measured with the same harness, at four synthetic review sizes and one built
from the repository's `spec/fixtures/review_judge` examples. Each build ran
twice, alternating, at 15 runs each, with a load average of 3.4-4.5 from
other work. Every build gave the same ledger as one built from fully loaded
responses. "Before" has the key memo, so the difference is the projection's
alone. Each cell gives allocated objects, then median wall time.

| review per day | 500 days, before | 500 days, after | 1000 days, before | 1000 days, after |
| --- | --- | --- | --- | --- |
| 0.15KB, rating only | 146,380, 60ms | 144,306, 59-63ms | 290,262, 101ms | 286,272, 101ms |
| 1.5KB, fixture examples | 158,671, 60-63ms | 144,306, 60-61ms | 314,614, 102-103ms | 286,273, 101-111ms |
| 2.9KB | 175,300, 64ms | 144,306, 60-63ms | 347,562, 108ms | 286,272, 101-103ms |
| 13KB | 181,086, 64ms | 144,306, 61ms | 359,022, 126-129ms | 286,272, 99ms |
| 30KB | 238,926, 95-98ms | 144,306, 58-60ms | 473,622, 189ms | 286,272, 103-107ms |

After the change, allocations no longer depend on review size, and wall
time falls most where reviews are largest. Both builds still make two
queries and instantiate every response and exercise.

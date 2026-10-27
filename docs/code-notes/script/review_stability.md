# script/review_stability.rb

`ReviewStability` prints how much a grade moves when the same answer is
graded several times. `ModelComparison#review_stability` does the grading and
hands it the rows; `script/regrade_review_baseline.rb` is the entry point. The
input is the file `script/export_review_baseline.rb` wrote
(`docs/code-notes/script/review_baseline_export.md`).

## How it grades

Each exported section is graded `--runs` times (5 by default) through
`ModelComparison#grade_result`, the same `ReviewGrading.grade_section` call
`#review` and `#review_calibration` make: the production prompt, the
provider's production `review_response` route, Parsons' fixed rating and
`RubricCheck`. The pinned service turns the prose judge off, since it never
changes a rating, and writes no `ApiUsage` rows. The run happens inside
`ReviewBaselineExport.read_only`.

A section's runs are made back to back, so the day's context, which is the
system prompt, is written to the provider's cache once and read on the
calls after it.

`--provider` picks `claude`, `openai` or `gemini` from
`ModelComparison::JUDGE_SHAPE_PROVIDERS` and bills that provider's own
environment key. Only Claude is priced; the others print token counts.

## Stopping

A grade that fails with `bad_key`, `out_of_credit`, `daily_limit` or `setup`
stops the run, since every later call would fail the same way. The report
then covers the sections finished, and a last line says where it stopped and
why. Any other failure is counted on its section and the run goes on.

## The plan

Without `--run` it makes no provider call. It prints the sections by kind,
which provider reviewed them, the call count, and two costs. The estimate
counts characters at about four a token, assumes 900 output tokens a call
(the mean of the 2026-10-09 calibration run, thinking included) and caches
each day's context after its first call. The worst case drops the cache and
puts every call at the output cap, which no grade has come near, so it is a
bound, not a forecast.

## What it prints

One line per section: date, kind, rung, the stored rating and each run's
rating (`-` for a failed call). Then one line per kind and one for all kinds:

- **changed between runs**: sections whose runs did not all give the same
  rating, out of those with at least two ratings.
- **spread**: how many sections had 0, 1, 2 or 3 levels between their lowest
  and highest rating.
- **moved more than one level**: sections with a spread of 2 or more.
- **failed calls**, and how many sections had too few ratings to compare.

The counts carry no percentages. With a dozen sections a kind, a percentage
claims a precision the sample doesn't have.

## Drift is reported apart from stability

Below the stability lines, a block headed "drift, not stability" compares
the regrades with the rating stored when the review was written. Stability
is how much one grader disagrees with itself today. Drift also moves with
every model and prompt change since the stored review, so a low match there
says nothing about how stable today's grader is.

Drift is split by the stored review's provider (`review_provider`). When that
differs from the provider the regrade runs on, the line says so, since it then
compares providers too. When it was never recorded, the line says the
provider may differ. A section with no stored rating is left out of the
denominator and counted on a line of its own.

It never prints an answer, a key, or any review text, so the output can be
pasted anywhere.

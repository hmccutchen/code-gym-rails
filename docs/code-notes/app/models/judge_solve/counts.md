# app/models/judge_solve/counts.rb

`JudgeSolve::Counts` builds the header of `/admin/judge_solves`. The counting
rules come from the spec's "Decision rule" section
(`docs/answer-key-trust-spec-2026-10-22.md`). This note covers why the code
reads the way it does.

## Every count reads `JudgeSolve.readable`

A hidden row's outcome is the answer to a design comparison someone hasn't
reviewed yet. If the "mismatched" count went up by one the morning a set was
generated, an admin who is also an engineer would learn that today's section
was a mismatch before answering it. So the outcome, revert and call counts
all start from `JudgeSolve.readable`, and a hidden row moves none of them.

The one number about hidden rows is `#withheld`, the number of hidden
sections (`JudgeSolve.withheld_section_count`, one per exercise, section and
set) with no source, outcome or rung. It counts sections rather than rows
because an edited section has two hidden rows, so a row count would reveal
the edit. It keeps the
denominator honest: you can see that rows exist which the tables leave out,
without learning anything about them. `#withheld` takes no arguments, so
nothing can ask it for a breakdown, and `counts_spec` holds that.

## Call tables count section versions, not records

The decision rule's unit is a distinct section version. A live solve and its
replay share a `section_digest`, and they count once. `#latest_call_per_version`
does this in SQL with `DISTINCT ON (section_digest)`, ordered so that a row
with a call beats one without (`human_call IS NULL` sorts false first), then
the latest `human_called_at` wins. Ties fall to the highest id, so the result
is stable. Preferring a call first means clearing the call on one row of a
version never hides the call on its twin. `human_called_at` moves only when
the call changes (see `docs/code-notes/app/models/judge_solve.md`), so
editing a note never reorders the pick either.

The winning row's `source` is the source the version counts under. A version
judged live and replayed therefore appears in one column only, and live plus
replay add up without counting it twice. A version can still appear in both
the mismatch and the matched table, when its live judge and its replay judge
disagreed. The tables are kept apart on purpose, as the spec asks.

Unsolved rows drop out because the tables filter on `matched` being true or
false. Rows at `JudgeVerdict::SOLVE_MISMATCH_TOLERATED_AT` drop out
because that rung already accepts disagreement; the constant is the one
authority for which rung that is.

## No bound or branch

The page shows counts only. You apply the decision rule's thresholds by hand,
so nothing here computes a Wilson bound or names a branch.

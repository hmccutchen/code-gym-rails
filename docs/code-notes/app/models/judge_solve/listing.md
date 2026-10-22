# app/models/judge_solve/listing.rb

`JudgeSolve::Listing` turns the `/admin/judge_solves` query parameters into
the rows the page shows. The controller only builds it; the views only read
it.

## Two lists: readable entries and waiting placeholders

`#entries` reads `JudgeSolve.readable` and is the only source of row content
on the page. The `show` and `call` filters and the order apply to it alone.

`#waiting` lists withheld sections as "waiting for the engineer's review".
It groups `JudgeSolve.withheld` rows by `JudgeSolve::WITHHELD_SECTION`
(exercise, section and set) and by source, and plucks only the source, the
earliest row's rung and the earliest creation time into a `Placeholder`. No
piece, key or pick is ever read into memory for a hidden row.

It shows one placeholder per section, not per row. A section the judge
edited has two hidden rows, the pre-edit draft and the edit check, so a
placeholder per row would show that the judge asked for an edit. Grouped
this way, an edited section and an unedited one look the same.

The placeholders are filtered by source and nothing else. If the
`show=mismatches` filter applied to hidden rows, a placeholder showing up
under it would say that today's section was a mismatch. They're ordered by
time only, for the same reason: ordering reverted edits first would reveal a
revert. The list is left off for `matched_sample`, which draws readable rows
only, and for a `call` filter naming a call, since a hidden row has none.

## Bounds

Entries come `PAGE_SIZE` to a page, offset-paged like `/history`, with the
`page` parameter carried through the filters and the redirect after a save.
A filter link drops it, so changing a filter starts again at page 1. An
out-of-range page reads as the last page. The placeholders stop at
`WAITING_LIMIT`, and the page says how many more are waiting.

The entry view needs only the exercise's language for highlighting, so
`#language_for` plucks `id` and `language` for the page's exercises in one
query rather than loading whole exercise rows, whose `problem_set` is large.

## What `show=mismatches` holds

The default view is mismatches and reverted edits together, ordered reverted
edits first, then mismatches, newest first. A revert for `judge_rejected` or
`judge_failed` may have matched or be unsolved, and it still belongs in the
default view, because the page lists reverted edits first. `show=reverts`
narrows to the reverts; `show=all` adds matched and unsolved rows.

## `matched_sample`

`ORDER BY random() LIMIT n` over readable, matched, uncalled rows below
principal engineer, from the source filter minus synthetic. A reload can
draw differently, and a called row leaves the pool. `n` defaults to 15 and
is clamped to 1..50, so a typo can't ask for the whole table. The pool is
uncalled rows, so a `call` filter naming a call draws nothing, and
`call=uncalled` draws the usual sample. The sample is never paged.

## Companions: the shipped original and the replay link

`#original_for` finds a reverted edit's shipped original: the row of the
same exercise, section, set and attempt with `edit_check: false`.
`#counterparts_for` finds rows of the same exercise, section and
`section_digest` with a different source, which links a live row to its
replay and back. Both read through `JudgeSolve.readable`, so a companion
that is still hidden never appears; the original sits beside the edit only
when both are readable. Each is one query for the whole page.

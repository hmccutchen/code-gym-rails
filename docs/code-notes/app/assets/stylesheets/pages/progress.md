# pages/progress.css

Progress's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on Progress only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

## At 900px and wider

- The open legend is four across, so its 7 entries make a row of 4 and a row
  of 3.
- A grouped bucket's `.progress-groups` is a two-column grid, so its groups
  sit two across. `.progress-buckets` is one too, and a bucket with more than
  one group (`.progress-bucket-grouped`) spans both columns. A single-group
  bucket's `.progress-groups` stays a flex column, since it already sits in
  one column of the outer grid and a second grid would halve its card again.
  The single-group buckets then sit two to a row instead of each stretching
  across 1040px.
- `align-items: start` keeps a group at its own height when the one beside
  it opens.
- Both grids use `minmax(0, 1fr)`, for the same reason as History's entries
  column.
- The note is held to `65ch`, the same reading width as History's review.
- Each desktop rule keeps the `.progress-page` prefix it had in
  `desktop.css`. The block comes last in the file, so it would win its ties
  without it.
- The single-group buckets pair up because each language's slice has four
  of them today. With an odd number, the last one would sit alone in its
  row.

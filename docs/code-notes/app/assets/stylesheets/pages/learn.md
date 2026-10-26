# pages/learn.css

the Learn index's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on the Learn index only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

Only the index's rules live here. The concept and lesson pages' rules, and
`.learn-worked-example`, which a recognition guide and a concept page's worked
example share, stay in the layout. `.learn-empty` left the layout's shared
muted-colour rule for a rule of its own here.

## At 900px and wider

- `.learn-top` is a two-column grid: this week's concept beside the filter.
  Without a featured concept the filter is the only child and spans the row.
- A grouped bucket's `.learn-groups` is a three-column grid, so its groups sit
  three across. `.learn-buckets` is one too, and a grouped bucket
  (`.learn-bucket-grouped`) spans it. The single-group buckets, one per
  `ConceptBucket::LANGUAGE_INDEPENDENT` entry and four of them today, each
  keep their own heading and sit in rows of three and one, so the fourth
  sits alone beside two empty cells. A single-group bucket's `.learn-groups` stays
  a flex column, as on Progress, so its card isn't split twice.
- `align-items: start` keeps a card at its own height when a recognition guide
  opens beside it.
- The prepare and drills boxes stay full width, with their sentences held to
  `65ch`.
- No rule here sets `display` on `.learn-bucket`, `.learn-group-block` or
  `.learn-entry`, the elements the filter hides; the grids sit on their
  wrappers, and `page_stylesheets_spec` holds that (`docs/code-notes/app/views/learn/index.html.md`).
- A selector list is written out in full, not inside `:is()`:
  `page_stylesheets_spec` reads selectors with `ViewStyles`, which splits a
  rule's selectors at every comma.

# pages/history.css

History's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on History only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

## At 900px and wider

- `.history-page` is a grid: a 240px rail, a 24px gap, then the entries. The
  entries column is `minmax(0, 1fr)`, not `1fr`. A grid track defaults to
  its content's minimum width, so a long path in a review or a wide code
  block would otherwise widen the column and scroll the page sideways.
- `.history-rail` is sticky 24px from the top. It holds three short lines,
  about 200px at the largest text, which is under the shortest window that
  reaches this layout (430px, an iPhone Pro Max in landscape). So it needs no
  minimum-height guard.
- The rail's "Page X of Y" shows only here. On a phone the pager already says
  it.
- An entry's padding is 20px here and 16px on a phone.
- The open review is held to `65ch`, a comfortable reading width. Answers and
  code keep the entry's full width.
- `.history-page .history-rail-page` once needed its two classes to beat the
  view's `<style>`. The rule now sits after the phone rule in the same file,
  and keeps the selector it had.

# pages/account.css

Account's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on Account only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

The page's own rules come first, then those of the partials in the order they
render: `accounts/_push_reminders`, `accounts/_authenticator` and
`accounts/_api_usage`. Each partial renders on Account only.

## At 900px and wider

- The page takes the 1040px column (`wide_page`) and becomes a two-column
  grid. `max-width: none` undoes `.phone-page`'s 480px cap, which has the same
  weight and loads earlier.
- The title and the identity card (`.account-id-card`, a class rather than a
  position, so a card added above it can't take its place) span the row.
- The other cards pair up in page order, and stretch, so each pair shares a
  height. Without push reminders the Reminders card is absent, the pairs
  reflow, and the Danger zone sits alone at half width.
- Below 900px nothing changes: a centered 480px column from 600px.

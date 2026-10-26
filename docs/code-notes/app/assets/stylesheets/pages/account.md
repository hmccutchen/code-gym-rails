# pages/account.css

Account's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on Account only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

The page's own rules come first, then those of the partials in the order they
render: `accounts/_push_reminders`, `accounts/_authenticator` and
`accounts/_api_usage`. Each partial renders on Account only.

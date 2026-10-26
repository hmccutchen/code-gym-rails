# pages/settings.css

Settings's styles: its phone rules, then its desktop rules in one
`@media (min-width: 900px)` block at the end, so a desktop rule wins every tie
with the page's phone rules. The layout links it on Settings only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`).

The rules' order and the ties it settles are in
`docs/code-notes/app/views/api_keys/edit.html.md` ("Partials' styles"). Each
partial renders on Settings only.

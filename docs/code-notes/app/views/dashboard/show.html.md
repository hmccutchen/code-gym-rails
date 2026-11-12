# app/views/dashboard/show.html.erb

## Styles

The page's styles live in `pages/today.css`
(`docs/code-notes/app/assets/stylesheets/pages/today.md`), including the
sticky progress bar's fixed height.

## Featured concept callout

The callout sits below the day's set, not above it. The set is what this page
is for, and a second call to action above it would compete. On the short
states (weekend, paused, generating, failed) there is nothing to scroll past,
so the callout lands in view on the days it has the most to offer.

It sits outside `#dashboard-content` because the generating state's poller
replaces that div and would take the callout with it.

## Automatic-pause line

`dashboard/_automatic_pause` renders above `#dashboard-content` while
`User#generation_paused_automatically?` holds. It is outside the `case` on
`@content_state` because it shows in every state, a weekend and a day with a
set included, and `MissingSetState` names one state at a time. Its two
controls are `button_to` forms with no Stimulus controller, so they work
with scripts off. `docs/decisions/pausing-generation.md` has the rule.

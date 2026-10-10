# app/views/dashboard/show.html.erb

## Sticky progress bar height

The sticky progress bar has a fixed height, `--progress-sticky-height`, so the
page can keep a focused field clear of it. A browser that scrolls a field to
the top edge stops at `scroll-padding-top`, which reads the same variable. The
focus ring's width and offset are added because the ring sits outside the
field.

## Featured concept callout

The callout sits below the day's set, not above it. The set is what this page
is for, and a second call to action above it would compete. On the short
states (weekend, paused, generating, failed) there is nothing to scroll past,
so the callout lands in view on the days it has the most to offer.

It sits outside `#dashboard-content` because the generating state's poller
replaces that div and would take the callout with it.

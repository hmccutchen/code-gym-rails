# app/views/learn/index.html.erb

## Layout

The page is a `.card-page` (`phone_cards.css`) and calls `wide_page`. On a
phone every box and group is a card `max(16px, inset)` from the screen edge,
16px apart. From 600 to 899px they take the container's full width. At 900px
and wider the page's own sheet puts this week's concept beside the filter
and the groups three across. Every rule lives in `pages/learn.css`
(`docs/code-notes/app/assets/stylesheets/pages/learn.md`), linked by
`page_stylesheet "learn"`; the ones that would also reach Today's featured
card carry the `.learn-page` prefix.

The order is this week's concept and the filter (`.learn-top`), the prepare
box, the drills box, then the buckets. The filter sits beside this week's
concept on a desktop, so it comes right after it in the page too, and the
visual order and the tab order agree.

`data-controller="learn-filter"` sits on the page wrapper, since its targets
are now the filter in the top row and the buckets below the boxes.

## The filter's `[hidden]`

The filter hides entries, group blocks and buckets with the `hidden`
attribute, and any author `display` rule beats the browser's own `[hidden]`
rule. Two rules restore it here: the page sheet's `.learn-entry[hidden]` and
`phone_cards.css`'s `:is(.phone-page, .card-page) [hidden]`, both at 0,2,0.
The phone rules on those three classes stay at 0,1,0, under both.
The page sheet loads after `phone_cards.css`, so a desktop rule at 0,2,0 that
set `display` on one of them would win the tie and stop the filter on a
desktop only. The grids therefore sit on `.learn-buckets` and `.learn-groups`,
which the filter never hides, and `page_stylesheets_spec` fails on a
desktop rule that sets `display` on a selector whose last part names one of
those three classes, `.learn-bucket-grouped` included.

## Featured concept

The featured concept renders above the filter and the list, so opening this tab
and reading one thing takes no decision. The filter shares its row on a
desktop.

## Prepare prompt

The prompt quotes the counts and says whose key pays, because the backfill
spends the user's own provider key and the rows it writes are shared with the
whole team.

## Prepare form script

`#prepare` derives what to enqueue from the rows that exist, so pressing the
button twice before the first jobs finish would enqueue jobs still in flight a
second time. Disabling the button on submit covers the realistic double-click
without adding a persisted in-flight marker, for a case the job's own re-check
already makes mostly harmless.

## Group headings

A bucket whose concepts all fall in one group renders flat. That covers every
language-independent bucket, where a heading over the only group would be
noise. A group drill sits with the heading, so a bucket with no headings
offers none; its core group is the whole bucket. A bucket with more than one
group carries `.learn-bucket-grouped`, which the desktop grid reads.

## Not-generated markers

Row existence and guide existence are different facts, so each gets its own
marker rather than one combined marker. A row can exist from before guides
were written, and the bulk button's count, which is driven by row existence,
would never offer to clear it.

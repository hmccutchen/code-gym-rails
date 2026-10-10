# app/views/learn/index.html.erb

## Featured concept

The featured concept renders above the filter and the list, so opening this tab
and reading one thing takes no decision.

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
offers none; its core group is the whole bucket.

## Not-generated markers

Row existence and guide existence are different facts, so each gets its own
marker rather than one combined marker. A row can exist from before guides
were written, and the bulk button's count, which is driven by row existence,
would never offer to clear it.

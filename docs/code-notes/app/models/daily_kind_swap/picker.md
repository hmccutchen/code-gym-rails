# app/models/daily_kind_swap/picker.rb

What one daily card's swap control shows: the current kind, one option per
kind with its state, note and consequences, the "next set" line, the
first-time hint, and the version a save must post.

## Cards are matched by membership

`.for_day` keys pickers by the card's kind, taken from the day's recorded pair
(`DailyExercise#daily_kinds`) and filtered by `active_section_keys`. Matching
by position would move a control onto a rotating card when the judge drops a
daily section, so a dropped daily section simply has no control. The place's
kind is then read from the user's current pair, since a swap made after the
set was planned changes the next set and not this one.

## The card's kind and the stored kind

A swap changes the next set, so after one the card on screen (the row's
recorded kind) and the place's stored kind differ. The trigger's label names
the card ("Swap Code Review for another kind"), and a line under the title
row says what the next set uses there (`next_kind_line`, shown unless
`card_shows_current?`).

## Badges

`marks_for(kind, refusal)` gives each option its badges, in order:

- the place's stored kind gets "Now" when the card shows it, and "In your
  next set" when a swap has already changed this place;
- the card's own kind gets "In today's set" when it is not the stored kind;
- the other daily kind gets "Already daily", from its `already_daily`
  refusal.

An option can carry two badges: after swaps that move the card's kind to the
other place, that kind is both in today's set here and already daily there.
Section 7 of the spec lists both badges, and #421 showed both facts, so
neither is dropped. `accent_mark?` is true only for the "Now" badge, the one
the view draws in the accent colour.

## Every state comes from `DailyKindSwap`

An option's state is `DailyKindSwap#refusal` for that kind with no version:
`unchanged` is "Now", any other reason disables it, and no reason makes it
available. The note, which the sheet shows in place of the kind's short
line, is the refusal's own sentence. `already_daily` has no note, because
its badge already says it. So the picker restates no pair rule; a new
refusal reason shows up here with its message and no code change.

## A refusal of the current kind closes the picker

When asking about the place's own kind is refused for anything but
`unchanged`, the refusal is about the account rather than a choice. Today
that is `trial_ended`. The picker then offers no options, shows the reason in
place of the "next set" line, and drops the hint, since the hint invites a
swap the account can't make.

## The hint

It shows on the first delivered daily card only, while the set is
unsubmitted, the account has no swap events, and fewer than
`HINT_UNTIL_SUBMITTED_DAYS` days are submitted. All three are reads the page
already makes possible, so nothing is stored to dismiss it.

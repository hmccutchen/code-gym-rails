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

## Every state comes from `DailyKindSwap`

An option's state is `DailyKindSwap#refusal` for that kind with no version:
`unchanged` is "Now", any other reason disables it, and no reason makes it
available. The note is the refusal's own sentence, except `already_daily`,
which reads shorter on a list of options. So the picker restates no pair
rule; a new refusal reason shows up here with its message and no code change.

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

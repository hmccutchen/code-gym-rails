# Coverage exception

at two sections a day has no optional slot, so
`SectionRotation`'s starvation guarantee has nothing to act on.
`CoverageException` (pure) adds one optional section when the setting is
Automatic, the day's count leaves no optional slot (`count <=
DailyKinds::COUNT`), the struggle brake is
off (`DaySize::Decision#brake?`, true while the gate's reason is `:brake`,
even on a day completion alone would also have held at two), and no exercise dated on the previous `CAP_WEEKDAYS` (4)
weekdays carries `plan_notes["coverage"]`. It picks (a) the kind able to
host the most overdue waiting check at or past
`ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER`, or else (b) the
optional kind unseen for more than `GAP_WEEKDAYS` (20) weekdays, longest
gap first, never seen before seen, ties in registry order. The
candidates are the kinds in the pair's optional slots
(`ExerciseSection.optional_slots(daily:)`), so a default kind the user
swapped out can be added, while a daily fourth's siblings never can,
because the pair's layout has no fourth slot. Both respect
the user's exclusions, and (a) reads hosting through `DayHosts`. The added
kind fills its own slot (`ExerciseSection.slot_for(kind, daily:)`) without weights, and
`DailyPlan` decides the concept tracks again so the check can land in it.
Reinforcement can still outrank that check for the one retention slot
(`Addition#check` names the check, and `DailyPlan.check_landed?` reads the
recomputed tracks for it); then the addition is given up and the day stays
at two, rather than spending the cap on a section carrying something else.

**The cap counts calendar weekdays, not delivered rows.** Weekends never
count toward the four, a weekend addition inside the window still blocks,
and a paused stretch counts as the weekdays it spans. Because the note is
written at plan time, an addition whose section the judge dropped still
counts. The checks run cheapest first: the setting and count cost
nothing, then `History.recent_coverage_dates` reads the planned additions
over the cap's window alone, and only a day the cap leaves open runs
`History.for`, which reads each optional kind's last delivered date
(`active_section_keys`) and the oldest date from one query over the last
`HISTORY_LIMIT` (120) exercises before today. A
kind never delivered counts as unseen from the oldest exercise read, so a
new account gains nothing from the gap rule. Today's row is left out, so a
regeneration plans as the first generation did. Generation logs
`[coverage] user=… kind=… reason=gap|due_check`, and the diagnostics
payload carries `coverage` and `shared_concept` beside the rest of
`requested`.

**What the dashboard says.** Two muted lines in the style of
`dashboard.section_left_out`, on the unsubmitted dashboard. While the
added kind is still in `active_section_keys`, `DailyExercise#coverage_shown`
returns the stored `plan_notes["coverage_reason"]` and the line follows it:
`dashboard.coverage_added.gap` ("a kind you haven't seen in a while") for a
gap, and `dashboard.coverage_added.due_check` ("so an idea you learned
earlier can come back up") for a due check, whose host may have been seen
last week, so the gap wording would be false for it.
`dashboard.shared_concept` shows only when both delivered daily sections carry
the planned concept (`#shared_concept_shown?`), so a dropped section or an
ignored placement never produces a false claim. The shared line gives no
reason: "because it has been giving you trouble" would expose the mastery
tier, which stays invisible. It names the day's daily sections from their
locale names (`sections.<key>.name`, listed from the row's
`DailyExercise#daily_kinds`) and says "from different sides", so neither
line nor prompt assumes which or how many daily kinds there are.

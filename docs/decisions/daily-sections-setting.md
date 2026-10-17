# Daily sections setting

`User#daily_section_count` is Automatic (nil)
or a fixed count in `User::DAILY_SECTION_COUNTS`, which runs from
`SectionCount::FLOOR` to `ExerciseSection::MAX_SECTIONS`. Setup shows it as a
radio group that autosaves through `PATCH /profile`. A fixed count is an
override of the count only: `DaySize.for` returns it before completion or
the gate is consulted, so no change to either can reach a user who chose
one. Automatic takes the lower of the completion rule and the competency
gate. `SectionRotation` still picks which optional kinds fill the day
either way, since that is not sizing, and the gate still runs under a fixed
count so the `[set_size]` line can log its evidence. Weights, exclusions, difficulty targets and locks are unaffected, and
the setting is not part of the Exercise mix, so it does not bump
`section_kind_preferences_version`.

The lowest choice holds only the user's daily kinds, and Setup's hint names
them; a spec holds `SectionCount::FLOOR` equal to `DailyKinds::COUNT` for that
sentence. A
fixed count is what the day is planned with, and the judge can still drop
an optional section from it.

**The boundary accepts only listed values.** `ProfileController` takes
`User::AUTOMATIC_SECTION_COUNT` (`"automatic"`, stored as nil, and the value
Setup's radio posts) or a listed count, as an Integer or its exact string.
Anything else is a 422 that saves nothing, because Active Record's integer
cast would turn `""` or `null` into nil, which means Automatic, `"abc"`
into 0 and `"2.5"` into 2, and a JSON `2.0` equals 2. The model checks the
same range only when the value changes, like the other validations that
read moving constants, and `DaySize.for` clamps a stored count to the
current range on read, so a row saved under a wider range plans a day the
set can actually hold.

**It replaced the `adaptive_set_size` boolean, and every account reads
Automatic.** `AddDailySectionCountToUsers` adds the column with no default
and no backfill, so an account that had turned adaptive sizing off, which
meant a fixed full day, now gets Automatic sizing until it picks a count.
That change was deliberate. The column was ignored for one release, while
the old code kept serving through the pre-deploy migration, and
`RemoveAdaptiveSetSizeFromUsers` dropped it afterwards.

**A fixed count never gains a coverage section.** The coverage exception
(`coverage-exception.md`) applies only to Automatic, so under a fixed 2 a check that only an
optional kind can host waits, and the `[retention] waiting=` line says so.
A fixed choice wins by design.

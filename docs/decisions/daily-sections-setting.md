# Daily sections setting

`User#daily_section_count` is Automatic (nil)
or a fixed count in `User::DAILY_SECTION_COUNTS`, which runs from
`DailyKinds::FEWEST` (1) to `ExerciseSection::MAX_SECTIONS`. Setup shows it as a
radio group that autosaves through `PATCH /profile`. A fixed count is an
override of the count only: `DaySize.for` returns it before completion or
the gate is consulted, so no change to either can reach a user who chose
one. Automatic takes the lower of the completion rule and the competency
gate. `SectionRotation` still picks which optional kinds fill the day
either way, since that is not sizing, and the gate still runs under a fixed
count so the `[set_size]` line can log its evidence. Weights, exclusions, difficulty targets and locks are unaffected, and
the setting is not part of the Exercise mix, so it does not bump
`section_kind_preferences_version`.

A fixed count also decides how many of the user's daily places a set holds
(`DailyKinds.for`), so the count and the kinds are chosen together:

- **1** holds one daily section. Setup asks which of the pair to keep and
  stores it first, so the stored pair keeps both kinds and a later count of 2
  brings the other one back.
- **2** holds the pair, as before.
- **3 or 4** holds the pair plus one or two extra sections the user chooses.
  Setup asks for a kind per extra place before it saves, preselecting the
  stored extras (`DailySectionsChoice`). A chosen extra is in every set and
  no rotation runs for its place, so the Exercise mix lists it under "In
  every set". A fixed count with no extras stored, such as one saved before
  this choice existed, still rotates the places it has no kind for.

Automatic holds the pair whatever is stored, so its floors stay at the
pair's size (`daily_kinds_floor_spec`); only a fixed setting goes down to
one. Setup's hint names the pair and says what 1, 2 and a larger number
hold. A fixed count is what the day is planned with, and the judge can
still drop a section from it.

**The count and its kinds save in one request.** The chooser posts
`daily_section_count`, `daily_section_kinds` (the whole place list) and the
`layout` the page was rendered for. `ProfileUpdate` refuses a list
`DailyKinds.problems_with` refuses, in words a person can act on, and a
`layout` another tab has moved gets the same 409 the Exercise mix gets. The
reply names the daily kinds the saved setting holds; when they differ from
the rendered layout, the page reloads once every other save on it has
landed (`daily_sections_controller`), since the Exercise mix below is drawn
for the old kinds. Counts that need no choice (Automatic and 2) save on the
tap, as before.

**The boundary accepts only listed values.** `ProfileUpdate` takes
`User::AUTOMATIC_SECTION_COUNT` (`"automatic"`, stored as nil, and the value
Setup's radio posts) or a whole number, as an Integer or a string of digits,
and `User` refuses a number outside the range. Any other shape is a 422 that
saves nothing, because Active Record's integer cast would turn `""` or
`null` into nil, which means Automatic, `"abc"` into 0 and `"2.5"` into 2,
and a JSON `2.0` equals 2. The model checks the range only when the value
changes, like the other validations that read moving constants, so a save
that posts back a count stored under a wider range is accepted.
`DaySize.for` clamps a stored count to the current range on read, so such a
row still plans a day the set can actually hold.

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

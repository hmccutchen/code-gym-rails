The projection counts weekdays because `GenerateDailyExercisesJob#generate_if_due` and the dashboard both skip weekends. Weekdays approximate when spending happens; they don't limit it. The "Generate anyway" button, a follow-up question (`ResponsesController#follow_ups`) and "explain differently" (`ConceptReferencesController#explain_differently`) can all call the provider on a weekend. Most spend follows the generation schedule, so spend per weekday is the rate worth extending across the month.

The projection stays hidden until the 4th because a rate from one or two days is noise. It also needs no divide-by-zero check: a weekend is two days, so days 1 to 3 of any month always include a weekday, and by the 4th the count of elapsed weekdays is at least one. The spec asserts this for all twelve months of 2026, which start on all seven weekdays.

Spend on a weekend lands in the numerator but adds no weekday to the denominator, so it makes the projection read slightly high. Rows written before #472 carry no cost, so October 2026's total misses that early spend and its projection reads low.

The projection is hidden while generation is paused, because the daily rhythm it extends has stopped. It is also hidden when any provider has no priced rows, because the total would leave that provider's spend out and the projection would read low with nothing to say so.

Today counts as a full weekday in the divisor, so a projection read on a weekday morning reads low. This was chosen over reading high later in the day.

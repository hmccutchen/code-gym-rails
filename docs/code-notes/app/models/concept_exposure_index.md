# `ConceptExposureIndex`

`ConceptExposureIndex.for(user)` reads every submitted response's
`concept_tags` with its day's date and language in one query, and keys each
date by `[concept, bucket]`, the bucket coming from `ConceptBucket.for`.
`DailyResponse#improved_code_visible?` relies on that key format, so a
section's revised code shows once the reader's own bucket has two exposures.
A skipped section of a submitted day still counts, since it was shown;
unsubmitted days, blank tags and `"other"` never count.

`User#concept_exposures` holds one index per user instance; its note says
why the memo lives there.

## Why each key holds a `Set`

Several sections tagging the same concept on one day count as one exposure,
which matches `ConceptMastery`.

Each key holds a `Set` of dates rather than an array built with
`array |= [date]`. The union form rescans the whole array for every concept
tag, so the cost grew with the square of the account's age — the same concept
is re-tagged for reinforcement, drills and retention checks, so one key really
does collect a date per submitted day. On 500 submitted days the build
measured 47ms, of which 33ms was that rescan; the `Set` form measured 4.6ms.
The dashboard, `/history` and `/learn` all pay it, through `#first_exposure?`
and the featured concept's "seen N times" line. The `Set` is also what keeps
the one-exposure-a-day rule above true, so a plain array with `<<` would break
the dedup that `spec/models/concept_exposure_index_spec.rb` pins.

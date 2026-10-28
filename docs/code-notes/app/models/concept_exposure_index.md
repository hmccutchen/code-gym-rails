# `ConceptExposureIndex`

`ConceptExposureIndex.for(user)` reads every submitted response's
`concept_tags` with its day's date and language in one query, and keys each
date by `[concept, bucket]` from `.key_for`, which is the one place that
says which tags count (`.counted?`) and which bucket a section records
under. `#count_for` answers a section's count through the same key, and
`ReviewShortVersion#key` is that key, so `DailyResponse#improved_code_visible?`
and the short version can't drift from the index: a section's revised code
shows once its own bucket has two exposures. `#count_for` is nil for a tag
that doesn't count, and each caller decides what that means.
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

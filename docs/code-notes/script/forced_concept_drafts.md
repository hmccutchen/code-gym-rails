# script/forced_concept_drafts.rb

## `.todays_plan`

The plan every measurement script drafts from (`KeySampleDrafts`, and
`ModelComparison`'s concept drafts). It plans in the user's zone, as the
generation jobs do, and as a weekday (`weekend: false`), so a run on a
Saturday or Sunday measures the same kind of set as a weekday run and never
gets a bug-hunt plan, which would also leave the trap's concept out of every
other kind (#704). It carries this week's stored featured concept, read
without `FeaturedConcept.for`, so a run writes no featured row.

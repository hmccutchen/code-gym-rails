# ReviewShortVersion

The rules for offering a concept's short version in a review, from
`docs/first-exposure-teaching-spec-2026-10-27.md`.

## Why `== 1` and not `.zero?`

The review renders after submit, so the submitted day already counts as an
exposure. A count of 1 means no earlier submitted day carried the concept.
`ConceptReferencesHelper#first_exposure?` runs before submit, on a day the
index doesn't hold yet, so it tests `.zero?`. Both read
`ConceptExposureIndex`, which owns the key rule.

## Why the reference row isn't checked here

Sections that share a concept share its `ConceptReference` row, so a missing
row can't change which section offers the short version. The partial renders
nothing when the row is missing, and the model stays free of database reads.

## Why the index is passed in

The exposure count is the only fact the rules need beyond the response. The
review partial passes `User#concept_exposures`, which is built once per
user, and the specs pass a hand-built index, so they need no database.

## What it never reads

`ConceptMastery`, its tier, drills or reinforcement state. The offer reads
the exposure count and the section's own rating and review, which the review
already shows, so it can't imply a tier. A convention spec scans this file
and the partial for `ConceptMastery`.

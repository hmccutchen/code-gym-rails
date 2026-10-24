# `app/helpers/concept_references_helper.rb`

## `#concept_reference_for`

The memo is a plain hash on the view instance, so it lives exactly as long as
one render and cannot carry a row between requests or between users. The only
writer of a `ConceptReference` is `GenerateConceptReferenceJob`, which every
caller enqueues rather than runs, so no request can cache a `nil` and then
create the row it would have found.

It reads through `fetch` with a block rather than `||=` because a concept with
no reference yet is the common case on a page, and `||=` would re-query every
one of those on every section.

Active Record's query cache already held the repeated reads inside a request,
so this does not remove database round trips: a page issued one real query
either way. What it removes is the repeated cache lookup and, more to the
point, the `ConceptReference` object rebuilt for every one of them — a page of
history went from 30 instantiations to 1. The row carries the `guide_*`,
`ladder_*` and `lesson` columns, so rebuilding it is not cheap.

Loading every reference for a language in one query would also collapse the
reads, but it would move far more bytes than the page displays, for the same
reason.

The lookup is keyed on the concept and the language together. The helper spec
covers that directly, because one concept can hold a reference in one language
and none in the other, and a key that dropped the language would return the
wrong one.

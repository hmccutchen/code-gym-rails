# Book citations

`ConceptBookSources` maps a concept to an ARRAY of
reading pointers — title, author, and where the book has one, the term the
book itself coined — rendered as "Where this comes from" at the bottom of a
`LearnController#show` page and nowhere else. Static and hand-curated, like
`Glossary`: **it is never sent to a provider, and that is the whole design.**
A generated citation is a hallucinated one, and a `ConceptReference` row is
cached forever, so the guarantee has to be that no prompt can reach the data
rather than that a prompt is asked to behave — a spec pins that no source
title appears in the concept-reference prompt. `CONCEPT_REFERENCE_FIELDS` and
`CONCEPT_GUIDE_FIELDS` are deliberately untouched by it, since widening
either would silently change `#explain_concept_differently`'s prompt and the
required-field check. Array-valued from the first commit rather than promoted
later: `shotgun_surgery` carries two sources on day one. A citation is
additive metadata — adding one never changes a concept's definition or its
grading criteria. The rule nothing mechanical can enforce: a pointer names a
term the book coined, never a chapter or page number, because a number
recalled rather than checked is a fabrication that reads as authoritative.

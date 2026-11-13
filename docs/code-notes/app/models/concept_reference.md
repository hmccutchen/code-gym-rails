# `ConceptReference`

## `MAX_LADDER_RUNG_LENGTH`

Many rungs share one generation prompt, so this is tighter than AiService's
`MAX_CONCEPT_GUIDE_LENGTH`.

## `#usable_lesson` and `#lesson?`

The `lesson` column is read back through `ConceptLesson.from_provider`, the same check that holds a new lesson at the boundary, and `#lesson?` is true only when that leaves a part to show (#558). Four production rows once stored the string `"None"`, which the old `lesson.present?` counted as a lesson: Learn showed an empty lesson box, hid the explanation, guide and pitfalls, and offered no "Write the short lesson". A number or a list there made the page raise. The page now renders `#usable_lesson`, so a stored value it can't show reads as no lesson, and the button's rewrite replaces it. The read applies today's `ConceptLesson` limits, so tightening `MAX_TEXT_LENGTH`, `MAX_SITUATIONS` or `MAX_HABITS` hides the parts of stored lessons past the new limit, and can turn `#lesson?` false so Learn offers the lesson button again, a billed call when clicked.

The migration `ClearNonHashConceptLessons` cleared every non-object lesson once, on the owner's choice to remove the bad values from the data as well. It doesn't touch an object whose parts are all unusable, which `#lesson?` already treats as no lesson.

## `.for`, `.seen_by` and `.visible_to`

The one answer to which reference a user sees: their own row, else the
shared row (no `user_id`), never another user's. `.seen_by` indexes the rows
by `[concept, language]` with the user's own row winning. The shared half
is a fallback until L5 of `docs/decisions/learn-content-per-user.md` drops
it.

## `.missing_for`

The pairs a user sees no reference for, own or shared. Learn's prepare
button and `GenerateConceptReferenceJob.queue_missing` both ask it, so the
two never disagree on what is still missing.

## `.written_up?` and `.written_up_keys`

The admin suggested-concepts page is the one reader that counts any user's
row, a teammate's included. It asks only whether a concept has ever been
written up, to decide whether a suggestion can be promoted, and shows no
text. A reference for a concept outside the vocabulary exists only once
someone's set was tagged with it.

## `WRITTEN_FIELDS`

Every column one `#generate_concept_reference` call fills: the reference,
guide and ladder fields and the lesson. The job writes all of them together
so a row's parts always come from one response. `#fully_written?` does not
read this list: it asks for the guide, the ladder and a lesson
`#usable_lesson` can show, and checks no reference field.

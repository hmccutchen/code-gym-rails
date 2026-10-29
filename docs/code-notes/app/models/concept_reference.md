# `ConceptReference`

## `MAX_LADDER_RUNG_LENGTH`

Many rungs share one generation prompt, so this is tighter than AiService's
`MAX_CONCEPT_GUIDE_LENGTH`.

## `#usable_lesson` and `#lesson?`

The `lesson` column is read back through `ConceptLesson.from_provider`, the same check that holds a new lesson at the boundary, and `#lesson?` is true only when that leaves a part to show (#558). Four production rows once stored the string `"None"`, which the old `lesson.present?` counted as a lesson: Learn showed an empty lesson box, hid the explanation, guide and pitfalls, and offered no "Write the short lesson". A number or a list there made the page raise. The page now renders `#usable_lesson`, so a stored value it can't show reads as no lesson, and the button's rewrite replaces it. The read applies today's `ConceptLesson` limits, so tightening `MAX_TEXT_LENGTH`, `MAX_SITUATIONS` or `MAX_HABITS` hides the parts of stored lessons past the new limit, and can turn `#lesson?` false so Learn offers the lesson button again, a billed call when clicked.

The migration `ClearNonHashConceptLessons` cleared every non-object lesson once, on the owner's choice to remove the bad values from the data as well. It doesn't touch an object whose parts are all unusable, which `#lesson?` already treats as no lesson.

# `ConceptReference`

## `MAX_LADDER_RUNG_LENGTH`

Many rungs share one generation prompt, so this is tighter than AiService's
`MAX_CONCEPT_GUIDE_LENGTH`.

## `#usable_lesson` and `#lesson?`

The `lesson` column is read back through `ConceptLesson.from_provider`, the same check that holds a new lesson at the boundary, and `#lesson?` is true only when that leaves a part to show (#558). Four production rows once stored the string `"None"`, which the old `lesson.present?` counted as a lesson: Learn showed an empty lesson box, hid the explanation, guide and pitfalls, and offered no "Write the short lesson". A number or a list there made the page raise. The page now renders `#usable_lesson`, so a stored value it can't show reads as no lesson, and the button's rewrite replaces it. The read applies today's `ConceptLesson` limits, so tightening `MAX_TEXT_LENGTH`, `MAX_SITUATIONS` or `MAX_HABITS` hides the parts of stored lessons past the new limit, and can turn `#lesson?` false so Learn offers the lesson button again, a billed call when clicked.

The migration `ClearNonHashConceptLessons` cleared every non-object lesson once, on the owner's choice to remove the bad values from the data as well. It doesn't touch an object whose parts are all unusable, which `#lesson?` already treats as no lesson.

## `.for`, `.seen_by` and `.visible_to`

The one answer to which reference a user sees: their own row only, never
another user's. Every row has an owner since the schema step of
`docs/decisions/learn-content-per-user.md`. `.for` finds the one row by user, concept and language, and `.seen_by` indexes the
user's rows by `[concept, language]`; the per-user unique index leaves one row per key.

## `.missing_for`

The pairs a user has no reference of their own for. Learn's prepare
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

## `.write_for` and `.write_wanted?`

`.write_for` saves one provider reply as the user's own row and returns
`:written`, `:skipped` or `:account_deleted`. `GenerateConceptReferenceJob`
calls it after the provider call and logs the answer (issue #790).

Locks are taken user first, then row, as `AccountDeletion` takes them. The
user row is share-locked (`FOR SHARE`) and must still be active, or nothing
is written. A deletion that holds the user row makes the write wait, and the
write then finds the account gone; a write that holds it first makes the
deletion wait. The job's code note says which spec covers each order. The user's own row is then read inside `uncached`, so the answer
never comes from a query cache the caller had on; a job runs with one, and
its earlier read would otherwise hide a row written since. Whichever way
that read comes out, `.write_wanted?` decides. With no row, it is asked
about `nil`, and a wanted write creates the row at `generation_version` 1.
A refresh against a version the user saw, for a row that has since gone,
writes nothing. An existing row is locked (`with_lock`, which reloads it)
and asked the same question: a write lands only when the row is still the
one the request was made against. A rewrite sets every `WRITTEN_FIELDS`
column, so a field the reply left out is cleared, and adds one to the
version.

### Losing a creation race

No lock covers a row that does not exist yet. If another writer inserts the
user's row after the uncached read and before `create!`, `.write_for`
raises instead of returning: `ActiveRecord::RecordNotUnique` from the unique
index, or `ActiveRecord::RecordInvalid` when the uniqueness validation
already sees the other row. It does not rescue either, because only the
caller knows whether losing is fine. `GenerateConceptReferenceJob#perform`
rescues both and logs a skip, re-raising a `RecordInvalid` whose error is
not on `concept`, since that is a real validation failure. A new caller
must do the same.

`.write_wanted?` is the one statement of when a write is wanted. A request
naming a `seen_version` the row no longer has already ran. Otherwise a
missing row is wanted, and an existing one only on a refresh while it is
not `#fully_written?`. The job asks it before its claim and again under the
claim, so a job with nothing to write makes no call.

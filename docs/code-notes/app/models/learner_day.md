# app/models/learner_day.rb

`LearnerDay` holds the derivations the dashboard and the two learner notes
endpoints share: which sections were passed over, the note box's question,
the explain question's default section and the explain box. It is pure, as
`NoteQuestion` and `ExplainQuestion` are: it takes the day's values and
reads no record, so `learner_notes_isolation_spec` holds it to values and
its spec needs no database. `LearnerNoteQuestions` reads those values once a
request, the duck thread included, and the controllers only pick a status
and a partial.

## Skipped sections

Fold state is never stored, so a section counts as passed over only once a
later section is answered. A section the engineer opened and left, with
nothing after it answered, reads as not yet reached.

## The pick log

`POST /learner_explanation` logs whether the saved section was the default.
It asks `.default_section` for that, which builds no box.

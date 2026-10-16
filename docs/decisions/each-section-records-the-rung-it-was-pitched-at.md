# Each section records the rung it was pitched at

`ProblemSetIngest`
stamps `pitched_at` (`junior` / `mid_level` / `senior` / `principal_engineer`) into every
section the provider returned, not only the ones the day asked for, because
the rendered set is resolved by slot precedence over what came back and an
unrequested section can win. Server-owned like `scenario` and
`current_schema`: every provider copy is stripped on every call, whatever
the caller passed, before the stamps go on. The rung is
`KindDifficulty#rung_for`: the kind's target when one is set, else the
profile's skill level, which uses the same scale, the one place a skill
level is read as a rung. A section whose concept
was offered as reduced-tier reinforcement in an unlocked kind also carries
`eased: true`, since the prompt's `(reduced)` rule asked for an easier
problem than the rung says; a locked kind exempts itself from that rule and
so is never marked. That is the one easing the server decides. The prompt's
"too hard" and "too easy" rating adjustments also move an unlocked
section's pitch, and the model judges when they apply, so they are not
recorded: an unlocked section's rung is what was asked for, possibly
adjusted, and only a lock makes it exact. Provider copies of both stamps
are stripped from every section first. A drilled concept at reduced tier is
annotated `(reduced, drilled)`, and the prompt's easing rule names that form
too, so its `eased` stamp records what was actually asked. `eased` reaches
no prompt, the review or the duck. `pitched_at` reaches one: each graded
section's review prompt states the rung it was pitched at, because the
rubric rates against that level (see "Grading rubric", `grading-rubric.md`). The others build
their text from named fields, and the judge, the one prompt that serializes a whole section,
strips every `ProblemSetIngest::SERVER_STAMPS` field first. The
diagnostics log serializes whole sections too and keeps the stamps, since
it is read by a person rather than a model. The Progress page does read them, which
is what they were written for: it says which rung a concept is held at from
stored evidence rather than from the diagnostics log, where the pitch level
lived before. Sections generated
before this carry no stamp and contribute no evidence. No migration: both
are keys inside the `problem_set` jsonb.

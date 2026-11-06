# app/models/exercise_section/code_review/bug_hunt.rb

Everything `code_review` knows about its `bug_hunt` mode that isn't a hook
on the kind itself: the mode's name, the field that marks a `bug_hunt`
section, the ingest checks and the key's optional fields.

## `.section?`

A `bug_hunt` section is a `code_review` section with a `purpose` field.
Ingest deletes a provider's `purpose` on every other mode, so after ingest
the field is a reliable marker. `CodeReview.bug_hunt?` and the separate
adaptation facet delegate to `BugHunt.section?`. The mode itself is never stored on the section, the way
`code_review_mode` never is.

## `Checks`

`CodeReview` extends `Checks`, so its methods run as the kind's own class
methods: they call `refuse!`, `usable_text?` and `shown_lines`, which are
private to `ExerciseSection`, without `send`. Their refusals use the
codes in `REFUSAL_CODES`, which `CodeReview.refusal_codes` includes, and
`refusal_codes_spec` reads this file with the kind's own.

- **The purpose** must be one line of at most `MAX_PURPOSE_LENGTH`
  characters. A line break means the purpose is missing rather than too
  long, since a two-line purpose isn't the one-line statement the mode
  asks for.
- **The snippet** must exist and show at most `MAX_LINES` lines, counted
  with `ExerciseSection.shown_lines` after formatting, so blank lines don't
  count. `MAX_SNIPPET_LINES` (40, shared with `RealSource` and
  `SecurityReview`) stays untouched. Its own refusal code,
  `bug_hunt_too_long`, carries its own retry line, since
  `snippet_too_long`'s line names the 40-line cap.
- **No result comment** (`# =>`, `// =>` or `// ->`) may appear in the
  snippet. It is a cheap catch for the rule that a `bug_hunt` shows no
  program output. The prompt and the judge carry the rest of that rule.
- File fields a provider sent are dropped, since a `bug_hunt` day is
  always single-file.

## `.optional_key_fields`

On a `bug_hunt` section the key keeps `issue`, `why_it_matters` and `fix`,
all required as on every `code_review`, plus three optional fields:
`witness` (`call`, `expected`, `returns`), `looks_right_on` (`call`,
`expected`) and `fixed_snippet`. An optional field that is incomplete is
dropped alone and the rest of the key is kept. Every text inside them is
measured against `PlantedKey::MAX_LENGTH` like the rest of the key. The
quote check still reads only `issue`, since a witness holds inputs that
aren't in the code.

## `KindHooks`

`CodeReview` extends this module for its bug-hunt-specific decisions:
difficulty, planning and evidence eligibility, concept visibility, judging
and context. Each hook answers as the kind's own class method and
overrides the ordinary default. This keeps mode decisions on the kind,
away from shared callers, without growing `code_review.rb`.

## `.snippet_context`

The goal line and the snippet with every line numbered (`1 | def …`), the
way the page numbers them, under a note that the `N | ` prefix is not code.
`CodeReview.review_context` and `SectionContext` (the duck and the
difficulty assessment) both read it, so the grader and the duck can cite
"line 4" and the engineer sees line 4. It never includes the concept or the
key. A section that isn't a `bug_hunt` gets nil, and its context renders as
before.

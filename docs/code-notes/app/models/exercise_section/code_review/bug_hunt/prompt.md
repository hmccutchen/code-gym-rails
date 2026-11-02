# app/models/exercise_section/code_review/bug_hunt/prompt.rb

The generation guidance and schema fragment for a `bug_hunt` day.
`CodeReview.generation_guidance` and `.schema_fragment` hand over to it when
the day's mode is `bug_hunt`, in place of the mode's content line, so a day
on any other mode renders exactly as before.

## `.guidance`

- **The trap** comes from the plan's picked `BugHuntGotchas` entry, never
  from the model's choice, and the vocabulary line offers only that entry's
  concept. A `bug_hunt` day without a picked gotcha is a bug in the plan,
  so the guidance raises rather than render a puzzle with no trap named.
- **The language line** keys on the gotcha's language. JavaScript snippets
  are ES modules, since `js_arrow_method` depends on module mode and the
  measurement harness runs every snippet as an `.mjs` file.
- **The rung line** has three tiers, and `principal_engineer` takes the
  `senior` line (`RUNG_FOR`): a 10-line puzzle has no room for a decision
  at system scale. A later line says the 10-line limit and the purpose come
  before the difficulty guidance's realistic constraints, since the concept
  ladders were written for realistic code.
- **The witness** is asked for as code (`call`, `expected`, `returns`), so
  a script can run it without anyone transcribing prose. For an async
  trap the call returns a snapshot of the state at the moment it returns:
  a copy taken in a `.then` is made after pending callbacks may have run,
  and a live reference would show its settled state.
- **`looks_right_on`** is asked for from `mid_level` up, where the input the
  purpose suggests first is meant to look right.
- **The purpose's length** is stated in the guidance and the schema from
  `BugHunt::MAX_PURPOSE_LENGTH`, the limit ingest enforces. The first Ruby
  measurement run asked only for "one sentence", and 16 of its 22 drafts
  were refused at 161 to 213 characters.

## `.schema_fragment`

It drops `scenario` and `diagram` and adds `purpose` and the key's
optional fields. `looks_right_on` is in the schema at every rung, since the
fragment has no rung; ingest keeps it when it is complete and drops it
when not.

## The judge (`JUDGE_TASK`, `JUDGE_GUIDANCE`)

`CodeReview.judge_task_for` and `.judge_guidance_for` return these for a
`bug_hunt` section; every other kind's section-aware hooks fall back to
its class-level task and guidance unchanged. The guidance asks the judge to
solve the puzzle first, then names which rejection principle each failure
falls under: correct as written, a second trap, shown output or a purpose
that gives the trap away are `reasoning_failure`; code outside the core
language is `unstated_prerequisite`; calling something undefined is
`underdetermined`. The judge prompt still prints the generic level meaning
for the pitched rung, so the guidance says `principal_engineer` is pitched
as `senior` here. `purpose` is not in `.prose_fields`, so the judge can
never rewrite what defines a correct answer.

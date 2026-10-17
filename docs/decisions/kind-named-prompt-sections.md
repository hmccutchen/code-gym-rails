# Prompt sections are named by kind

Every prompt names a section by its JSON key, the same `ExerciseSection.key`
the schema uses: `The "architecture" section is…`, and the fourth-track lines
name `@plan.fourth`. None says "the third section" or "the fourth slot".

**Why.** On `main` the order is still fixed, with `code_review` and
`design_comparison` first. Once each user picks their own daily kinds
(`DailyKinds`, #408), a day can open with any kind, so a positional phrase
would point the model at the wrong section. Naming by key also ties the
prose to the schema: the model reads the same token in both places.

**Only for kinds in the request.** The fourth-track lines (reinforcement,
retention check, established concept) render only when the fourth kind is
among the kinds being asked for. A single-section retry for another kind
leaves them out, so it never names a key its schema lacks. The general
retention block already filtered by kind the same way.

**How it is held.** `generation_prompt_section_names_spec` fails on an
ordinal or "last" followed by "section" or "slot" in any prompt snapshot and
in any Ruby file under `app/` or `lib/`, which covers the judge, review,
duck and difficulty prompts that have no snapshot. Page copy in
`config/locales/en.yml` ("Rotating third section") is a settings legend, not
a prompt, and is out of the scan.

**Still open.** A few lines assume `code_review` is in the day:
`DesignComparison`'s "the same as the code review's" and `SecurityReview`'s
"the same bar as code_review's snippet". They name no position, so this
check passes them, but a pair without `code_review` would leave them
pointing at a section that is not there. That belongs with the change that
lets an engineer choose such a pair.

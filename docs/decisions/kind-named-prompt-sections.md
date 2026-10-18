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

**Lines that compare against another section.** Some lines compare one
section with another: `DesignComparison`'s "the same as the code review's"
and `SecurityReview`'s "the same bar as code_review's snippet" and
"code_review/pattern's broader vocabulary". Each kind's
`.generation_guidance` receives `alongside:`, the keys of the other kinds in
the same request, and renders a comparison only when the section it names is
there. Without `code_review` the design-comparison line is left out, the
snippet line ends at "not a contrived toy example", and the vocabulary line
names only the kinds present, or "another section's" when neither is. On a
default day only the vocabulary line changed, where `pattern` was not
planned: it now says "code_review's" instead of "code_review/pattern's".
`alongside:` is the kinds requested together, not the day's kinds, so a
single-section retry passes none: a `design_comparison` retry leaves the
overlap line out even on a day that has a code review, the same way a retry
leaves out the fourth-section lines.

`generation_prompt_pair_coverage_spec` takes every pair `DailyKinds` accepts
(`DailyKinds.problems_with` empty), renders each in both languages with
index-wise rotations (each optional slot's first kind, then its second, and
so on, plus an empty rotation, not every combination) and a single-section
retry of every kind in each. It fails when the instruction text names a
quoted section key the schema lacks, or names any kind's key or label
followed by "'s" or " section" when that kind is not in the schema.

**Idiom lines kept on purpose.** The concept-group lines in
`GenerationPrompt::ConceptGuidance` describe how each kind expresses a
concept, not a sibling section of the same day: "a code_review tagged
reading_for_intent plants…", "A challenge tagged separating_symptom_from_cause
states…", "Where no code is shown (pattern)…", "a pattern, which shows no
code, describes…", "a design_comparison shows…" and "The challenge section is
the exception to the answer shape, since its answer is code". They render on
every day because a concept may land on any kind that hosts it. Only the last
matches the spec's "<kind> section" check, so it is the one named exception
(`KIND_IDIOM_PHRASES`). Its wording reads like a reference to a sibling
section, and a later change may reword it, for example to "When the challenge
kind hosts this concept…".

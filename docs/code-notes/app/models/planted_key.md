# `PlantedKey`

The one place the four newer discovery kinds (`code_review`,
`security_review`, `plan_review`, `pseudocode_to_code`) bound the answer key
a provider plants, under `answer_key`
(`docs/stored-answer-keys-spec-2026-10-27.md`).

A kind that plants a key answers `.planted_key?` and shapes it in
`.normalize_planted_key`. `ExerciseSection.reject_unusable!` then lists the
field and stores the cleaned key, or deletes it, through `.store!`. An
unusable key never drops the section: the key only helps grading, and the
grader falls back to today's behavior for a section without one.

`MAX_LENGTH` (500) bounds one field. A key is one or two sentences that
quote a line of code or plan, so 500 characters only cuts a runaway reply.

Three older helpers bound provider text the same way:
`ExerciseSection::DesignComparison`'s `usable_text?`, `AmbiguityHunt`'s
inline strip and `ExerciseSection.normalize_scaffold`. They stay where they
are for now, since moving them would change two working kinds inside the PR
that added keys. hmccutchen/code-gym-rails#597 moves them here.

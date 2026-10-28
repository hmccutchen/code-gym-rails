# `PlantedKey`

The one place the four newer discovery kinds (`code_review`,
`security_review`, `plan_review`, `pseudocode_to_code`) bound the answer key
a provider plants, under `answer_key`
(`docs/stored-answer-keys-spec-2026-10-27.md`).

A kind that plants a key extends `PlantedKey::Kind` and answers its hooks:
`.normalize_planted_key` (its shape), `.quoted_key_texts` (which key text
quotes) and `.key_context_fields` (the shown fields the quotes are checked
against, which the key sheet also shows). `ProblemSetIngest#clean_planted_keys!`
stores the cleaned key, or deletes it, through `.store!`. An
unusable key never drops the section: the key only helps grading, and the
grader falls back to today's behavior for a section without one.

`MAX_LENGTH` (500) bounds one field. A key is one or two sentences that
quote a line of code or plan, so 500 characters only cuts a runaway reply.

Three older helpers bound provider text the same way:
`ExerciseSection::DesignComparison`'s `usable_text?`, `AmbiguityHunt`'s
inline strip and `ExerciseSection.normalize_scaffold`. They stay where they
are for now, since moving them would change two working kinds inside the PR
that added keys. hmccutchen/code-gym-rails#597 moves them here.

## The quote match

`.unquoted_parts` compares with all whitespace removed on both sides. The
Ruby formatter's Layout cops add spaces the provider never wrote
(`{a: 1}` becomes `{ a: 1 }`, `x+1` becomes `x + 1`), so a quote of the
provider's own snippet would otherwise miss against the code as shown. A
quote under `MIN_QUOTE_LENGTH` characters is left out, since a lone `.`
matches anything. A backtick inside a quote, such as a JavaScript template
literal, splits it into fragments; the check is a diagnostic, so that limit
is accepted.

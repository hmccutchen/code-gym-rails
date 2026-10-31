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

`MAX_LENGTH` (1,500) bounds one field, and `.too_long?` checks every text
in a cleaned key against it, however nested. A field past it drops the whole
key, never cuts it, since a cut field can lose the part grading needs
(`docs/decisions/stored-answer-keys.md`, "A key past the length limit is
dropped"). `.text` only strips, so the check sees the provider's full text.

Three older helpers bound provider text the same way:
`ExerciseSection::DesignComparison`'s `usable_text?`, `AmbiguityHunt`'s
inline strip and `ExerciseSection.normalize_scaffold`. They stay where they
are for now, since moving them would change two working kinds inside the PR
that added keys. hmccutchen/code-gym-rails#597 moves them here.

## The quote match

`.unquoted_parts` compares the quote with the shown text through
`KeyQuote.normalize`, given the set's language, and counts a quote missing
when its normalized form isn't a substring of the normalized text
(`docs/code-notes/app/models/key_quote.md`). The Ruby formatter's Layout
cops add spaces the provider never wrote (`{a: 1}` becomes `{ a: 1 }`, `x+1`
becomes `x + 1`), and both formatters add a trailing comma to the last item
of a wrapped list, so a quote of the provider's own snippet would otherwise
miss against the code as shown. A quote whose normalized form is under
`MIN_QUOTE_LENGTH` characters is left out, since a lone `.` matches
anything. A backtick inside a quote, such as a JavaScript template literal,
splits it into fragments; the check is a diagnostic, so that limit is
accepted.

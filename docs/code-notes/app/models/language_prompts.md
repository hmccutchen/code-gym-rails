# `LanguagePrompts`

Each concept bucket's prompt wording: its label, its coach, its focus and, for the two real languages, its test framework and schema artifact. It is domain data, so it moved off `AiService` (#431). `GenerationPrompt` reads it for its own language; the other prompt classes take the coach, label or focus from their caller.

## `.for`

Fails loudly on "mixed" or a typo instead of silently falling back to Ruby/Rails. `AiService`, `GenerationPrompt` and `script/model_comparison.rb` share this one lookup.

## `ALL` (javascript `schema_artifact`)

The JavaScript artifact is a Prisma schema change together with its migration,
because `unsafe_migration` cannot be planted in a `schema.prisma`, which has no
migration semantics.

# `app/models/glossary.rb`

## `FORMS`

`FORMS` maps a key to the extra word forms that show its definition: plurals,
verb forms and hyphenated spellings such as "memoized" or "thread-safe". The
span keeps the word the text used, and the definition is the key's.

The forms are listed by hand. A suffix rule would match `concerns` and `fakes`
as verbs, and would underline "indexing" twice because it has its own key. A
list is reviewed the way the definitions are, and a form must be an inflection
of its key. Bare adjectives like `pure` and `immutable`, and words that are no
key's inflection, stay out.

Forms are unique across the glossary. No form equals a key or another key's
form, and `glossary_spec` fails when one does. The pattern lists longer words
first, so "idempotency key" shows its own entry and the shorter key
`idempotency` does not win inside it; `glossary_spec` pins that order.

A new key or form is checked against real text before it merges. A listing of
every match over reference prose and the app owner's recent exercise text, with
context on both sides, shows any match in a different sense from its key. That
listing gates forms as well as keys, and a wrong-sense match drops the form or
gives it a longer phrase.

`script/glossary_sense_listing.rb` produces that listing. Give it the export as
JSONL (`source`, `id`, `field` and `text` on each line) and a base words file,
and it prints every match of a new spelling, grouped by key. The base words file
holds every key and every form, one per line; run the script with `--words` at
the base commit to make it. The scan uses the pattern over all keys and forms,
as the page does, and drops a match only when its spelling is in the base words,
so the longer key still wins where two overlap (`adapter pattern` over a new
`adapter`). The export stays outside the repository.

## `key_for`

`key_for(text)` returns the key that a matched word belongs to, whether the
word is the key or one of its forms. It reads `LOOKUP`, the reverse
hash `lookup_for(TERMS, FORMS)` builds once at load and freezes, so no request
changes shared state. `stub_glossary` replaces `LOOKUP` with the constants it
stubs. `definition_for(text)` returns the definition for a key or a form, so a
caller that only needs the definition never reads `TERMS` itself.

## The length rule

A definition is one sentence of at most 180 characters. Twelve entries break that
rule, four with two sentences and eight over 180 characters. They were written
before the rule and are named in `GlossaryLengthRule::LONG_ENTRIES` in
`glossary_spec`. Every entry stays at or under 300 characters. The list can
shrink when an entry is shortened and should not grow: a new entry that needs
more room is two terms.

## Measuring coverage

`bin/rails runner script/glossary_coverage.rb <audit.tsv>...` reads the
production reference audit and prints, for the rows a reader sees, how many
match a key or form as a whole term, match through a form, match inside a
longer term, or match nothing, followed by the twenty most common unmatched
terms. It writes nothing and calls no provider. The TSVs hold terms derived
from production text, so they stay outside the repository. The `by_form` count
is a subset of `whole_term` and prints 0 for the 2026-10-25 audit, because its
term column already holds the base form.

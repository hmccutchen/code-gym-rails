# `app/helpers/glossary_helper.rb`

## `#glossary_wrap`

It turns the first use of each glossary term in a piece of text into a
`.gloss-term` span that the glossary controller opens as a definition panel.
The first-use rule is per field. Each call starts with an empty `seen` set, so
a tagline and the explanation under it each underline "memoization" once. A
reader who jumps straight to the explanation still meets the term underlined.
One underline for a whole page would leave every later field plain.

`seen` holds keys, resolved through `Glossary.key_for`, so "memoization" and
then "memoized" in one field underline once. The span keeps the text's own
word and takes the key's definition. The helper never inspects forms itself:
`Glossary.key_for` is the one place that knows a word is a form, so a new form
needs no change here (see `docs/code-notes/app/models/glossary.md`).

Pass `seen:` to share one set across several calls that make up one field.
`#glossary_wrap_prose` does this.

The text goes in as raw text, and each fragment is escaped before the result is
marked `html_safe`. Reference fields come from a provider, so they can't be
trusted to be free of markup. If the helper trusted its input, a field holding
`<b>raw</b>` would render as bold, and a field holding a script tag would run.
Escaping the pieces keeps the only markup in the output the spans the helper
builds itself.

An input that is already `html_safe` would defeat this, because `html_escape`
leaves a safe string alone. The helper calls `to_str` first so the escape
always runs.

## `#glossary_wrap_prose`

A worked example's prose can hold backtick code spans. It splits the text on
`SyntaxHighlightingHelper::INLINE_CODE` and renders each span as plain `<code>`
with no wrapping. It wraps the prose between the spans and passes one `seen`
set through all of them, so a term used before and after a code span is
underlined once in that paragraph.

## Why code is never wrapped

A term inside code is an identifier or a literal, not a use of the word. A
`memoize` method or a `throttle` call isn't asking for a definition, and a
span inside a highlighted block would break the highlighter's markup. So the
code example, the worked example's code and every `<code>` span stay as they
are. Views call the wrapper only for prose fields.

## Alternate framings are wrapped in the request

Alternate framings of a concept arrive after the page loads, so no view wraps
them. `ConceptReferencesController#explain_differently` runs the framing
through this helper and returns the result as `alternate_html`, escaped again
because the helper returns plain, unescaped text when no term matches and the
page inserts the field with `innerHTML`.
`docs/code-notes/app/controllers/concept_references_controller.md` has the
detail. Framings of a reviewed section are still plain text.

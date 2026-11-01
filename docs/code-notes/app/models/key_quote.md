# `KeyQuote`

The one home for matching text a provider quoted against the code as the
page shows it, after `CodeFormat` has reformatted it. The stored keys' quote
check (`PlantedKey.unquoted_parts`), the multi-file code review's
changed-line resolver and the blind-solve triage script (`KeyTriage`) call
it today, and the multi-file key's evidence check will too. One matcher means one rule for what counts as "the same code", so two checks
can't disagree about a quote (design spec section 4, 2026-10-29).

## The rules

`.normalize(text, language:)` applies these, in order, to the text:

- **All whitespace is removed, inside string literals too.** This is the
  rule the owner chose for stored keys on 2026-10-28 ("ignore all
  whitespace"), which `PlantedKey.unspaced` held until `KeyQuote` replaced
  it. The `change_review` spec's finer rule, which kept whitespace inside
  string literals, was dropped so there is one rule. Its known limit:
  `"superuser"` matches `"super user"`. The checks are diagnostics and
  boundary checks on provider text, so a rare false match costs less than a
  second rule.
- **JavaScript only**, on the whitespace-free text, undoing Prettier's
  rewrites: `'` is read as `"`; one trailing `;` is dropped; a comma directly
  before `)`, `]` or `}` is removed; and parentheses around one bare arrow
  parameter are removed, so `(id)=>` reads as `id=>`. Prettier changes all
  four, and a provider usually quotes the code it wrote, before formatting.
  Ruby keeps its quotes, since `'` and `"` differ there.

  These rules mostly let more quotes match, but the arrow-parameter rule
  can make one miss that whitespace alone would match. It reads the
  parentheses only when `=>` follows them, so a quote that stops before
  the arrow keeps them while the code loses them: `done = (order)` misses
  against `const done = (order) => order.paid;`. A stored key quote that
  matched under the old rule can now log `quote_missing`. `key_quote_spec`
  pins the case.
- **Every language:** one comma at the very end is dropped. Both formatters
  add one to the last item of a list they wrap, so a quote of
  `timeoutMs: 5000` should equal the line `timeoutMs: 5000,`.

Because each rule runs on the output of the one before, they compose: a
JavaScript call Prettier wrapped onto three lines with a trailing comma
normalizes to the same text as the provider's one-line, single-quoted,
semicolon-free quote.

## The lookups

`.line(code, quote, language:)` is whole-line equality, for naming a changed
line. It compares the normalized quote with each normalized source line,
and on JavaScript also with each run of two or more lines joined, up to the
whole code, since Prettier puts each argument of a long call on its own line
and a statement can wrap onto five lines or more. Runs are built only
between lines that have content, since blank lines don't count toward the
15-shown-line cap: a file padded with a thousand blank lines still has at most
15 endpoints, so at most 120 runs to try, instead of one run for every pair of
physical lines. It answers only when exactly one
line or run matches. Two matches mean the quote doesn't say which line it
means (a bare `end` or `}`), so it returns nil rather than guess. A blank
line never matches, and a run never starts or ends on a line that
normalizes to nothing, so a padded run can't count as a second match of the
line inside it. It returns nil for a quote that normalizes to nothing.

`.find(code, quote, language:)` is a substring search of the normalized
quote in the normalized whole code. Each normalized character remembers the
source line it came from, so the result is the 1-based range of lines the
match spans. It suits a quote that may be part of a line or several. It
returns nil for a quote the code holds more than once, as `.line` does for
two matches, since a short quote such as `order` would otherwise land on
whichever appearance comes first, and for a quote that normalizes to
nothing. The triage script is
its first caller; the multi-file key's evidence check
(`docs/decisions/multi-file-code-review.md`) will be the second.

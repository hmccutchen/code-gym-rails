# `KeyQuote`

The one home for matching text a provider quoted against the code as the
page shows it, after `CodeFormat` has reformatted it. The stored keys' quote
check (`PlantedKey.unquoted_parts`) calls it today, and the multi-file code
review's evidence check and changed-line resolver will call it too. One
matcher means one rule for what counts as "the same code", so two checks
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
- **Every language:** one comma at the very end is dropped. Both formatters
  add one to the last item of a list they wrap, so a quote of
  `timeoutMs: 5000` should equal the line `timeoutMs: 5000,`.

Because each rule runs on the output of the one before, they compose: a
JavaScript call Prettier wrapped onto three lines with a trailing comma
normalizes to the same text as the provider's one-line, single-quoted,
semicolon-free quote.

## The two lookups

`.find(code, quote, language:)` is a substring search of the normalized
quote in the normalized whole code. Each normalized character remembers the
source line it came from, so the result is the 1-based range of lines the
first match spans. It suits a quote that may be part of a line or several.

`.line(code, quote, language:)` is whole-line equality, for naming a changed
line. It compares the normalized quote with each normalized source line,
and on JavaScript also with each run of two to four lines joined, since
Prettier can wrap one line onto several. It answers only when exactly one
line or run matches. Two matches mean the quote doesn't say which line it
means (a bare `end` or `}`), so it returns nil rather than guess. A blank
line never matches, and a run never starts or ends on a line that
normalizes to nothing, so a padded run can't count as a second match of the
line inside it.

Both return nil for a quote that normalizes to nothing.

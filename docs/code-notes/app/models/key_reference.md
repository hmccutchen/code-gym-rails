# `KeyReference`

`PlantedKey.quote_tally` asks `.resolves?` about a backticked span that
isn't verbatim in the code. A key names code in its prose as well as
quoting it: it writes `Adoption.create!` where a spec shows
`allow(Adoption).to receive(:create!)`, or `HoldPickupJob#perform` for a
method defined two lines below its class. Read as verbatim quotes, those
names counted as misses, and 4 of the 8 drafts the owner read on 2026-11-01
logged `quote_missing` while every key was right
(`docs/decisions/stored-answer-keys.md`, "A code reference is not a
misquote").

Three Ruby shapes resolve, and nothing else:

- `Const.method`, where the receiver may be namespaced (`Billing::Invoice`)
  or chained (`Rails.cache`). The receiver and the method must share one
  line, as a call (`.fetch`) or a symbol (`receive(:fetch)`), and the method
  must match whole, so `Adoption.create` doesn't resolve against `create!`.
- `Const#method`. `def method` must appear in `class Const`'s body, which
  runs up to the next class at the start of a line.
- A call shortened with `...`. Each piece around the `...` of at least
  `PlantedKey::MIN_QUOTE_LENGTH` characters must appear in the normalized
  code, in order. A span with no piece that long doesn't resolve.

The one-line and class-body rules are what keep a true miss from passing:
`Pet.create!` doesn't resolve against a file holding `Pet` on one line and
`create!` on another. They read the code line by line, unnormalized, since
removing whitespace would join `def perform` into one token. A call whose
receiver and method the formatter splits across lines
(`Rails.cache` then `.fetch` on the next) doesn't resolve, an accepted
limit of a diagnostic.

Other languages resolve nothing. JavaScript names code differently
(`obj.method()`), and no JavaScript run has shown which shapes it needs.

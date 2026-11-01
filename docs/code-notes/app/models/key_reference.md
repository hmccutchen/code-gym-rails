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

Three Ruby shapes resolve, and nothing else. A trailing `(...)` is dropped
first, so `Rails.cache.fetch(...)` resolves wherever `Rails.cache.fetch`
does.

- `Const.method`, where the receiver may be namespaced (`Billing::Invoice`)
  or chained (`Rails.cache`). The method must be called on that receiver
  (`Adoption.create!(...)`, or `Rails.cache` with `.fetch` on the next
  line), or stubbed on it (`allow(Adoption).to receive(:create!)`,
  `expect(Rails.cache).to have_received(:fetch)`). The method must match
  whole, so `Adoption.create` doesn't resolve against `create!`.
- `Const#method`. `def method` must appear in `class Const`'s own body,
  which ends at the first `end` indented like the `class` line. A class in
  a module counts. `class Const::Inner` doesn't count as `Const`.
- A call shortened with `...`. Each piece around the `...` of at least
  `PlantedKey::MIN_QUOTE_LENGTH` characters must appear in the normalized
  code, in order. A span with no piece that long doesn't resolve.

These rules are what keep a true miss from passing. `Adoption.create!`
doesn't resolve against `Pet.create!(adoption: Adoption.new)`, where the
method is called on something else, or against `Adoption::Record.create!`,
where `Adoption` is only a namespace. `Foo#perform` doesn't resolve against
a `def perform` after `class Foo`'s `end`. The review of #648 found each of
these passing under the first version, which only asked for the receiver and
the method to share a line.

A reference still means the name is present in the code, not that the key
points at the right line. The owner reads the `reference` count beside the
key sheet for that. Known limits of a diagnostic: a one-line
`class Foo; def perform; end; end` doesn't resolve, and a stub written
another way (`allow_any_instance_of`, `receive_message_chain`) doesn't
either.

Other languages resolve nothing. JavaScript names code differently
(`obj.method()`), and no JavaScript run has shown which shapes it needs.

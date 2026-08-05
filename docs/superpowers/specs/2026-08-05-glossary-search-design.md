# On-Demand Glossary Search

**Date:** 2026-08-05
**Status:** Approved

## Problem

`GlossaryHelper#glossary_wrap` renders a fixed set of terms per section —
whichever ones the AI predicted might be unfamiliar at generation time. That
prediction always has gaps: it's guessing at the reader's knowledge instead
of responding to an actual expressed gap. There's no way today to ask about
a term the AI didn't happen to flag.

## Goal

Let a user type any term and get a definition, backed by a static curated
dataset rather than a live AI call — so it works even with an invalid,
missing, or rate-limited API key, and never invents or misleads on an
unfamiliar term the way a general-purpose dictionary would (general
dictionaries define common English words, not programming jargon —
"closure," "hoisting," and "idempotent" either don't exist there or resolve
to the wrong, non-technical sense).

This is additive. `GlossaryHelper`'s pre-generated, per-section inline terms
are untouched — same data, same rendering, same `gloss-term` tooltip
behavior. The new feature is named **`Glossary` / "glossary search"** to
keep it clearly distinct from `GlossaryHelper`'s `gloss-term` wrapping in
both code and UI copy.

## Data: `app/models/glossary.rb`, a Ruby constant

```ruby
module Glossary
  TERMS = {
    "closure" => "A function that remembers the variables from where it was
      defined, even after that outer scope has finished running.",
    # ...
  }.freeze

  def self.lookup(term)
    TERMS[term.to_s.strip.downcase]
  end
end
```

**Why a Ruby constant, not YAML:** every existing curated vocabulary in this
app (`RAILS_CONCEPTS`, `JS_CONCEPTS`, `ARCHITECTURE_CONCEPTS`,
`SCENARIO_DOMAINS`) lives as a plain Ruby constant in `ai_service.rb`, and
there is no precedent anywhere in the app for a `config/*.yml` data file —
all config YAML is framework config. A Ruby constant matches the existing
convention and needs no parser. It lives in its own file rather than folded
into `ai_service.rb` because it's ~150–250 entries of content unrelated to
prompts/HTTP, the same reasoning that already split
`app/models/exercise_section/*.rb` out of a would-be monolith.

Content: ~150–250 common Ruby/Rails/JS/general-CS terms, drawn from the
terms already in `RAILS_CONCEPTS`/`JS_CONCEPTS`/`ARCHITECTURE_CONCEPTS` and
the jargon those concepts commonly involve (not just the concept names
themselves) — closures, memoization, hoisting, idempotency, N+1, service
objects, mixins, promises, event loop, generics, etc. One-sentence,
plain-English definitions in the same teaching tone as the rest of the app.

Drafted once with AI assistance, then hand-reviewed and edited. A comment at
the top of the file states explicitly that nothing touches this file
automatically after that pass — it's pure static data from then on.
Extending it later is "add one line," by design, since gaps will keep
surfacing and get filled incrementally, not regenerated wholesale.

Keys are pre-normalized to lowercase, so `lookup` (already given
stripped/downcased input) is a direct hash read.

## Delivery: embedded JSON, zero network calls

`Glossary::TERMS` is small enough (~150–250 short entries) to serialize once
into the page rather than fetched per search. The layout renders it into a
`<script type="application/json" id="glossary-data">` tag, next to the
existing `gloss-term` tooltip script block. Page JS parses it once into a
plain lookup object (`Object.create(null)`, to avoid a search like
`"constructor"` resolving to `Object.prototype.constructor` instead of a
miss) and every search thereafter is a local property lookup.

This means glossary search needs no controller, no route, and issues no
request of its own — it keeps working even with a dead session or an
invalid/expired provider key, satisfying "must work regardless of API key
state" outright rather than by defensive fallback.

## Lookup semantics

- Normalize input the same way the data is keyed: strip, downcase.
- Exact match only — no substring/fuzzy suggestions. Simpler, and avoids a
  near-miss suggestion reading as authoritative when it isn't a match. If
  this proves too strict in practice, fuzzy matching is a incremental
  follow-up, not a blocker here.
- No match → a clearly-distinguished "*term* isn't in the glossary yet" row,
  never a silent no-op and never a fallback to any live API call.

## UI: one search box per section, in both live and read-only views

A new shared partial, `shared/_glossary_search.html.erb`, rendered once
inside each of the six section partials — `code_review`/`pattern` (inline in
`app/views/dashboard/_exercise.html.erb` and
`app/views/responses/_answered_sections.html.erb`) and the third-slot
partials (`_architecture_section`, `_security_review_section`,
`_parsons_problem_section`, and inline `challenge` in both parent views).
That means it appears both while a set is in progress (dashboard) and in the
read-only record of a submitted day (dashboard's submitted state, every
`/history` entry) — everywhere problem-set content renders.

```erb
<div class="glossary-search" data-glossary-search data-field="<%= field %>">
  <input type="text" placeholder="Search the glossary…" aria-label="Search the glossary">
  <button type="button">Search</button>
  <ul class="glossary-results" aria-live="polite"></ul>
</div>
```

`data-field` scopes each instance to its section (`code_review`, `pattern`,
`challenge`/`architecture`/`security_review`/`parsons_problem`) so multiple
boxes on one page never collide.

Behavior — one delegated script in the layout, matching the existing
`gloss-term` tooltip script's single-listener-for-every-instance pattern:

- Submit (button click or Enter) normalizes the input, looks up the parsed
  glossary object, and **appends** a `term: definition` row to that
  section's `<ul>` — a running list per section, not a single replaceable
  slot, so several lookups in one section all stay visible.
- A miss appends a visually distinct (muted/italic) "not in the glossary
  yet" row instead of a definition.
- No dedupe — searching the same term twice appends twice. Simplest
  behavior; repeat lookups in one sitting are rare enough not to warrant
  tracking state for.
- Nothing persists past reload and nothing is saved server-side — this is a
  scratch pad, not part of `DailyResponse`.

## Non-goals / explicit exclusions

- No changes to `GlossaryHelper`, `glossary_wrap`, or the per-section
  pre-generated `problem_set[...]["glossary"]` data — both features
  coexist untouched.
- No AI call at lookup time, ever.
- No general-purpose dictionary gem/API integration (see Goal).
- No fuzzy/substring matching in this iteration.
- No persistence of search history.

## Testing

- `spec/models/glossary_spec.rb` — `Glossary.lookup` normalization (case,
  surrounding whitespace) and miss behavior.
- A new `spec/system/glossary_search_spec.rb` (real-browser, against the
  existing `FakeService` fixture pages, following the pattern in
  `spec/system/glossary_tooltip_spec.rb`) covering: searching a known term,
  searching an unknown term, and two searches stacking in one section's
  list rather than replacing each other.

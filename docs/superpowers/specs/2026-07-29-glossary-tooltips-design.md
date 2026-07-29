# Inline vocabulary glossary tooltips

## Problem

A user unfamiliar with certain terminology (e.g. "closure," "IIFE," "dependency
array" in JS; "memoization," "duck typing" in Ruby) can get blocked by the
vocabulary itself before ever reasoning about the actual problem. This is
distinct from two things that already exist:

- `teaching_note` — nudges toward *how to solve* the problem, never the answer.
- `ConceptReference` — explains the section's one tagged `concept` as a whole,
  in depth, via a dropdown.

Glossary tooltips cover *incidental* terminology that shows up in a
question/scenario/prose field without being the main concept — a quick,
one-sentence definition surfaced inline, not a separate disclosure to open.

Bundled into this spec: the third-section type (architecture vs. challenge)
currently rolls 75/25 via `AiService#roll_third_section`. This is a working,
intentional weighted random roll, not interval-based alternation — what
looked like "not shuffling" is expected statistical streaking at that ratio.
Resolution: re-weight to 60/40, no logic change.

## Schema changes

`AiService#exercise_schema_for` gains an optional `glossary` field, a sibling
of `teaching_note`/`concept`, in all four section blocks (`code_review`,
`pattern`, `challenge`, `architecture`):

```
"glossary": [{"term": "string", "definition": "string — one plain-English sentence"}]
```

- 2-4 entries max, empty array when nothing in the section's text warrants a
  definition — never forced.
- Applies to both language modes (`ruby_rails` and `javascript`); jargon is
  language-specific, not JS-only.
- Tone matches the rest of the app's teaching content (plain English, one
  sentence).
- No migration: `problem_set` is an unstructured jsonb column already; old
  exercises simply lack the key.

## Third-section ratio

`AiService#roll_third_section`:

```ruby
def roll_third_section
  rand < 0.60 ? :architecture : :challenge
end
```

Only the threshold changes (was `0.75`). No interval/streak tracking is
introduced — the roll remains a pure per-generation coin flip, now 60/40
instead of 75/25.

## Safe wrapping algorithm

New `app/helpers/glossary_helper.rb`, method `glossary_wrap(text, glossary)`:

- Returns `text` unmodified (still auto-escaped by the caller's `<%= %>`) when
  `text` is blank or `glossary` is nil/blank — nil-safe for exercises
  generated before this feature existed.
- Operates on the **raw, unescaped** source string. Never regex-match against
  already-HTML-escaped text — escaping entities (`&amp;`, `&quot;`, etc.) can
  shift `\b` word-boundary positions and produce wrong or missed matches.
- For each glossary term, in array order, finds the first case-insensitive
  `/\b#{Regexp.escape(term)}\b/i` match in the raw text.
- If a term's match range overlaps a range already claimed by an
  earlier-processed term (e.g. "array" nested inside an already-wrapped
  "dependency array"), that later term is skipped for this field — first
  claim wins, no nested/overlapping spans.
- The raw string is split at the resulting match ranges. Every plain-text
  slice, and the term/definition text going into the span's attributes, is
  passed through `ERB::Util.html_escape` individually. Only the matched
  slices are wrapped:

  ```html
  <span class="gloss-term" data-definition="ESCAPED_DEFINITION">MATCHED_TEXT</span>
  ```

- The escaped slices and wrapped spans are joined and the result is marked
  `.html_safe`. This is safe specifically because every fragment reaching the
  final string was escaped *before* concatenation — nothing AI-generated or
  user-generated is ever interpolated into the HTML string unescaped. A term
  or definition containing `<script>` or `"` renders as inert escaped text,
  never breaks out of the `data-definition` attribute or the surrounding
  markup.
- A term with no match in the field's text is silently skipped — no error.

**Fields scanned** (prose only; each field is scanned independently, so a
term appearing in two fields of the same section gets its own first-occurrence
wrap in each):

| Section | Fields |
|---|---|
| `code_review` | `question`, `scenario` |
| `pattern` | `title`, `why`, `question`, `scenario` |
| `challenge` | `title`, `question`, `scenario` |
| `architecture` | `title`, `scenario`, `question`, each `options` array entry independently |

Explicitly **not** scanned: `snippet`, `starter_code` (rendered into
`<code data-hljs>` and rewritten asynchronously by the highlight.js script —
wrapping spans there would be destroyed by or conflict with that later
`innerHTML` replacement), `teaching_note`, and everything under
`architecture.reference` (separate disclosure widgets with their own voice).

## View integration

Every `<%= section["field"] %>` call for a scanned field, in both
`app/views/dashboard/_exercise.html.erb` (live/unanswered) and
`app/views/responses/_answered_sections.html.erb` /
`_architecture_section.html.erb` (read-only, shared by the dashboard's
submitted state and every `/history` entry), becomes:

```erb
<%= glossary_wrap(section["field"], section["glossary"]) %>
```

The live and read-only/history views use the same helper and the same
persisted `glossary` array, so a section's glossary renders identically
wherever it's shown.

## Interaction: hover (desktop) / tap (mobile), same tooltip

No new JS framework — matches the existing inline-`<script>` convention (the
app loads no Stimulus/importmap JS).

**CSS** (added to the layout's single `<style>` block, per the existing
convention that partials rendering on multiple pages must have their styles
there, not in a per-page block):

- `.gloss-term`: `border-bottom: 1px dotted var(--muted); cursor: help;` —
  subtle, consistent with existing muted-accent styling.
- Definition bubble: `::after` with `content: attr(data-definition)`,
  `position: absolute`, hidden by default.
- Shown when the term is `:hover`ed, gated behind
  `@media (hover: hover) and (pointer: fine)` so touch devices — which have no
  true hover — never get a stuck/phantom hover state; **or** when the term
  carries a `.gloss-open` class (any device, added by the JS below).

**JS** (one inline `<script>` IIFE, same pattern as the rating/highlight.js
scripts): a single delegated `click` listener on `document`.

- Click/tap on a `.gloss-term`: toggle `.gloss-open` on it, and remove
  `.gloss-open` from any other term that has it — only one tooltip open at a
  time.
- Click/tap anywhere else: close any currently-open tooltip.

On desktop this gives hover-to-preview plus click-to-pin (harmless, not
disruptive); on touch it's the only way to reveal a definition, exactly as
required.

## Constraints confirmed

- No changes to `teaching_note`, `ConceptReference`, or any other existing
  per-section content — purely additive.
- No migration — `glossary` lives in the same jsonb `problem_set` structure.
- Old exercises without a `glossary` key render exactly as today: the helper
  no-ops on nil/blank glossary, and no view previously rendered a glossary
  affordance.
- XSS: addressed above — wrapping composes from individually-escaped
  fragments and is marked safe only after escaping, never by escaping-then-
  reparsing or by trusting AI output to already be safe.

## Testing

- `spec/helpers/glossary_helper_spec.rb`: case-insensitive match, word-boundary
  correctness (no partial matches inside other words/identifiers),
  first-occurrence-only wrapping, overlapping-term skip behavior, missing-term
  no-op, nil/blank glossary passthrough, and an explicit XSS case (term or
  definition containing `<script>`/`"` renders fully escaped with no markup
  breakout).
- Request spec: a section's rendered HTML contains the expected
  `data-definition` span when `glossary` is present; renders unchanged when
  absent (old-exercise backward compatibility).
- `AiService#roll_third_section` spec's threshold assertions updated from
  0.75 to 0.60.
- Manual verification in the browser (dashboard live view and `/history`) for
  both hover (desktop) and tap (mobile viewport) behavior, per this project's
  convention of browser-testing JS-driven UI rather than relying on
  request/helper specs alone.

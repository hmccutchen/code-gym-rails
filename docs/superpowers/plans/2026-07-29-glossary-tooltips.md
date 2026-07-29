# Glossary Tooltips Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, per-section glossary tooltips (AI-generated term/definition pairs, safely wrapped and shown on hover/tap) to exercise sections, and re-weight the third-section architecture/challenge roll from 75/25 to 60/40.

**Architecture:** `AiService#exercise_schema_for` gains an optional `glossary` array per section. A new `GlossaryHelper#glossary_wrap` escapes-then-wraps the first occurrence of each term in a field's raw text before Rails renders it, producing an already-`html_safe` string. Views call this helper in place of the plain `<%= field %>` output for the fields in scope. A CSS/JS addition in the shared layout makes wrapped terms show their definition on hover (desktop) or tap (mobile), matching the app's existing inline-`<script>`, `<style>`-block-in-layout conventions.

**Tech Stack:** Ruby on Rails 8.0.5, RSpec, ERB, vanilla JS/CSS (no framework, no new dependency).

## Global Constraints

- No database migration — `glossary` lives inside the existing jsonb `problem_set` column (spec: "No migration expected").
- Old exercises without a `glossary` key must render identically to today — every new code path is nil-safe (spec: "Old exercises without a `glossary` field render exactly as today").
- No changes to `teaching_note`, `ConceptReference`, or any other existing per-section content — purely additive (spec: "Constraints confirmed").
- Wrapping must never let AI-generated or user-generated text break out of its escaped HTML context — every fragment is escaped individually before concatenation, and the result is marked `.html_safe` only after that (spec: "Safe wrapping algorithm").
- Only the first case-insensitive, word-boundary match of each term is wrapped, independently per scanned field (spec: "Fields scanned").
- `snippet`/`starter_code` are never scanned (would conflict with the async highlight.js `innerHTML` rewrite) (spec: "Fields scanned").
- Desktop uses hover, touch uses tap-toggle, only one tooltip open at a time, matching content either way (spec: "Interaction").
- Third-section roll changes from `rand < 0.75` to `rand < 0.60` — no other logic change (spec: "Third-section ratio").

---

## Task 1: Add `glossary` to the generation schema and prompt

**Files:**
- Modify: `app/services/ai_service.rb:389-546` (`exercise_schema_for`, `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Produces: `AiService#exercise_schema_for(language, third:)` now includes a `"glossary": [...]` key in every section's JSON schema block (`code_review`, `pattern`, `challenge`, `architecture`). Later tasks (view integration) read this key as `section["glossary"]`, an array of `{"term" => String, "definition" => String}` hashes (possibly empty or absent for pre-feature exercises).

- [ ] **Step 1: Write failing schema tests**

Add to `spec/services/ai_service_spec.rb`, inside the existing `describe "#exercise_schema_for"` block (after the `it "defines a scenario field for each of the three sections"` test around line 56):

```ruby
    it "defines an optional glossary array for each of the three sections" do
      schema = service.send(:exercise_schema_for)
      expect(schema.scan(/"glossary"/).size).to eq(3)
    end

    it "swaps in a glossary array for the architecture block too" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      architecture = JSON.parse(schema)["architecture"]
      expect(architecture).to have_key("glossary")
    end
```

Then update the existing test at line 86-94 (`"no longer asks the model for a pattern.reference block"`) — its `contain_exactly` list is now missing a key:

```ruby
    it "no longer asks the model for a pattern.reference block" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :challenge)
      pattern = JSON.parse(schema)["pattern"]

      expect(pattern.keys).to contain_exactly(
        "title", "why", "question", "scenario", "teaching_note", "concept", "glossary"
      )
      expect(pattern).not_to have_key("reference")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#exercise_schema_for"`
Expected: FAIL — `"glossary"` not found in schema; `contain_exactly` mismatch (missing `"glossary"`).

- [ ] **Step 3: Add `glossary` to every section block in `exercise_schema_for`**

In `app/services/ai_service.rb`, replace the `exercise_schema_for` method body (lines 389-444) with:

```ruby
  def exercise_schema_for(language = "ruby_rails", third: :challenge)
    label = config_for(language)[:label]
    glossary_field = %("glossary": [{"term": "string — an unfamiliar word from this section's own text", "definition": "string — one plain-English sentence"}])

    third_section =
      if third == :architecture
        <<~ARCH.chomp
          "architecture": {
              "title":     "string — short name for the decision",
              "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
              "question":  "string — ONE sentence asking for a decision + justification",
              "options":   ["string — a viable approach", "string — another viable approach", "string — an optional third approach (omit for 2)"],
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the architecture vocabulary",
              #{glossary_field},
              "reference": {
                "tagline":     "string — bold one-liner",
                "explanation": "string — 2-3 sentences",
                "tradeoffs":   ["string — a tradeoff", "string — a tradeoff", "string — a tradeoff"],
                "senior_lens": "string — how a senior frames the decision",
                "diagram":     "string — Mermaid source visualizing the decision, or an empty string if no diagram would help"
              }
            }
        ARCH
      else
        <<~CH.chomp
          "challenge": {
              "title":        "string",
              "question":     "string — what to implement",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "starter_code": "string — optional skeleton (empty string if none)",
              "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field}
            }
        CH
      end

    <<~SCHEMA
      {
        "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — #{label} code, ~10-15 lines",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          #{glossary_field}
        },
        "pattern": {
          "title":    "string — pattern name",
          "why":      "string — one sentence on why the pattern exists",
          "question": "string — conceptual question to answer",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          #{glossary_field}
        },
        #{third_section}
      }
    SCHEMA
  end
```

- [ ] **Step 4: Add a glossary instruction to the prompt**

In `app/services/ai_service.rb`, inside `build_exercise_prompt`, the `Instructions:` block (around line 528-541) gets one new bullet. Add it directly after the existing `teaching_note` bullet:

```ruby
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Each section's "glossary": 0-4 {term, definition} pairs for incidental terminology inside THAT section's own title/scenario/question/why/options text that a mid-level developer newer to #{label} might not immediately know — distinct from the section's own tagged "concept" and from "teaching_note". One plain-English sentence per definition, same tone as the rest of this app's teaching content. Return an empty array when nothing in the section's text warrants one — never force entries to exist.
```

(This replaces the single existing `teaching_note` bullet line with two bullets — the `teaching_note` line stays exactly as-is, the `glossary` line is new immediately after it.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS (all examples in this file, not just the new ones — confirms nothing else in the schema/prompt broke).

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add optional glossary field to exercise generation schema"
```

---

## Task 2: Re-weight the third-section roll to 60/40

**Files:**
- Modify: `app/services/ai_service.rb:265-267` (`roll_third_section`)
- Test: `spec/services/ai_service_spec.rb:119-126`

**Interfaces:**
- Produces: `AiService#roll_third_section` (private) — same signature and return values (`:architecture` / `:challenge`), only the probability threshold changes. No consumer changes needed since callers only branch on the returned symbol.

- [ ] **Step 1: Update the test description and threshold assertions**

In `spec/services/ai_service_spec.rb`, replace the `describe "#roll_third_section"` block (lines 119-126):

```ruby
  describe "#roll_third_section" do
    it "returns :architecture ~60% and :challenge ~40% (both reachable)" do
      allow(service).to receive(:rand).and_return(0.10)
      expect(service.send(:roll_third_section)).to eq(:architecture)
      allow(service).to receive(:rand).and_return(0.90)
      expect(service.send(:roll_third_section)).to eq(:challenge)

      # Boundary check: just under vs. just at/over the new 0.60 threshold.
      allow(service).to receive(:rand).and_return(0.59)
      expect(service.send(:roll_third_section)).to eq(:architecture)
      allow(service).to receive(:rand).and_return(0.60)
      expect(service.send(:roll_third_section)).to eq(:challenge)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails on the boundary assertions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#roll_third_section"`
Expected: FAIL on the `0.59`/`0.60` boundary checks (current code uses `0.75`, so both `0.59` and `0.60` currently return `:architecture`, but the new test expects `0.60` to return `:challenge`).

- [ ] **Step 3: Change the threshold**

In `app/services/ai_service.rb`, update `roll_third_section` (around line 265-267):

```ruby
  def roll_third_section
    rand < 0.60 ? :architecture : :challenge
  end
```

Also update the comment directly above it (lines 261-264) to say "60% of the time" / "40%" instead of "75%" / "25%" — keep the rest of the comment (extraction rationale, "never assert on real randomness") unchanged:

```ruby
  # Which third section this set gets: architecture-reasoning 60% of the time,
  # a traditional coding challenge 40%. Extracted so tests can stub it — never
  # assert on real randomness. The chosen kind is not tracked separately; the
  # persisted third key (problem_set["architecture"] vs ["challenge"]) is the record.
  def roll_third_section
    rand < 0.60 ? :architecture : :challenge
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#roll_third_section"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Re-weight third-section roll from 75/25 to 60/40"
```

---

## Task 3: `GlossaryHelper#glossary_wrap`

**Files:**
- Create: `app/helpers/glossary_helper.rb`
- Create: `spec/helpers/glossary_helper_spec.rb`

**Interfaces:**
- Produces: `GlossaryHelper#glossary_wrap(text, glossary)` — `text` is a `String` (possibly nil/blank), `glossary` is an `Array` of `Hash`-like objects each responding to `["term"]`/`["definition"]` (possibly nil/blank/empty). Returns a `String`: either `text` unchanged (nil-safe passthrough) or an `ActiveSupport::SafeBuffer` (`.html_safe`) with matched terms wrapped in `<span class="gloss-term" data-definition="...">`. Later tasks (view integration) call this in place of raw field interpolation, e.g. `glossary_wrap(cr["question"], cr["glossary"])`.

- [ ] **Step 1: Write the failing helper spec**

Create `spec/helpers/glossary_helper_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe GlossaryHelper, type: :helper do
  describe "#glossary_wrap" do
    it "wraps the first case-insensitive match of a term in a span with its definition" do
      glossary = [ { "term" => "closure", "definition" => "A function bundled with its surrounding variables." } ]
      result = helper.glossary_wrap("A Closure captures scope.", glossary)

      expect(result).to be_html_safe
      expect(result).to include('<span class="gloss-term" data-definition="A function bundled with its surrounding variables.">Closure</span>')
    end

    it "only wraps the first occurrence, leaving later repeats plain" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("A closure is a closure of scope.", glossary)

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include(">closure</span> is a closure of scope.")
    end

    it "does not match a term as a partial substring of another word" do
      glossary = [ { "term" => "class", "definition" => "A blueprint for objects." } ]
      result = helper.glossary_wrap("Welcome to the classroom, not a class problem.", glossary)

      expect(result).to include("Welcome to the classroom, not a")
      expect(result).to include('<span class="gloss-term" data-definition="A blueprint for objects.">class</span> problem.')
    end

    it "wraps multiple distinct terms independently in the same text" do
      glossary = [
        { "term" => "closure", "definition" => "def1" },
        { "term" => "hoisting", "definition" => "def2" }
      ]
      result = helper.glossary_wrap("A closure relies on hoisting rules.", glossary)

      expect(result.scan("gloss-term").size).to eq(2)
    end

    it "skips a later term whose only match overlaps an already-wrapped term" do
      glossary = [
        { "term" => "dependency array", "definition" => "outer" },
        { "term" => "array", "definition" => "inner" }
      ]
      result = helper.glossary_wrap("Watch the dependency array closely.", glossary)

      expect(result.scan("gloss-term").size).to eq(1)
      expect(result).to include('data-definition="outer"')
      expect(result).not_to include('data-definition="inner"')
    end

    it "silently skips a term with no match in the text" do
      glossary = [ { "term" => "nonexistentword", "definition" => "def" } ]
      result = helper.glossary_wrap("Nothing to see here.", glossary)

      expect(result).to eq("Nothing to see here.")
    end

    it "returns the text unchanged when glossary is nil" do
      expect(helper.glossary_wrap("Plain text.", nil)).to eq("Plain text.")
    end

    it "returns the text unchanged when glossary is empty" do
      expect(helper.glossary_wrap("Plain text.", [])).to eq("Plain text.")
    end

    it "returns nil/blank text unchanged" do
      expect(helper.glossary_wrap(nil, [ { "term" => "x", "definition" => "y" } ])).to be_nil
      expect(helper.glossary_wrap("", [ { "term" => "x", "definition" => "y" } ])).to eq("")
    end

    it "escapes a malicious definition so it cannot break out of the data attribute" do
      glossary = [ { "term" => "closure", "definition" => %(a trick" onmouseover="alert(1)) } ]
      result = helper.glossary_wrap("Explain the closure here.", glossary)

      expect(result).not_to include('onmouseover="alert(1)"')
      expect(result).to include("a trick&quot; onmouseover=&quot;alert(1)")
    end

    it "escapes unmatched HTML-bearing text in the same field" do
      glossary = [ { "term" => "closure", "definition" => "def" } ]
      result = helper.glossary_wrap("<script>alert(1)</script> a closure appears here.", glossary)

      expect(result).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(result).not_to include("<script>alert(1)</script>")
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/helpers/glossary_helper_spec.rb`
Expected: FAIL — `uninitialized constant GlossaryHelper` (file doesn't exist yet).

- [ ] **Step 3: Implement `GlossaryHelper`**

Create `app/helpers/glossary_helper.rb`:

```ruby
# Wraps each glossary term's first case-insensitive, word-boundary match in
# `text` with a <span class="gloss-term" data-definition="..."> that the
# tooltip CSS/JS (in the layout) reads. Operates on the raw, un-escaped
# `text` — never on already-escaped HTML, since escaping entities can shift
# \b word-boundary positions — and escapes every resulting fragment (plain
# text and span attributes) individually before assembling the final string.
# The result is marked .html_safe only after that escaping, so nothing in
# `text` or `glossary` (both may be AI-generated) can ever break out of the
# surrounding markup.
module GlossaryHelper
  def glossary_wrap(text, glossary)
    return text if text.blank? || glossary.blank?

    matches = []
    glossary.each do |entry|
      term       = entry["term"]
      definition = entry["definition"]
      next if term.blank? || definition.blank?

      match = text.match(/\b#{Regexp.escape(term)}\b/i)
      next unless match

      range = match.begin(0)...match.end(0)
      next if matches.any? { |m| ranges_overlap?(m[:range], range) }

      matches << { range: range, definition: definition }
    end

    return text if matches.empty?

    matches.sort_by! { |m| m[:range].begin }

    result = +""
    cursor = 0
    matches.each do |m|
      result << ERB::Util.html_escape(text[cursor...m[:range].begin])
      matched_text = text[m[:range]]
      result << %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(m[:definition])}">#{ERB::Util.html_escape(matched_text)}</span>)
      cursor = m[:range].end
    end
    result << ERB::Util.html_escape(text[cursor..])

    result.html_safe
  end

  private

  def ranges_overlap?(a, b)
    a.begin < b.end && b.begin < a.end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/helpers/glossary_helper_spec.rb`
Expected: PASS (all 11 examples)

- [ ] **Step 5: Commit**

```bash
git add app/helpers/glossary_helper.rb spec/helpers/glossary_helper_spec.rb
git commit -m "Add GlossaryHelper for safe inline term wrapping"
```

---

## Task 4: Wire `glossary_wrap` into the views

**Files:**
- Modify: `app/views/dashboard/_exercise.html.erb`
- Modify: `app/views/responses/_answered_sections.html.erb`
- Modify: `app/views/responses/_architecture_section.html.erb`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `GlossaryHelper#glossary_wrap(text, glossary)` from Task 3.
- Produces: rendered HTML containing `<span class="gloss-term" data-definition="...">` wherever a scanned field has a matching glossary term. Task 5 (CSS/JS) styles and wires interaction for `.gloss-term` elements — no dependency the other direction.

**Fields to wrap, per section (per the spec's field table):**
| Section | Fields |
|---|---|
| `code_review` | `question`, `scenario` |
| `pattern` | `title`, `why`, `question`, `scenario` |
| `challenge` | `title`, `question`, `scenario` |
| `architecture` | `title`, `scenario`, `question`, each `options` entry |

- [ ] **Step 1: Write failing request specs**

Add to `spec/requests/dashboard_spec.rb`, as a new `describe "glossary tooltips"` block (place it after the existing `describe "teaching hints"` block, using the file's existing `base_problem_set`/`create_exercise` helpers):

```ruby
  describe "glossary tooltips" do
    it "wraps a matching term in the code_review question with its definition" do
      ps = base_problem_set
      ps["code_review"]["question"] = "What does this closure capture?"
      ps["code_review"]["glossary"] = [ { "term" => "closure", "definition" => "A function bundled with its surrounding variables." } ]
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include('<span class="gloss-term" data-definition="A function bundled with its surrounding variables.">closure</span>')
    end

    it "wraps a matching term in an architecture option" do
      ps = base_problem_set
      ps["architecture"] = {
        "title" => "Pick a store", "question" => "Which store fits best?",
        "options" => [ "Use memoization to cache results", "Recompute every time" ],
        "glossary" => [ { "term" => "memoization", "definition" => "Caching a function's return value." } ]
      }
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include('<span class="gloss-term" data-definition="Caching a function&#39;s return value.">memoization</span>')
    end

    it "renders no glossary markup for sections without a glossary key" do
      create_exercise
      get root_path
      expect(response.body).not_to include("gloss-term")
    end

    it "still wraps glossary terms in the read-only submitted view" do
      ps = base_problem_set
      ps["pattern"]["why"] = "It avoids duck typing surprises."
      ps["pattern"]["glossary"] = [ { "term" => "duck typing", "definition" => "Caring about behavior, not declared type." } ]
      create_response(create_exercise(problem_set: ps))
      get root_path
      expect(response.body).to include('<span class="gloss-term" data-definition="Caring about behavior, not declared type.">duck typing</span>')
    end
  end
```

(Note: the second test expects `&#39;` because Rails' `ERB::Util.html_escape` escapes a single quote inside the `definition` attribute value — verify the exact escaped form matches what `html_escape` actually produces when you run the test; adjust the expectation string only if it differs, the wrapping/escaping behavior itself must not change.)

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "glossary tooltips"`
Expected: FAIL — `gloss-term` not found in any response body yet.

- [ ] **Step 3: Update `app/views/dashboard/_exercise.html.erb`**

Change the four field lines that fall in scope (leave `snippet`, `starter_code`, `teaching_note`, everything else untouched):

Line 43 — code_review question:
```erb
      <div class="question"><%= glossary_wrap(cr["question"], cr["glossary"]) %></div>
```

Line 42 — code_review scenario (inside the existing `if cr["scenario"].present?` guard):
```erb
      <% if cr["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(cr["scenario"], cr["glossary"]) %></div><% end %>
```

Line 60 — pattern title (inside the section-label div):
```erb
      <div class="section-label">2 — Pattern of the Month: <%= glossary_wrap(pat["title"], pat["glossary"]) %></div>
```

Line 61 — pattern scenario:
```erb
      <% if pat["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(pat["scenario"], pat["glossary"]) %></div><% end %>
```

Line 62 — pattern why:
```erb
      <div class="why-box"><strong>Why it exists:</strong> <%= glossary_wrap(pat["why"], pat["glossary"]) %></div>
```

Line 63 — pattern question:
```erb
      <div class="question"><%= glossary_wrap(pat["question"], pat["glossary"]) %></div>
```

Line 85 — challenge scenario:
```erb
        <% if ch["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(ch["scenario"], ch["glossary"]) %></div><% end %>
```

Line 86 — challenge question:
```erb
        <div class="question"><%= glossary_wrap(ch["question"], ch["glossary"]) %></div>
```

The challenge section-label ("3 — Coding Challenge", line 84) has no `title` interpolated — leave it as-is (unlike pattern, this label is a static string). `ch["title"]` is generated but not rendered anywhere in the current view, so there's nothing to wrap there — do not add a new render of `ch["title"]`.

- [ ] **Step 4: Update `app/views/responses/_answered_sections.html.erb`**

Same field-level changes, mirrored for the read-only view:

Line 9 — code_review scenario:
```erb
  <% if cr["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(cr["scenario"], cr["glossary"]) %></div><% end %>
```

Line 10 — code_review question:
```erb
  <div class="question"><%= glossary_wrap(cr["question"], cr["glossary"]) %></div>
```

Line 22 — pattern title:
```erb
  <div class="section-label">2 — Pattern of the Month: <%= glossary_wrap(pat["title"], pat["glossary"]) %></div>
```

Line 23 — pattern scenario:
```erb
  <% if pat["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(pat["scenario"], pat["glossary"]) %></div><% end %>
```

Line 24 — pattern why:
```erb
  <div class="why-box"><strong>Why it exists:</strong> <%= glossary_wrap(pat["why"], pat["glossary"]) %></div>
```

Line 25 — pattern question:
```erb
  <div class="question"><%= glossary_wrap(pat["question"], pat["glossary"]) %></div>
```

Line 41 — challenge scenario:
```erb
    <% if ch["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(ch["scenario"], ch["glossary"]) %></div><% end %>
```

Line 42 — challenge question:
```erb
    <div class="question"><%= glossary_wrap(ch["question"], ch["glossary"]) %></div>
```

- [ ] **Step 5: Update `app/views/responses/_architecture_section.html.erb`**

Line 6 — architecture title:
```erb
  <div class="section-label">3 — Architecture Decision: <%= glossary_wrap(arch["title"], arch["glossary"]) %></div>
```

Line 7 — architecture scenario:
```erb
  <% if arch["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(arch["scenario"], arch["glossary"]) %></div><% end %>
```

Line 8 — architecture question:
```erb
  <div class="question"><%= glossary_wrap(arch["question"], arch["glossary"]) %></div>
```

Lines 9-12 — each architecture option, independently:
```erb
  <% if arch["options"].present? %>
    <ul class="arch-options">
      <% arch["options"].each do |opt| %><li><%= glossary_wrap(opt, arch["glossary"]) %></li><% end %>
    </ul>
  <% end %>
```

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS (the whole file, not just the new block — confirms nothing else in dashboard rendering broke)

- [ ] **Step 7: Run the full suite to check for regressions in history rendering**

Run: `bundle exec rspec spec/requests/history_spec.rb spec/requests/responses_spec.rb`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app/views/dashboard/_exercise.html.erb app/views/responses/_answered_sections.html.erb app/views/responses/_architecture_section.html.erb spec/requests/dashboard_spec.rb
git commit -m "Render glossary tooltip spans in exercise question/scenario/title fields"
```

---

## Task 5: Hover/tap interaction (CSS + inline JS)

**Files:**
- Modify: `app/views/layouts/application.html.erb`

**Interfaces:**
- Consumes: `<span class="gloss-term" data-definition="...">` elements produced by Task 4, wherever they appear on the page (dashboard live view, dashboard submitted view, every `/history` entry).
- Produces: no new interface for later tasks — this is the last task in the plan.

- [ ] **Step 1: Add CSS to the layout's `<style>` block**

In `app/views/layouts/application.html.erb`, add after the existing `details.hint` rules (after line 116, before the `.submit-row` rule):

```css
    .gloss-term { border-bottom: 1px dotted var(--muted); cursor: help; position: relative; }
    .gloss-term::after {
      content: attr(data-definition);
      position: absolute; left: 0; bottom: 100%; margin-bottom: .35rem;
      width: max-content; max-width: 16rem;
      background: #0d0d1a; border: 1px solid var(--border); border-radius: 6px;
      padding: .5rem .65rem; font-size: .8rem; line-height: 1.5; color: var(--text);
      white-space: normal; z-index: 10;
      display: none;
    }
    @media (hover: hover) and (pointer: fine) {
      .gloss-term:hover::after { display: block; }
    }
    .gloss-term.gloss-open::after { display: block; }
```

- [ ] **Step 2: Add the delegated tap/click handler**

In `app/views/layouts/application.html.erb`, add a new inline `<script>` block right after the existing `data-loading-form` script (after its closing `</script>` at line 293, before the `<%= yield :page_scripts %>` line):

```erb
  <%# Glossary term tooltips: hover reveals the definition on desktop (pure
      CSS, gated to real-hover pointers above); tap toggles it on touch,
      since hover has no equivalent there. One delegated listener handles
      every .gloss-term on the page regardless of which partial rendered it,
      matching the loading-form script's delegation just above. Cheap and
      unconditional — no CDN fetch, so no presence-gated dedup partial is
      needed the way syntax highlighting and Mermaid require. %>
  <script>
    (() => {
      document.addEventListener("click", (event) => {
        const term = event.target.closest(".gloss-term");
        document.querySelectorAll(".gloss-term.gloss-open").forEach((el) => {
          if (el !== term) el.classList.remove("gloss-open");
        });
        if (term) term.classList.toggle("gloss-open");
      });
    })();
  </script>
```

- [ ] **Step 3: Start the dev server and verify manually in the browser**

Run: `bin/dev` (or confirm it's already running)

In the browser (desktop viewport):
- Log in, view the dashboard with an exercise whose sections include glossary terms (use `rails console` to set a `DailyExercise#problem_set` with a `glossary` array on a section if none currently has one generated, or trigger a generation and check the result).
- Hover over a wrapped term: definition bubble appears above it.
- Move the mouse away: bubble disappears.
- Click a wrapped term: bubble stays visible (pinned); click elsewhere on the page: bubble closes.

In the browser (mobile/touch viewport — use Chrome DevTools device emulation or an actual phone):
- Tap a wrapped term: definition bubble appears.
- Tap the same term again: bubble closes.
- Tap a different wrapped term while one is open: the first closes, the second opens (only one open at a time).
- Tap elsewhere on the page: any open bubble closes.

Also verify on `/history`: a past entry with a glossary term shows the same hover/tap behavior as the live dashboard.

- [ ] **Step 4: Run the full test suite**

Run: `bundle exec rspec`
Expected: PASS (no regressions anywhere)

- [ ] **Step 5: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "Add hover/tap interaction for glossary term tooltips"
```

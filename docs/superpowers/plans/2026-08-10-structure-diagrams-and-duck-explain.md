# Structure Diagrams and "Explain It Simply" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a daily exercise carry an optional Mermaid diagram of the problem's structure, and let the rubber duck explain what a problem *is* without ever revealing how to solve it.

**Architecture:** Both changes extend infrastructure already in place. Change 1 adds an optional `diagram` key to the existing jsonb `problem_set` for three section kinds, bounds it on ingest the way `answer_scaffold` is bounded, and renders it through a new `shared/_mermaid_diagram` partial extracted verbatim from the architecture section's existing Mermaid setup. Change 2 revises `AiService::DUCK_SYSTEM_PROMPT` to distinguish explaining a problem from solving it, raises the duck's token ceiling, and adds a button that sends a server-owned pre-written message through the duck's existing endpoint.

**Tech Stack:** Rails 8.0.5, PostgreSQL, RSpec, Capybara + capybara-playwright-driver, Mermaid 11.4.1 via CDN (already in use), inline `<script>` tags (no JS framework — this app loads no Turbo/Stimulus).

**Spec:** `docs/superpowers/specs/2026-08-10-structure-diagrams-and-duck-explain-design.md`

## Global Constraints

- **No migration.** Neither change adds a column or a table. `diagram` is one more optional key in the existing jsonb `problem_set`; nothing about the duck is persisted.
- **No new dependencies.** Do not add a gem or an npm package. Mermaid is already loaded from `cdn.jsdelivr.net` at the exact pin `mermaid@11.4.1`; keep that pin.
- **The two changes must never share a commit.** Tasks 1–5 are Change 1 and Tasks 6–8 are Change 2. Committing within a change is encouraged; a commit that touches both is a plan violation.
- **Do not touch grading, concept tagging, mastery tiers, or `ConceptMastery`.** No changes to `DailyPlan`, `ConceptBucket`, `ConceptMastery`, or `normalize_concepts`.
- **Do not weaken or delete an existing assertion** to make a new test pass. Existing specs in `spec/requests/history_spec.rb` and `spec/services/ai_service_spec.rb` must keep passing unchanged.
- **`DUCK_SYSTEM_PROMPT` must keep the literal phrase `Socratic thinking partner`.** `FakeService#call` dispatches on `/Socratic thinking partner/` to decide which canned response to return (`app/services/fake_service.rb:179`). Removing that phrase makes `FakeService` raise on every duck call and breaks every duck system spec.
- **Provider output is untrusted.** Anything the model returns that reaches a view or a data attribute is bounded and sanitized at ingest, in `generate_exercise`, not at the call site.
- **Run the suite with** `bundle exec rspec`. System specs are excluded from the default unit run in CI via `--exclude-pattern "system/**/*_spec.rb"`; run them explicitly by path. Running them locally needs the one-time Playwright CLI install described at the top of `spec/support/system_test_helper.rb`.

## File Structure

**Change 1**

| File | Responsibility |
| --- | --- |
| `app/models/exercise_section.rb` | Add `diagrammable?` default (`false`) — the one place the diagram-bearing set is stated |
| `app/models/exercise_section/code_review.rb` | Override `diagrammable?` → `true` |
| `app/models/exercise_section/pattern.rb` | Override `diagrammable?` → `true` |
| `app/models/exercise_section/challenge.rb` | Override `diagrammable?` → `true` |
| `app/services/ai_service.rb` | `MAX_DIAGRAM_LENGTH`, `normalize_diagrams!`, schema `diagram` keys, prompt constraints moved to the shared instruction list |
| `app/views/shared/_mermaid_diagram.html.erb` | **Create.** Hidden container + once-per-page module script |
| `app/views/responses/_architecture_section.html.erb` | Switch to the shared partial; delete its inline copy |
| `app/views/dashboard/_exercise.html.erb` | Render the diagram pre-answer on code_review, pattern, challenge |
| `app/views/responses/_answered_sections.html.erb` | Same three renders for the read-only/history view |
| `app/services/fake_service.rb` | Carry a diagram on one section so specs exercise the render path |

**Change 2**

| File | Responsibility |
| --- | --- |
| `app/services/ai_service.rb` | Revised `DUCK_SYSTEM_PROMPT`, `DUCK_RESPONSE_MAX_TOKENS` 150 → 250, new `DUCK_EXPLAIN_REQUEST` |
| `app/views/shared/_duck_thread.html.erb` | "Explain this simply" button; `sendMessage`/`refreshCap` adjustments |
| `app/views/layouts/application.html.erb` | `.duck-form` gains `flex-wrap: wrap` for the third control |

---

## Task 1: `ExerciseSection.diagrammable?`

**Files:**
- Modify: `app/models/exercise_section.rb`
- Modify: `app/models/exercise_section/code_review.rb`
- Modify: `app/models/exercise_section/pattern.rb`
- Modify: `app/models/exercise_section/challenge.rb`
- Test: `spec/models/exercise_section_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `ExerciseSection.diagrammable?` — a class-level predicate on every section kind returning `true` or `false`. Tasks 2, 3, and 5 all read it. It is the only place the diagram-bearing set of kinds is stated.

- [ ] **Step 1: Write the failing test**

Add to `spec/models/exercise_section_spec.rb`, after the `.vocabulary_key` describe block:

```ruby
  describe ".diagrammable?" do
    # code_review, pattern, and challenge all describe a structure in prose or
    # in code already on screen, so a diagram of it restates what is visible.
    it "marks the kinds whose scenario carries a structure worth diagramming" do
      expect(described_class.find("code_review").diagrammable?).to be(true)
      expect(described_class.find("pattern").diagrammable?).to be(true)
      expect(described_class.find("challenge").diagrammable?).to be(true)
    end

    # security_review's task is finding one exploitable thing in a snippet, so
    # a diagram of that snippet's structure narrows the search. A parsons
    # problem's blocks ARE the structure — diagramming them is the answer.
    # Architecture already carries a diagram inside its reference block.
    it "excludes the kinds where a diagram would narrow the search or be the answer" do
      expect(described_class.find("security_review").diagrammable?).to be(false)
      expect(described_class.find("parsons_problem").diagrammable?).to be(false)
      expect(described_class.find("architecture").diagrammable?).to be(false)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb -e "diagrammable"`
Expected: FAIL with `NoMethodError: undefined method 'diagrammable?'`

- [ ] **Step 3: Write minimal implementation**

In `app/models/exercise_section.rb`, inside the `class << self` block, directly after the `improved_code?` method:

```ruby
    # Whether this kind's problem_set may carry a Mermaid `diagram` of the
    # structure its scenario describes. False by default: a diagram is only
    # safe pre-answer where it restates something already on screen, which is
    # not true of a kind whose whole task is finding what is hidden in a
    # snippet (security_review) or arranging the structure itself
    # (parsons_problem).
    def diagrammable?
      false
    end
```

In `app/models/exercise_section/code_review.rb`, replace the whole file:

```ruby
class ExerciseSection::CodeReview < ExerciseSection
  def self.diagrammable?
    true
  end
end
```

In `app/models/exercise_section/pattern.rb`, add inside the class, after `self.default_scaffold`:

```ruby
  def self.diagrammable?
    true
  end
```

In `app/models/exercise_section/challenge.rb`, add the same method inside the class body:

```ruby
  def self.diagrammable?
    true
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb`
Expected: PASS, all examples green.

- [ ] **Step 5: Commit**

```bash
git add app/models/exercise_section.rb app/models/exercise_section/ spec/models/exercise_section_spec.rb
git commit -m "Name which section kinds may carry a structure diagram

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 2: Bound the diagram on ingest

**Files:**
- Modify: `app/services/ai_service.rb` (add `MAX_DIAGRAM_LENGTH` near `RAW_SNIPPET_LIMIT`; add `normalize_diagrams!` beside `normalize_answer_scaffolds!` around line 1091; call it in `generate_exercise` around line 258)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `ExerciseSection.diagrammable?` from Task 1.
- Produces: `AiService#normalize_diagrams!(problem_set)` — private, mutates and returns the hash. `AiService::MAX_DIAGRAM_LENGTH` = `1_000`.

- [ ] **Step 1: Write the failing test**

Add to `spec/services/ai_service_spec.rb`, directly after the closing `end` of the `describe "#normalize_answer_scaffolds!"` block:

```ruby
  describe "#normalize_diagrams!" do
    it "keeps a usable diagram on a diagrammable section" do
      set = { "code_review" => { "diagram" => "  flowchart TD\n  A[Job] --> B[(DB)]  " } }

      expect(service.send(:normalize_diagrams!, set)["code_review"]["diagram"])
        .to eq("flowchart TD\n  A[Job] --> B[(DB)]")
    end

    # Dropped rather than truncated: a half a diagram is broken Mermaid, which
    # the renderer rejects anyway — dropping says the same thing without the
    # CDN round trip.
    it "drops an unusable diagram instead of persisting it" do
      [ "", "   ", nil, 42, [ "flowchart TD" ], "x" * (AiService::MAX_DIAGRAM_LENGTH + 1) ].each do |bad|
        set = { "pattern" => { "question" => "q", "diagram" => bad } }
        expect(service.send(:normalize_diagrams!, set)["pattern"]).not_to have_key("diagram")
      end
    end

    it "strips a diagram the model volunteered for a non-diagrammable section" do
      set = { "security_review" => { "diagram" => "flowchart TD\n  A --> B" } }

      expect(service.send(:normalize_diagrams!, set)["security_review"]).not_to have_key("diagram")
    end

    # Architecture's diagram lives at reference.diagram, not at the top level,
    # and predates this field — normalizing the top level must not reach into
    # it.
    it "leaves architecture's existing reference diagram untouched" do
      set = { "architecture" => { "reference" => { "diagram" => "flowchart TD\n  A --> B" } } }

      expect(service.send(:normalize_diagrams!, set)["architecture"]["reference"]["diagram"])
        .to eq("flowchart TD\n  A --> B")
    end

    it "leaves a section that carries no diagram alone" do
      set = { "pattern" => { "question" => "q" } }

      expect(service.send(:normalize_diagrams!, set)).to eq("pattern" => { "question" => "q" })
    end

    it "runs on generation, so a bad diagram never reaches a persisted problem set" do
      svc = double_class.new(canned_text: {
        "code_review" => { "question" => "q", "concept" => "n_plus_one", "diagram" => "x" * 5_000 },
        "pattern"     => { "question" => "q", "concept" => "memoization", "diagram" => "flowchart TD\n  A --> B" }
      }.to_json)

      problem_set = svc.generate_exercise(user)

      expect(problem_set["code_review"]).not_to have_key("diagram")
      expect(problem_set["pattern"]["diagram"]).to eq("flowchart TD\n  A --> B")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "normalize_diagrams"`
Expected: FAIL with `NameError: uninitialized constant AiService::MAX_DIAGRAM_LENGTH`

- [ ] **Step 3: Write minimal implementation**

In `app/services/ai_service.rb`, directly below the `RAW_SNIPPET_LIMIT = 500` constant:

```ruby
  # Upper bound on a section's Mermaid `diagram`. The prompt asks for at most
  # 8 nodes with short labels, which lands well under half this — so the bound
  # rejects runaway output without rejecting anything actually asked for.
  MAX_DIAGRAM_LENGTH = 1_000
```

In `generate_exercise`, add the call directly after `normalize_answer_scaffolds!(problem_set)`:

```ruby
    normalize_diagrams!(problem_set)
```

Add the method directly after `normalize_answer_scaffolds!` ends:

```ruby
  # Mermaid source is provider output rendered straight into an HTML data
  # attribute, so it is bounded here rather than trusted downstream. Anything
  # unusable is deleted, not repaired: the reader then takes the same "no
  # diagram" path every pre-diagram row already takes.
  #
  # Only the top-level key — architecture's diagram lives at
  # reference.diagram, predates this field, and is not touched.
  def normalize_diagrams!(problem_set)
    problem_set.each do |section_key, section_data|
      next unless section_data.is_a?(Hash)

      diagram = section_data["diagram"]
      usable  = ExerciseSection.find(section_key)&.diagrammable? &&
                diagram.is_a?(String) &&
                diagram.strip.length.between?(1, MAX_DIAGRAM_LENGTH)

      usable ? section_data["diagram"] = diagram.strip : section_data.delete("diagram")
    end
    problem_set
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS. Every pre-existing example in the file must still pass.

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Bound a section's diagram where it enters, like every scaffold

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 3: Ask for the diagram in the schema and the prompt

**Files:**
- Modify: `app/services/ai_service.rb` (`exercise_schema_for`, `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `MAX_DIAGRAM_LENGTH` and `normalize_diagrams!` from Task 2.
- Produces: no new methods. `exercise_schema_for` gains a `"diagram"` key on `code_review`, `pattern`, and `challenge`; `build_exercise_prompt` gains three shared instruction lines.

- [ ] **Step 1: Write the failing test**

Add to `spec/services/ai_service_spec.rb`, directly after the `describe "answer_scaffold in the generation schema"` block:

```ruby
  describe "diagram in the generation schema and prompt" do
    it "asks for a diagram on code_review, pattern, and the challenge third" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :challenge)

      expect(schema.scan('"diagram"').size).to eq(3)
    end

    # architecture's own reference diagram is the one occurrence here — its
    # top-level section never gains one.
    it "asks for no section-level diagram on a non-diagrammable third" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)

      expect(schema.scan('"diagram"').size).to eq(3)
      expect(schema).to include('"reference"')
    end

    it "asks for none on parsons_problem or security_review beyond the two always-present kinds" do
      %i[parsons_problem security_review].each do |third|
        schema = service.send(:exercise_schema_for, "ruby_rails", third: third)
        expect(schema.scan('"diagram"').size).to eq(2)
      end
    end

    # The syntax rules used to live in the architecture-only branch. They now
    # govern code_review and pattern, which are present every single day.
    it "states the Mermaid syntax constraints regardless of which third was rolled" do
      %i[challenge parsons_problem security_review architecture].each do |third|
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: third)

        expect(prompt).to include("flowchart TD")
        expect(prompt).to include("Maximum 8 nodes")
        expect(prompt).to match(/empty string/i)
      end
    end

    # The safety property: depicting a problem's shape must not reveal its
    # solution.
    it "forbids diagramming the fix rather than the scenario as written" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to match(/never diagram the fix/i)
      expect(prompt).to match(/never annotate a node as the problem/i)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "diagram in the generation schema"`
Expected: FAIL — `expected: 3, got: 0` on the first example.

- [ ] **Step 3: Write minimal implementation**

In `exercise_schema_for`, in the `code_review` block, add after the `"scenario"` line (mind the trailing comma on the line above):

```ruby
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "diagram":  "string — Mermaid source showing the structure this snippet describes, or an empty string if no diagram would help"
```

In the `pattern` block, add after its `"concept"` line:

```ruby
          "concept": "string — exactly one concept from the provided vocabulary",
          "diagram": "string — Mermaid source showing the structure this scenario describes, or an empty string if no diagram would help"
```

In the `else` (challenge) branch of `third_section`, add after its `"concept"` line:

```ruby
              "concept": "string — exactly one concept from the provided vocabulary",
              "diagram": "string — Mermaid source showing the structure this scenario describes, or an empty string if no diagram would help"
```

In `build_exercise_prompt`, **delete** these three lines from the `when :architecture` branch of `third_guidance`:

```
          - The architecture reference's "diagram" must be valid Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not.
          - Node labels must be short (a few words). Use quoted labels like A["Order service"] when a label contains spaces or punctuation.
          - Return an empty string for "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
```

and **replace** the remaining architecture diagram line with this narrower one (its subject is the reference diagram specifically, which the shared rules do not describe):

```
          - The architecture reference's "diagram" shows the STRUCTURE the decision is about — the services, data stores, and flows in tension — not a flowchart of how to decide.
```

Then add the shared rules to the main instruction list, directly after the `- answer_scaffold (pattern and architecture only): …` line and before `#{third_guidance}`:

```
      - Every "diagram" field is Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not. Node labels must be short (a few words); use quoted labels like A["Order service"] when a label contains spaces or punctuation.
      - A section's "diagram" depicts ONLY the structure its scenario or snippet already describes — the components, calls, state, and consumers as written, in the order they happen. Never diagram the fix, the corrected structure, or the answer, and never annotate a node as the problem, the bug, or the bottleneck. The engineer sees this BEFORE answering, so showing the shape of a problem must never reveal its solution.
      - Return an empty string for any "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS, including the pre-existing architecture prompt examples.

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Ask for a diagram of the problem, never of the fix

The Mermaid syntax rules move out of the architecture-only branch: they
now govern code_review and pattern, which are present every day.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 4: Extract `shared/_mermaid_diagram`

**Files:**
- Create: `app/views/shared/_mermaid_diagram.html.erb`
- Modify: `app/views/responses/_architecture_section.html.erb`
- Test: `spec/requests/history_spec.rb` (existing examples must pass unchanged)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the partial `shared/mermaid_diagram`, taking one local, `source:` (a String or nil). It renders nothing at all when `source` is blank. Task 5 renders it at four call sites.

This task is a pure refactor: behavior must be identical afterward. `spec/requests/history_spec.rb` already asserts the container renders, the script is emitted exactly once across multiple entries, and neither appears for an empty or missing diagram — that is the regression net.

- [ ] **Step 1: Run the existing specs to establish the green baseline**

Run: `bundle exec rspec spec/requests/history_spec.rb`
Expected: PASS. Note the count; it must be identical at the end of this task.

- [ ] **Step 2: Create the partial**

Create `app/views/shared/_mermaid_diagram.html.erb`:

```erb
<%# A hidden Mermaid container plus, once per page, the module script that
    renders every such container on it. Local: source (Mermaid text) — a blank
    source renders nothing at all, so call sites stay a single unconditional
    line and a pre-diagram row is indistinguishable from a section that chose
    not to have one. %>
<% if source.present? %>
  <div class="mermaid-diagram" data-diagram="<%= source %>"></div>
  <%# This partial renders up to three times per exercise and once per history
      entry, so the module script goes into the layout's shared :page_scripts
      region only on the FIRST call with a diagram — otherwise every container
      would ship its own identical copy. The script loops over every
      ".mermaid-diagram" on the page, so one copy still renders them all. %>
  <% unless @mermaid_diagram_script_emitted %>
    <% @mermaid_diagram_script_emitted = true %>
    <% content_for :page_scripts do %>
      <script type="module">
        // Loaded only on pages that actually have a diagram. The container starts
        // hidden and is revealed ONLY after a successful parse and render, which is
        // what makes every failure mode identical and harmless: malformed syntax, a
        // blocked CDN, an offline user, or a Mermaid change all produce "no diagram"
        // rather than a broken box. Nothing else on the page depends on this running.
        // securityLevel stays strict — the diagram source is model-generated.
        //
        // Version is pinned exactly (not "@11") so a Mermaid release can't change
        // behavior under us without a deliberate bump. SRI/CSP hardening for this
        // CDN import is a known gap, deliberately deferred to its own PR — enabling
        // a CSP here interacts with every inline script in this app.
        try {
          const mermaid = (await import("https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs")).default;
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });

          for (const el of document.querySelectorAll(".mermaid-diagram[data-diagram]:not([data-mermaid-done])")) {
            el.dataset.mermaidDone = "1";
            const src = el.dataset.diagram;
            try {
              await mermaid.parse(src);
              const { svg } = await mermaid.render("mmd-" + Math.random().toString(36).slice(2), src);
              el.innerHTML = svg;
              el.style.display = "block";
            } catch {
              el.remove();
            }
          }
        } catch {
          // CDN unreachable or module failed to load — containers simply stay hidden.
        }
      </script>
    <% end %>
  <% end %>
<% end %>
```

- [ ] **Step 3: Switch the architecture section to it**

In `app/views/responses/_architecture_section.html.erb`, replace these three lines:

```erb
        <% if arch.dig("reference", "diagram").present? %>
          <div class="mermaid-diagram" data-diagram="<%= arch.dig("reference", "diagram") %>"></div>
        <% end %>
```

with:

```erb
        <%= render "shared/mermaid_diagram", source: arch.dig("reference", "diagram") %>
```

Then **delete the entire trailing block** at the bottom of the file — everything from `<% if arch.dig("reference", "diagram").present? && !@architecture_diagram_script_emitted %>` through its final `<% end %>`, including the `content_for :page_scripts` script it contains. The file now ends with the closing `</div>` of the section.

- [ ] **Step 4: Run the existing specs to verify identical behavior**

Run: `bundle exec rspec spec/requests/history_spec.rb spec/requests/dashboard_spec.rb`
Expected: PASS with the same example count as Step 1. In particular these must still pass untouched:
- "renders a hidden diagram container and the mermaid module when a diagram is present"
- "renders no container and no mermaid script when the diagram is an empty string"
- "emits the ai_review autosave script and the mermaid module exactly once across multiple entries"

- [ ] **Step 5: Verify no stale reference to the old guard remains**

Run: `grep -rn "architecture_diagram_script_emitted" app spec`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add app/views/shared/_mermaid_diagram.html.erb app/views/responses/_architecture_section.html.erb
git commit -m "Give the Mermaid container and its script one home

A day whose third section isn't architecture still needs the module, so
the script can't keep living in the architecture partial.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 5: Render the diagram before answering

**Files:**
- Modify: `app/views/dashboard/_exercise.html.erb`
- Modify: `app/views/responses/_answered_sections.html.erb`
- Modify: `app/services/fake_service.rb`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `shared/mermaid_diagram` from Task 4; `normalize_diagrams!` from Task 2.
- Produces: no new interfaces. Adds `FakeService::EXERCISE_PROBLEM_SET["code_review"]["diagram"]`, a valid Mermaid string, which system specs can rely on.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/dashboard_spec.rb`, at the end of the file, inside the outermost `RSpec.describe` block:

```ruby
  describe "structure diagrams" do
    # Visible BEFORE answering, unlike improved_code — the whole point is
    # understanding what is being asked.
    it "renders a hidden container and the mermaid module on an unsubmitted set" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body).to include("mermaid-diagram")
      expect(response.body).to include("flowchart TD")
      expect(response.body).to include("mermaid@11.4.1")
      expect(response.body).to match(/securityLevel:\s*["']strict["']/)
    end

    it "renders one script for several diagrams across sections" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      ps["pattern"]["diagram"]     = "graph LR\n  A[Caller] --> B[Service]"
      ps["challenge"]["diagram"]   = "flowchart TD\n  A[Page] --> B[Count]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body.scan('class="mermaid-diagram"').size).to eq(3)
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end

    # The old-data guarantee: a row generated before this field existed must
    # render exactly as it did before.
    it "renders no container and no script for an exercise generated before diagrams existed" do
      create_exercise(problem_set: base_problem_set)
      login_as(user)

      get root_path

      expect(response.body).not_to include('class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    it "still shows the diagram on a submitted day, where the question is still on screen" do
      ps = base_problem_set
      ps["pattern"]["diagram"] = "graph LR\n  A[Caller] --> B[Service]"
      create_response(create_exercise(problem_set: ps))
      login_as(user)

      get root_path

      expect(response.body).to include("✓ Submitted")
      expect(response.body).to include("graph LR")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "structure diagrams"`
Expected: FAIL — the first example reports the body does not include `mermaid-diagram`.

- [ ] **Step 3: Write minimal implementation**

In `app/views/dashboard/_exercise.html.erb`, in the **code_review** section, add directly after the `<pre class="snippet">` line and before the `concept_reference_for` block:

```erb
      <%= render "shared/mermaid_diagram", source: cr["diagram"] %>
```

In the **pattern** section, add directly after the `<div class="question">` line:

```erb
      <%= render "shared/mermaid_diagram", source: pat["diagram"] %>
```

In the **challenge** section (the final `else` branch), add directly after the `starter_code` `<% end %>` and before the `concept_reference_for` block:

```erb
        <%= render "shared/mermaid_diagram", source: ch["diagram"] %>
```

In `app/views/responses/_answered_sections.html.erb`, add the same three renders at the same positions: after code_review's `<pre class="snippet">` line, after pattern's `<div class="question">` line, and after challenge's `starter_code` `<% end %>`.

In `app/services/fake_service.rb`, add a `"diagram"` key to `EXERCISE_PROBLEM_SET["code_review"]`, after its `"scenario"` line:

```ruby
      "scenario" => "a nightly loyalty-tier recalculation job",
      "diagram" => "flowchart TD\n  A[\"Nightly job\"] --> B[\"loyalty_tier\"]\n  B --> C[(\"orders\")]"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/history_spec.rb spec/services/fake_service_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the whole unit suite before closing out Change 1**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS, no failures.

- [ ] **Step 6: Run the system specs, which now render a FakeService diagram**

Run: `bundle exec rspec spec/system`
Expected: PASS. (Needs the one-time Playwright CLI install noted at the top of `spec/support/system_test_helper.rb`.)

- [ ] **Step 7: Commit**

```bash
git add app/views/dashboard/_exercise.html.erb app/views/responses/_answered_sections.html.erb app/services/fake_service.rb spec/requests/dashboard_spec.rb
git commit -m "Show a problem's shape before asking someone to reason about it

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 6: Teach the duck to explain without solving

**Files:**
- Modify: `app/services/ai_service.rb` (`DUCK_RESPONSE_MAX_TOKENS` and `DUCK_SYSTEM_PROMPT`, around lines 78–99; add `DUCK_EXPLAIN_REQUEST`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: nothing from Change 1.
- Produces: `AiService::DUCK_EXPLAIN_REQUEST` — a frozen String, the pre-written message Task 7's button sends. `AiService::DUCK_RESPONSE_MAX_TOKENS` becomes `250`.

**Reminder:** the revised prompt must keep the literal phrase `Socratic thinking partner` (see Global Constraints).

- [ ] **Step 1: Write the failing test**

Add to `spec/services/ai_service_spec.rb`, inside the existing `describe "#duck_response"` block, after the "the system prompt never permits stating the answer or writing corrected code" example:

```ruby
    it "allows explaining what the problem is, directly and in plain words" do
      svc = duck_spy_class.new(canned_text: "Think of it like a shopping list you rewrite on every trip.")

      svc.duck_response(user, exercise, section: "code_review",
                        message: AiService::DUCK_EXPLAIN_REQUEST, thread: [])

      expect(svc.last_system).to match(/understanding the problem/i)
      expect(svc.last_system).to match(/answer these directly/i)
      expect(svc.last_system).to match(/analogy/i)
    end

    # The boundary is a judgement the model makes per message, so the prompt
    # has to give it instances to classify against, a rule for the mixed case,
    # and a tie-break — not just a definition.
    it "still forbids solving, and says what to do when the two are mixed or unclear" do
      svc = duck_spy_class.new(canned_text: "A guiding question.")

      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_system).to match(/solving the problem/i)
      expect(svc.last_system).to match(/what's the bug\?/i)
      expect(svc.last_system).to match(/mixes both/i)
      expect(svc.last_system).to match(/cannot tell which kind it is, treat it as kind 2/i)
    end

    it "keeps the FakeService dispatch phrase, which every duck system spec routes on" do
      expect(AiService::DUCK_SYSTEM_PROMPT).to include("Socratic thinking partner")
    end

    it "asks for a plain-language explanation rather than the answer" do
      expect(AiService::DUCK_EXPLAIN_REQUEST).to match(/plain language/i)
      expect(AiService::DUCK_EXPLAIN_REQUEST).not_to match(/answer|fix|solve/i)
    end

    # An explanation plus a concrete analogy does not fit in 150 tokens. The
    # ceiling stays a budget, not an enforcement mechanism — the prompt is
    # what actually withholds the answer.
    it "gives a reply room for an explanation while staying far below a review's ceiling" do
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to eq(250)
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to be < ClaudeService::MAX_TOKENS
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "duck_response"`
Expected: FAIL with `NameError: uninitialized constant AiService::DUCK_EXPLAIN_REQUEST`

- [ ] **Step 3: Write minimal implementation**

In `app/services/ai_service.rb`, replace the `DUCK_RESPONSE_MAX_TOKENS` comment and constant with:

```ruby
  # Cost and length control for #duck_response. 250 tokens fits both shapes the
  # system prompt asks for: a 1-3 sentence guiding question, and a plain-language
  # explanation with a concrete analogy — the latter does not fit in the 150 this
  # started at. It remains a budget, not an enforcement mechanism: a short fix
  # fits in 250 tokens too, so DUCK_SYSTEM_PROMPT's rules are still the only
  # thing actually asking the model not to give answers.
  #
  # Deliberately one ceiling for every duck reply rather than a higher one for
  # explain-requests. The server cannot know which kind a message is until the
  # model has answered it, so branching would mean trusting a client-declared
  # flag that any client could set on every request — a per-type ceiling that
  # does not hold is worse than one honest number.
  # Deliberately distinct from ClaudeService::MAX_TOKENS, which is sized for
  # full review generation.
  DUCK_RESPONSE_MAX_TOKENS = 250

  # The message the "Explain this simply" button sends on the user's behalf.
  # Server-owned so its wording lives beside the prompt it is tuned against: it
  # names the exercise rather than the answer, so it reads as a kind-1 request
  # under DUCK_SYSTEM_PROMPT without the prompt having to recognize it
  # specially. It reaches the endpoint as an ordinary message and counts
  # against the same turn cap as one.
  DUCK_EXPLAIN_REQUEST = "Explain what this exercise is asking, in plain language."
```

Replace `DUCK_SYSTEM_PROMPT` entirely with:

```ruby
  DUCK_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are a Socratic thinking partner helping an engineer work through a
    problem they have NOT yet submitted or been graded on.

    Every message they send is one of two kinds. Decide which before replying.

    1. UNDERSTANDING THE PROBLEM — they are asking what the exercise means, what
       a term or a piece of the snippet does, or for a plainer restatement of the
       question. Examples: "what is this even asking?", "what does memoization
       mean?", "explain this scenario simply", "what does this line do?"
       Answer these DIRECTLY and simply: plain words, one concrete everyday
       analogy if it helps, no jargon. Describe only what is already on their
       screen — the situation as written, the vocabulary, the shape of the
       question. Explaining what a problem IS is always allowed.

    2. SOLVING THE PROBLEM — they are asking for the fix, the answer, corrected
       code, which option to pick, or what is wrong with the snippet. Examples:
       "what's the bug?", "how do I fix this?", "which option is right?", "just
       tell me the answer", "is my approach correct?"
       Never comply. Never state the correct answer, the specific fix, or write
       corrected or complete code — not even as an illustrative example. Respond
       with a single guiding question that helps them find it themselves.

    When a message mixes both ("what does this method do, and what's wrong with
    it?"), explain the first part and answer the second with a guiding question.
    When you genuinely cannot tell which kind it is, treat it as kind 2.

    Keep it short: 1-3 sentences for a guiding question, up to 4 for an
    explanation. No preamble.
  PROMPT
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb spec/services/fake_service_spec.rb`
Expected: PASS. The pre-existing example asserting `/never state the correct answer/i`, `/complete code/i`, and `/1-3 sentences/i` must still pass against the new wording — it does, unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Let the duck explain a problem without ever solving it

Answering \"what is this even asking?\" with another Socratic question is
unhelpful to someone who can't yet reason about the problem at all.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 7: The "Explain this simply" button

**Files:**
- Modify: `app/views/shared/_duck_thread.html.erb`
- Modify: `app/views/layouts/application.html.erb` (the `.duck-form` rule, line 97)
- Test: `spec/system/duck_thread_spec.rb`

**Interfaces:**
- Consumes: `AiService::DUCK_EXPLAIN_REQUEST` from Task 6.
- Produces: a `.duck-explain` button inside `.duck-form`, carrying its message in `data-message`. No new endpoint and no server branch — it posts through the existing `sendMessage`.

- [ ] **Step 1: Write the failing test**

Add to `spec/system/duck_thread_spec.rb`, before the final "does not render the duck thread once the set is submitted" example:

```ruby
  # A user reaches for Explain precisely because they don't know what to type,
  # so the empty input box is the normal case, not an edge case.
  it "sends the pre-written explanation request with an empty input box" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      expect(duck.find(".duck-input").value).to eq("")
      duck.find(".duck-explain").click

      expect(duck).to have_selector(".duck-turn.duck-user", text: AiService::DUCK_EXPLAIN_REQUEST, wait: 10)
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(DailyResponse.count).to eq(0)
    end
  end

  # A button that looks live and silently swallows the click is worse than one
  # that is plainly unavailable.
  it "disables Explain at the cap rather than letting it fail silently" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times do |i|
        ask(duck, "stuck #{i}")
        expect(duck).to have_css(".duck-turn.duck-user", count: i + 1, wait: 10)
      end

      expect(duck.find(".duck-explain")).to be_disabled
      expect(duck.find(".duck-send")).to be_disabled
      expect(duck.find(".duck-input")).to be_disabled

      # Deliberately not clicked: Playwright's click auto-waits for the element
      # to become actionable and would time out on a disabled button rather
      # than reporting the no-op this asserts. "Visibly unavailable" is the
      # whole property — the click itself is covered in manual verification.

      # Clear restores it along with the rest of the controls.
      duck.find(".duck-clear").click
      expect(duck.find(".duck-explain")).not_to be_disabled
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/system/duck_thread_spec.rb -e "pre-written explanation request"`
Expected: FAIL — Capybara cannot find `.duck-explain`.

- [ ] **Step 3: Add the button to the markup**

In `app/views/shared/_duck_thread.html.erb`, replace the `.duck-form` div with:

```erb
    <div class="duck-form">
      <input type="text" class="duck-input" placeholder="What are you stuck on?">
      <button type="button" class="btn btn-ghost btn-sm duck-send">Ask</button>
      <%# Sends a fixed message on the user's behalf so getting an explanation
          doesn't depend on knowing how to phrase one. It goes through the same
          endpoint as any other turn and counts against the same cap. %>
      <button type="button" class="btn btn-ghost btn-sm duck-explain" data-message="<%= AiService::DUCK_EXPLAIN_REQUEST %>">Explain this simply</button>
      <button type="button" class="btn btn-ghost btn-sm duck-clear">Clear</button>
    </div>
```

- [ ] **Step 4: Wire it into the existing send path**

In the same file's inline script, make four edits.

Add `explain` to the element lookups, after the `send` line:

```javascript
    const send    = box.querySelector(".duck-send");
    const explain = box.querySelector(".duck-explain");
```

Change `refreshCap` to disable it too. Replace its body's three assignments with:

```javascript
    const capped = userTurnCount(box) >= MAX_TURNS;
    input.disabled = capped;
    send.disabled = capped;
    explain.disabled = capped;
```

Note `refreshCap` is defined above the `forEach` and takes `box`, so look the button up from `box` there:

```javascript
  const refreshCap = (box) => {
    const input = box.querySelector(".duck-input");
    const send = box.querySelector(".duck-send");
    const explain = box.querySelector(".duck-explain");
    const status = box.querySelector(".duck-status");
    const capped = userTurnCount(box) >= MAX_TURNS;
    input.disabled = capped;
    send.disabled = capped;
    explain.disabled = capped;
    if (capped) {
      status.textContent =
        `You've used all ${MAX_TURNS} messages for this section — clear the conversation to keep going.`;
    }
  };
```

Change `sendMessage` to take an optional explicit message. Replace its first three lines:

```javascript
    const sendMessage = async (explicitMessage) => {
      // An explicit message (the Explain button's) bypasses the input entirely:
      // the empty box is the normal case for it, not a reason to do nothing.
      const message = explicitMessage || input.value.trim();
      if (!message || send.disabled) return;
```

and, in its success branch, clear the input only when the message came from it:

```javascript
        box.duckThread.push({ role: "user", content: message }, { role: "assistant", content: data.answer });
        renderTurns(box);
        if (!explicitMessage) input.value = "";
        status.textContent = "";
```

Add the listener beside the existing `send` one:

```javascript
    send.addEventListener("click", () => sendMessage());
    explain.addEventListener("click", () => sendMessage(explain.dataset.message));
```

Note the `send` listener changes from `sendMessage` to `() => sendMessage()`: passing the function directly would hand the click event in as `explicitMessage`.

- [ ] **Step 5: Let the third control wrap**

In `app/views/layouts/application.html.erb`, replace the `.duck-form` rule:

```css
    .duck-form { display: flex; gap: .5rem; flex-wrap: wrap; }
```

- [ ] **Step 6: Run the system specs to verify they pass**

Run: `bundle exec rspec spec/system/duck_thread_spec.rb`
Expected: PASS, all examples including the four pre-existing ones.

- [ ] **Step 7: Commit**

```bash
git add app/views/shared/_duck_thread.html.erb app/views/layouts/application.html.erb spec/system/duck_thread_spec.rb
git commit -m "Ask for the explanation without knowing how to phrase it

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 8: Confirm the explain message is an ordinary turn

**Files:**
- Test: `spec/requests/responses_duck_thread_spec.rb`

**Interfaces:**
- Consumes: `AiService::DUCK_EXPLAIN_REQUEST` from Task 6.
- Produces: nothing. This task adds coverage only — the point is proving there is no server-side special case, so **no application code changes here.** If a step in this task tempts you to edit a controller, the implementation is wrong.

- [ ] **Step 1: Write the test**

Add to `spec/requests/responses_duck_thread_spec.rb`, at the end of the outermost describe block:

```ruby
  describe "the pre-written explanation request" do
    # It travels the same path as anything the user types: same endpoint, same
    # gate, same cap, no branch anywhere on the server.
    it "is handled as an ordinary message with no special-casing" do
      create_exercise_for(user)
      fake = stub_answer("Think of it like recounting a shopping list on every trip.")
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: [] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake).to have_received(:duck_response).with(
        user, an_instance_of(DailyExercise),
        section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: []
      )
      expect(DailyResponse.count).to eq(0)
    end

    it "counts against the same turn cap as a typed message" do
      create_exercise_for(user)
      stub_answer
      login_as(user)

      thread = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION) do |i|
        [ { role: "user", content: "q#{i}" }, { role: "assistant", content: "a#{i}" } ]
      end.flatten

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: thread }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/used all/i)
    end

    it "is refused once the set is submitted, like any other duck message" do
      exercise = create_exercise_for(user)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "done" }, submitted_at: Time.current)
      stub_answer
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: [] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/before you submit/i)
    end
  end
```

- [ ] **Step 2: Run the test — it should pass immediately**

Run: `bundle exec rspec spec/requests/responses_duck_thread_spec.rb`
Expected: PASS with no application change. A failure here means Task 7 introduced a server-side branch that should not exist; remove the branch rather than adapting the test.

- [ ] **Step 3: Run the full unit suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS.

- [ ] **Step 4: Run the full system suite**

Run: `bundle exec rspec spec/system`
Expected: PASS.

- [ ] **Step 5: Verify no migration was generated**

Run: `git status --porcelain db/`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add spec/requests/responses_duck_thread_spec.rb
git commit -m "Pin the explain request to the ordinary duck path

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Manual browser verification

After Task 8, confirm in Chrome against a `provider: "fake"` user on a weekday (`bin/dev`, then log in via the magic link that `letter_opener` opens):

1. **Diagram renders pre-answer.** The dashboard's Code Review section shows a rendered SVG flowchart above the answer box, before anything is typed or submitted.
2. **Degradation is invisible.** In DevTools, block `cdn.jsdelivr.net` and reload. No empty box, no broken frame, no console-visible breakage in the page — the diagram is simply absent and everything else works.
3. **Explain with an empty input box.** Open the duck, click "Explain this simply" without typing. The pre-written message appears as a user turn and a reply follows.
4. **Explain at the cap.** Send 6 messages, then confirm the Explain button is visibly disabled. Click it and confirm nothing happens — no turn is added, no status change, no console error. (The automated spec asserts the disabled state but cannot click it; Playwright would time out waiting for actionability rather than observing the no-op.) Click Clear and confirm the button becomes usable again.

## Notes for the implementer

- **Why the diagram shows before answering.** This is the opposite of `improved_code`, which is hidden until a review exists. The diagram's entire purpose is comprehension of the question, so hiding it until after submission would defeat it. The safety property that makes this acceptable is that the diagram depicts only what the scenario already says — which is why the prompt constraint in Task 3 is not optional polish.
- **Why unusable provider output is deleted rather than repaired.** Both `normalize_diagrams!` and the existing `normalize_answer_scaffolds!` delete. A repaired value is a new shape nobody tested; a deleted one puts the reader on the well-trodden path every historical row already takes.
- **Why Task 8 changes no application code.** The value of the Explain button is that it is not a feature — it is a pre-filled message. If it acquires a server-side branch, it acquires its own failure modes, its own cap interaction, and its own tests, which is precisely what folding it into the duck was meant to avoid.

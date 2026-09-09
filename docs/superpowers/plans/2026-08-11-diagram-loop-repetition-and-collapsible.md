# Diagram Loop-Repetition Instruction + Collapsible Diagrams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Add one instruction to the diagram-generation prompt so a diagram whose underlying code repeats (a loop, `each`, etc.) shows that repetition instead of rendering as an indistinguishable flat one-time chain. (2) Make every structure diagram a closed-by-default `<details>` disclosure, matching the app's existing collapsible-section pattern, with a required knock-on fix to the failure-cleanup JS and one call-site exception for architecture's already-nested diagram.

**Architecture:** Two independent changes sharing no code: Part 1 edits a prompt string and adds prompt-text specs; Part 2 edits one shared view partial (plus one call site and shared layout CSS/JS) and extends existing request specs. Full rationale: `docs/superpowers/specs/2026-08-11-diagram-loop-repetition-and-collapsible-design.md`.

**Tech Stack:** Ruby on Rails 8, RSpec, ERB views, vanilla inline JS (ES module), Mermaid.js (CDN).

## Global Constraints

- No change to which section kinds get diagrams, the node-count/syntax constraints (`flowchart TD`/`graph LR` only, max 8 nodes, no styling directives), or anything else from the original structure-diagrams spec (`docs/superpowers/specs/2026-08-10-structure-diagrams-and-duck-explain-design.md`) — Part 1 is one additional instruction, not a redesign.
- No migration, no schema change.
- Part 1 verification is prompt-text assertions only — no live provider calls, no regenerating real examples.
- Part 2 verification matches this codebase's existing test depth for diagrams: request-spec HTML/text assertions only, no new system spec.
- Full design context: `docs/superpowers/specs/2026-08-11-diagram-loop-repetition-and-collapsible-design.md`.

---

## Task 1: Loop-repetition prompt instruction

**Files:**
- Modify: `app/services/ai_service.rb:930-932` (inside `#build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb` (new examples inside the existing `describe "diagram in the generation schema and prompt" do ... end` block, which currently ends after the `"forbids diagramming the fix..."` example at line 797)

**Interfaces:**
- Consumes: nothing new — this is a pure string edit inside an existing private method.
- Produces: nothing consumed by other tasks. Task 2 is fully independent.

- [ ] **Step 1: Write the failing tests**

Add these two examples to `spec/services/ai_service_spec.rb`, immediately after the existing `"forbids diagramming the fix rather than the scenario as written"` example (which ends at line 797, just before the `describe` block's closing `end` on line 798):

```ruby
    it "instructs the diagram to show repetition when a loop wraps the flow" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to include("repeated invocation that wraps the flow")
      expect(prompt).to include("per-item cardinality")
      expect(prompt).to include("once per customer")
    end

    it "does not force a loop cue on snippets without one" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to include("Do not manufacture a loop or cardinality label when the snippet has none")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs the diagram to show repetition" -e "does not force a loop cue"`
Expected: FAIL — both `include` assertions fail, since none of that text exists in the prompt yet.

- [ ] **Step 3: Add the new instruction**

In `app/services/ai_service.rb`, change lines 930-932 from:

```ruby
      - Every "diagram" field is Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not. Node labels must be short (a few words); use quoted labels like A["Order service"] when a label contains spaces or punctuation.
      - A section's "diagram" depicts ONLY the structure its scenario or snippet already describes — the components, calls, state, and consumers as written, in the order they happen. Never diagram the fix, the corrected structure, or the answer, and never annotate a node as the problem, the bug, or the bottleneck. The engineer sees this BEFORE answering, so showing the shape of a problem must never reveal its solution.
      - Return an empty string for any "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
```

to:

```ruby
      - Every "diagram" field is Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not. Node labels must be short (a few words); use quoted labels like A["Order service"] when a label contains spaces or punctuation.
      - A section's "diagram" depicts ONLY the structure its scenario or snippet already describes — the components, calls, state, and consumers as written, in the order they happen. Never diagram the fix, the corrected structure, or the answer, and never annotate a node as the problem, the bug, or the bottleneck. The engineer sees this BEFORE answering, so showing the shape of a problem must never reveal its solution.
      - When the snippet or scenario contains a loop, iteration, or repeated invocation that wraps the flow being diagrammed (e.g. a method called inside `each`/`for`/`while`), the diagram must make that repetition visible — either an explicit loop/iteration node in the call's path, or a labeled edge stating the per-item cardinality (e.g. "once per customer", "for each order"). A flat one-time call chain is not accurate for code that actually repeats. Do not manufacture a loop or cardinality label when the snippet has none.
      - Return an empty string for any "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs the diagram to show repetition" -e "does not force a loop cue"`
Expected: PASS (2 examples, 0 failures)

- [ ] **Step 5: Run the full AiService spec file to check for regressions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS, no new failures. In particular `"states the Mermaid syntax constraints regardless of which third was rolled"` (line 780) and `"forbids diagramming the fix..."` (line 792) must still pass — they assert on substrings unaffected by this insertion.

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Instruct the diagram prompt to show loop repetition instead of a flat chain"
```

---

## Task 2: Collapsible diagrams

**Files:**
- Modify: `app/views/shared/_mermaid_diagram.html.erb` (full rewrite of markup + script)
- Modify: `app/views/responses/_architecture_section.html.erb:24` (one call-site argument)
- Modify: `app/views/layouts/application.html.erb` (CSS: drop `display: none` from `.mermaid-diagram`)
- Test: `spec/requests/dashboard_spec.rb:923-984` (the `"structure diagrams"` describe block)
- Test: `spec/requests/history_spec.rb:131-166` (the diagram examples inside the architecture describe block)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: a new `collapsible` local on `shared/_mermaid_diagram` (default `true`; `_architecture_section.html.erb` passes `collapsible: false`). No other file references this partial's locals, so no other caller needs updating.

- [ ] **Step 1: Write the failing tests**

In `spec/requests/dashboard_spec.rb`, replace the entire `describe "structure diagrams" do ... end` block (lines 923-984, the four examples between `describe "structure diagrams" do` and its closing `end`) with:

```ruby
  describe "structure diagrams" do
    # Visible BEFORE answering, unlike improved_code — the whole point is
    # understanding what is being asked.
    it "renders a collapsed disclosure and the mermaid module on an unsubmitted set" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body).to include('<details class="ref">')
      expect(response.body).to include("🗺️ Structure diagram")
      expect(response.body).to include("mermaid-diagram")
      expect(response.body).to include("flowchart TD")
      expect(response.body).to include("mermaid@11.4.1")
      expect(response.body).to match(/securityLevel:\s*["']strict["']/)
    end

    it "renders one script for several diagrams across sections, each in its own disclosure" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      ps["pattern"]["diagram"]     = "graph LR\n  A[Caller] --> B[Service]"
      ps["challenge"]["diagram"]   = "flowchart TD\n  A[Page] --> B[Count]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body.scan('<details class="ref">').size).to eq(3)
      expect(response.body.scan('class="mermaid-diagram"').size).to eq(3)
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end

    # The old-data guarantee: a row generated before this field existed must
    # render exactly as it did before.
    it "renders no disclosure, no container, and no script for an exercise generated before diagrams existed" do
      create_exercise(problem_set: base_problem_set)
      login_as(user)

      get root_path

      expect(response.body).not_to include('class="mermaid-diagram"')
      expect(response.body).not_to include("🗺️ Structure diagram")
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    # The submitted day renders a different partial than the unsubmitted one
    # (responses/_answered_sections, shared with history), so every
    # diagrammable section needs asserting here too — covering only one of
    # them would let the other two renders be deleted silently.
    it "still shows every section's diagram, each collapsed, on a submitted day, where the questions are still on screen" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      ps["pattern"]["diagram"]     = "graph LR\n  A[Caller] --> B[Service]"
      ps["challenge"]["diagram"]   = "flowchart TD\n  A[Page] --> B[Count]"
      create_response(create_exercise(problem_set: ps))
      login_as(user)

      get root_path

      expect(response.body).to include("✓ Submitted")
      expect(response.body).to include("graph LR")
      expect(response.body.scan('<details class="ref">').size).to eq(3)
      expect(response.body.scan('class="mermaid-diagram"').size).to eq(3)
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end
  end
```

In `spec/requests/history_spec.rb`, replace the three examples from `"renders a hidden diagram container..."` (line 131) through `"renders no container and no mermaid script for an exercise generated before diagrams existed"` (ending line 166) with:

```ruby
    it "renders a collapsed disclosure and the mermaid module when a diagram is present" do
      architecture_session(diagram: "flowchart TD\n  A[Client] --> B[API]")
      login_as(user)
      get history_path

      # Architecture's diagram is collapsible: false (it already lives inside
      # its own "Reference — tradeoffs" <details class="ref">), so it must
      # NOT get its own nested disclosure — only the outer one.
      expect(response.body.scan('<details class="ref">').size).to eq(1)
      expect(response.body).not_to include("🗺️ Structure diagram")
      expect(response.body).to include("mermaid-diagram")
      expect(response.body).to include("flowchart TD")
      expect(response.body).to include("cdn.jsdelivr.net")
      expect(response.body).to match(/securityLevel:\s*["']strict["']/)
    end

    it "renders no container and no mermaid script when the diagram is an empty string" do
      architecture_session(diagram: "")
      login_as(user)
      get history_path

      # The .mermaid-diagram CSS rule itself is global (defined once in the
      # layout's <style> block, like every other section style), so it is
      # present on every page regardless of content. What must NOT appear is
      # an actual container element or the mermaid script.
      expect(response.body).not_to include('<div class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    it "renders no container and no mermaid script for an exercise generated before diagrams existed" do
      architecture_session(diagram: nil)
      login_as(user)
      get history_path

      # The .mermaid-diagram CSS rule itself is global (defined once in the
      # layout's <style> block, like every other section style), so it is
      # present on every page regardless of content. What must NOT appear is
      # an actual container element or the mermaid script.
      expect(response.body).not_to include('<div class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "structure diagrams"`
Expected: FAIL — no `<details class="ref">` or `"🗺️ Structure diagram"` exists yet, so the new/changed assertions in all four examples fail.

Run: `bundle exec rspec spec/requests/history_spec.rb -e "renders a collapsed disclosure and the mermaid module when a diagram is present"`
Expected: FAIL — same reason.

- [ ] **Step 3: Rewrite the shared partial**

Replace the entire contents of `app/views/shared/_mermaid_diagram.html.erb` with:

```erb
<%# A Mermaid container plus, once per page, the module script that renders
    every such container on it. Local: source (Mermaid text) — a blank
    source renders nothing at all, so call sites stay a single unconditional
    line and a pre-diagram row is indistinguishable from a section that chose
    not to have one. Local: collapsible (default true) — wraps the container
    in its own closed <details>, matching shared/_concept_reference.html.erb's
    dropdown. Architecture's diagram passes collapsible: false since it
    already renders inside its own <details class="ref"> (the "Reference —
    tradeoffs" box) — a second nested disclosure there would turn a one-click
    reveal into two. %>
<% if source.present? %>
  <% if local_assigns.fetch(:collapsible, true) %>
    <details class="ref">
      <summary>🗺️ Structure diagram</summary>
      <div class="mermaid-diagram" data-diagram="<%= source %>"></div>
    </details>
  <% else %>
    <div class="mermaid-diagram" data-diagram="<%= source %>"></div>
  <% end %>
  <%# This partial renders up to three times per exercise and once per history
      entry, so the module script goes into the layout's shared :page_scripts
      region only on the FIRST call with a diagram — otherwise every container
      would ship its own identical copy. The script loops over every
      ".mermaid-diagram" on the page, so one copy still renders them all. %>
  <% unless @mermaid_diagram_script_emitted %>
    <% @mermaid_diagram_script_emitted = true %>
    <% content_for :page_scripts do %>
      <script type="module">
        // Loaded only on pages that actually have a diagram. The container lives
        // inside a closed <details> for every call site except architecture's,
        // which is already nested inside its own — so visibility is the
        // disclosure's job, not this script's. A failed parse/render removes the
        // WHOLE <details> ancestor, not just the diagram div — same for a CDN or
        // module load failure below, which can leave several diagrams pending at
        // once — so a bad diagram never leaves behind an empty, clickable
        // disclosure with nothing inside. Nothing else on the page depends on
        // this running. securityLevel stays strict — the diagram source is
        // model-generated.
        //
        // Version is pinned exactly (not "@11") so a Mermaid release can't change
        // behavior under us without a deliberate bump. SRI/CSP hardening for this
        // CDN import is a known gap, deliberately deferred to its own PR — enabling
        // a CSP here interacts with every inline script in this app.
        const pending = () => document.querySelectorAll(".mermaid-diagram[data-diagram]:not([data-mermaid-done])");
        try {
          const mermaid = (await import("https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs")).default;
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });

          for (const el of pending()) {
            el.dataset.mermaidDone = "1";
            const src = el.dataset.diagram;
            try {
              await mermaid.parse(src);
              const { svg } = await mermaid.render("mmd-" + Math.random().toString(36).slice(2), src);
              el.innerHTML = svg;
            } catch {
              (el.closest("details") || el).remove();
            }
          }
        } catch {
          // CDN unreachable or module failed to load before any diagram could be
          // parsed — remove every pending disclosure so none are left clickable
          // with nothing inside, matching the per-diagram failure path above.
          for (const el of pending()) (el.closest("details") || el).remove();
        }
      </script>
    <% end %>
  <% end %>
<% end %>
```

- [ ] **Step 4: Pass `collapsible: false` at the architecture call site**

In `app/views/responses/_architecture_section.html.erb`, change line 24 from:

```erb
        <%= render "shared/mermaid_diagram", source: arch.dig("reference", "diagram") %>
```

to:

```erb
        <%= render "shared/mermaid_diagram", source: arch.dig("reference", "diagram"), collapsible: false %>
```

- [ ] **Step 5: Drop the now-redundant CSS default**

In `app/views/layouts/application.html.erb`, change line 143 from:

```css
    .mermaid-diagram { display: none; margin-top: .9rem; overflow-x: auto; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: .75rem; }
```

to:

```css
    .mermaid-diagram { margin-top: .9rem; overflow-x: auto; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: .75rem; }
```

(A closed `<details>` already hides its descendants regardless of their own `display` value, and architecture's `collapsible: false` case sits inside its own outer `<details>`, so this default-hide is redundant everywhere the container now appears.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "structure diagrams"`
Expected: PASS (4 examples, 0 failures)

Run: `bundle exec rspec spec/requests/history_spec.rb`
Expected: PASS, 0 failures (run the full file — architecture-diagram examples live inside a larger describe block with siblings that must keep passing)

- [ ] **Step 7: Run both full spec files to check for regressions**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/history_spec.rb`
Expected: PASS, no new failures.

- [ ] **Step 8: Commit**

```bash
git add app/views/shared/_mermaid_diagram.html.erb app/views/responses/_architecture_section.html.erb app/views/layouts/application.html.erb spec/requests/dashboard_spec.rb spec/requests/history_spec.rb
git commit -m "Make structure diagrams a collapsed-by-default disclosure"
```

---

## Final check

- [ ] Run the full non-system suite once more: `bundle exec rspec --exclude-pattern "spec/system/**/*_spec.rb"`
- [ ] Run rubocop on every touched file: `bundle exec rubocop app/services/ai_service.rb app/views/shared/_mermaid_diagram.html.erb app/views/responses/_architecture_section.html.erb app/views/layouts/application.html.erb spec/services/ai_service_spec.rb spec/requests/dashboard_spec.rb spec/requests/history_spec.rb`
- [ ] Manual sanity check (optional but recommended given this touches live JS behavior rubocop/RSpec can't see): run `bin/dev`, log in as a fake-provider user, open a set with a diagram, confirm the disclosure is closed by default, opens on click, and shows the rendered SVG.

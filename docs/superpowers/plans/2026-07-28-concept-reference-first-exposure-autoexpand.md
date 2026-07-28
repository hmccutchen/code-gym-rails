# ConceptReference First-Exposure Auto-Expand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-expand the `ConceptReference` `<details>` dropdown when a user is answering a section whose concept they have never been exposed to before (across their whole submitted history), while leaving every other case (repeat exposures, and all read-only/history rendering) collapsed exactly as today.

**Architecture:** Add one helper method (`ConceptReferencesHelper#first_exposure?`) that reuses `User#concept_exposure_count` — already built for `improved_code` gating — to answer "has this user ever been exposed to this concept before today, in this bucket?" Thread an `open` local through the existing `shared/_concept_reference` partial, and pass `open:` only from the three unsubmitted call sites in `dashboard/_exercise.html.erb` and the shared architecture section (gated on its existing `submitted` local). No other call site changes.

**Tech Stack:** Rails 8, RSpec (request + helper specs), ERB views.

## Global Constraints

- No migration — this is a read-time display decision only (spec: "Decision" section).
- No changes to `teaching_note` gating, `improved_code` gating logic, concept tagging, or `ConceptReference` generation/storage (spec: "Out of scope").
- Auto-expand applies only to the unsubmitted answering path (`dashboard/_exercise.html.erb`'s three inline sections, and `_architecture_section.html.erb` when `submitted: false`). History and the post-submit read-only view (`_answered_sections.html.erb`, and `_architecture_section.html.erb` when `submitted: true`) always render collapsed (spec: "Decision", "Scope").
- Reuse `User#concept_exposure_count(concept, bucket, on_or_before:)` verbatim — do not build a second counter (spec: "Design").

---

### Task 1: `ConceptReferencesHelper#first_exposure?`

**Files:**
- Modify: `app/helpers/concept_references_helper.rb`
- Test: `spec/helpers/concept_references_helper_spec.rb`

**Interfaces:**
- Consumes: `User#concept_exposure_count(concept, bucket, on_or_before:)` (`app/models/user.rb:163`, already exists, returns Integer) via `current_user` (helper method available in helper specs through the `helper` object once a `current_user` stub/login context is set — see steps below for how existing helper specs in this file get a real user in place; here we stub `current_user` directly since this is a helper spec, not a request spec).
- Produces: `first_exposure?(concept, bucket, date) -> Boolean`, used by Task 2 and Task 3.

- [ ] **Step 1: Write the failing helper spec**

Add this `describe` block at the end of `spec/helpers/concept_references_helper_spec.rb`, just before the final `end` that closes the outer `RSpec.describe ConceptReferencesHelper` block:

```ruby
  describe "#first_exposure?" do
    let(:user) { create_user_with_key }

    before { allow(helper).to receive(:current_user).and_return(user) }

    it "returns false for a blank concept" do
      expect(helper.first_exposure?(nil, "ruby_rails", Date.current)).to eq(false)
      expect(helper.first_exposure?("", "ruby_rails", Date.current)).to eq(false)
    end

    it "returns false for the 'other' concept" do
      expect(helper.first_exposure?("other", "ruby_rails", Date.current)).to eq(false)
    end

    it "returns true when the user has no prior exposure to the concept in that bucket" do
      expect(helper.first_exposure?("n_plus_one", "ruby_rails", Date.current)).to eq(true)
    end

    it "returns false once the user has a prior submitted exposure to the concept" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "ruby_rails",
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(helper.first_exposure?("n_plus_one", "ruby_rails", Date.current)).to eq(false)
    end

    it "scopes exposure by bucket" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "javascript",
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "closures" })

      expect(helper.first_exposure?("closures", "javascript", Date.current)).to eq(false)
      expect(helper.first_exposure?("closures", "ruby_rails", Date.current)).to eq(true)
    end
  end
```

This mirrors the fixture style already used in `spec/models/user_spec.rb`'s `#concept_exposure_count` tests (around line 566) and reuses the `create_user_with_key` spec helper already used throughout `spec/requests/dashboard_spec.rb`.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/helpers/concept_references_helper_spec.rb -e "#first_exposure?"`
Expected: FAIL with `NoMethodError: undefined method 'first_exposure?'`

- [ ] **Step 3: Implement `first_exposure?`**

In `app/helpers/concept_references_helper.rb`, add the method after `concept_reference_for`:

```ruby
module ConceptReferencesHelper
  # The cached durable reference for a section's concept in the given language,
  # or nil. Concepts with no generated reference yet — "other", and first-ever
  # exposures whose lazy background generation hasn't run — simply render no
  # dropdown. Display only; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, language)
    return nil if concept.blank?
    ConceptReference.find_by(concept: concept, language: language)
  end

  # True when the current user has never been exposed to this concept, in this
  # bucket, before the given date — i.e. this render would be their first-ever
  # encounter. Reuses User#concept_exposure_count (the same counter that gates
  # improved_code) rather than a second counter. Blank/"other" concepts never
  # resolve to a cached ConceptReference, but are guarded here too for
  # consistency with DailyResponse#improved_code_visible?.
  def first_exposure?(concept, bucket, date)
    return false if concept.blank? || concept == "other"
    current_user.concept_exposure_count(concept, bucket, on_or_before: date).zero?
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/helpers/concept_references_helper_spec.rb`
Expected: PASS (all examples in the file, including the pre-existing `#concept_reference_for` ones)

- [ ] **Step 5: Commit**

```bash
git add app/helpers/concept_references_helper.rb spec/helpers/concept_references_helper_spec.rb
git commit -m "Add ConceptReferencesHelper#first_exposure?"
```

---

### Task 2: `open` local on the partial + wire `dashboard/_exercise.html.erb`

**Files:**
- Modify: `app/views/shared/_concept_reference.html.erb`
- Modify: `app/views/dashboard/_exercise.html.erb`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `first_exposure?(concept, bucket, date)` from Task 1.
- Produces: `shared/concept_reference` partial now accepts an optional `open:` local (default `false`); no change to its required `reference:` local. Task 3 depends on this partial change.

- [ ] **Step 1: Write the failing request specs**

Add these two examples inside the existing `describe "ConceptReference and scenario rendering"` block in `spec/requests/dashboard_spec.rb` (place them right after the `"renders a concept-reference dropdown before submission when a reference is cached"` example, around line 417):

```ruby
    it "auto-expands the dropdown on a concept's first-ever exposure" do
      exercise_with(concept: "n_plus_one", scenario: "billing reconciliation")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to match(/<details class="ref" open>\s*<summary>Reference — N plus one: how it works/)
    end

    it "keeps the dropdown collapsed on a repeat exposure to the same concept" do
      prior_exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "ruby_rails",
                                             problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: prior_exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "n_plus_one" })
      exercise_with(concept: "n_plus_one", scenario: "billing reconciliation")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to match(/<details class="ref">\s*<summary>Reference — N plus one: how it works/)
      expect(response.body).not_to include('<details class="ref" open>')
    end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "auto-expands the dropdown on a concept's first-ever exposure" -e "keeps the dropdown collapsed on a repeat exposure to the same concept"`
Expected: FAIL — both examples fail because `<details class="ref" open>` never appears (current partial always renders `<details class="ref">` with no `open` attribute).

- [ ] **Step 3: Add the `open` local to the partial**

In `app/views/shared/_concept_reference.html.erb`, change:

```erb
<%# Always-collapsed reference dropdown for a section's concept. Rendered near
    the section's question whenever a cached ConceptReference exists — no
    submission gate, no exposure-count logic. `reference` is a ConceptReference. %>
<details class="ref">
```

to:

```erb
<%# Reference dropdown for a section's concept, rendered near the section's
    question whenever a cached ConceptReference exists. Collapsed by default;
    callers may pass `open: true` for a concept's first-ever exposure while
    answering — see ConceptReferencesHelper#first_exposure?. `reference` is a
    ConceptReference. %>
<% open = local_assigns.fetch(:open, false) %>
<details class="ref"<%= " open".html_safe if open %>>
```

(Leave the rest of the file — `summary`, `ref-body`, closing `</details>` — unchanged.)

- [ ] **Step 4: Wire the three call sites in `dashboard/_exercise.html.erb`**

Change (around line 44-46):

```erb
      <% if (ref = concept_reference_for(cr["concept"], exercise.language)) %>
        <%= render "shared/concept_reference", reference: ref %>
      <% end %>
```

to:

```erb
      <% if (ref = concept_reference_for(cr["concept"], exercise.language)) %>
        <%= render "shared/concept_reference", reference: ref,
              open: first_exposure?(cr["concept"], exercise.language, exercise.date) %>
      <% end %>
```

Change (around line 63-65):

```erb
      <% if (ref = concept_reference_for(pat["concept"], exercise.language)) %>
        <%= render "shared/concept_reference", reference: ref %>
      <% end %>
```

to:

```erb
      <% if (ref = concept_reference_for(pat["concept"], exercise.language)) %>
        <%= render "shared/concept_reference", reference: ref,
              open: first_exposure?(pat["concept"], exercise.language, exercise.date) %>
      <% end %>
```

Change (around line 87-89, inside the `else` branch that renders the plain challenge section):

```erb
        <% if (ref = concept_reference_for(ch["concept"], exercise.language)) %>
          <%= render "shared/concept_reference", reference: ref %>
        <% end %>
```

to:

```erb
        <% if (ref = concept_reference_for(ch["concept"], exercise.language)) %>
          <%= render "shared/concept_reference", reference: ref,
                open: first_exposure?(ch["concept"], exercise.language, exercise.date) %>
        <% end %>
```

Do **not** change the analogous calls in `app/views/responses/_answered_sections.html.erb` — those must keep rendering without `open:` so the partial's default (`false`) applies.

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS (all examples in the file, including the pre-existing ConceptReference/scenario and streak/teaching-hint examples — this confirms no regression in the untouched read-only paths).

- [ ] **Step 6: Commit**

```bash
git add app/views/shared/_concept_reference.html.erb app/views/dashboard/_exercise.html.erb spec/requests/dashboard_spec.rb
git commit -m "Auto-expand ConceptReference on a concept's first exposure"
```

---

### Task 3: Wire `_architecture_section.html.erb`

**Files:**
- Modify: `app/views/responses/_architecture_section.html.erb`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `first_exposure?(concept, bucket, date)` from Task 1; the `open:` local on `shared/concept_reference` from Task 2.
- Produces: nothing consumed by later tasks (this is the last task).

- [ ] **Step 1: Write the failing request spec**

Add this example inside the existing `describe "ConceptReference and scenario rendering"` block in `spec/requests/dashboard_spec.rb`, right after the `"renders the architecture third section with options, tradeoffs, and its concept dropdown"` example (around line 492):

```ruby
    it "auto-expands the architecture section's dropdown on first exposure, but not once submitted" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one", "scenario" => "billing" },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization",
                             "reference" => { "tagline" => "x", "explanation" => "y", "code_example" => "z", "senior_lens" => "w" } },
          "architecture" => { "title" => "Datastore choice", "scenario" => "10x traffic", "question" => "Pick an approach",
                              "options" => [ "Shard Postgres", "Add a cache" ], "concept" => "scaling_bottlenecks" }
        })
      ConceptReference.create!(concept: "scaling_bottlenecks", language: "architecture",
                               tagline: "Find the bottleneck", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path
      expect(response.body).to match(/<details class="ref" open>\s*<summary>Reference — Scaling bottlenecks: how it works/)

      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "architecture" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "architecture" => "scaling_bottlenecks" })

      get root_path
      expect(response.body).to match(/<details class="ref">\s*<summary>Reference — Scaling bottlenecks: how it works/)
      expect(response.body).not_to include('<details class="ref" open>')
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "auto-expands the architecture section's dropdown on first exposure, but not once submitted"`
Expected: FAIL — the first `get root_path` assertion fails because the architecture section's call site doesn't pass `open:` yet, so the dropdown always renders collapsed.

- [ ] **Step 3: Wire the call site**

In `app/views/responses/_architecture_section.html.erb`, change (around line 27-28):

```erb
  <% if (ref = concept_reference_for(arch["concept"], "architecture")) %>
    <%= render "shared/concept_reference", reference: ref %>
  <% end %>
```

to:

```erb
  <% if (ref = concept_reference_for(arch["concept"], "architecture")) %>
    <%= render "shared/concept_reference", reference: ref,
          open: !submitted && first_exposure?(arch["concept"], "architecture", response.date) %>
  <% end %>
```

This uses the partial's existing `submitted` local (already passed in by both callers of `_architecture_section` — `dashboard/_exercise.html.erb` with `submitted: false` and `_answered_sections.html.erb` with `submitted: true`) so the read-only render path never auto-expands, matching Task 2's treatment of the other three sections.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS (full file, confirming no regression elsewhere)

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/views/responses/_architecture_section.html.erb spec/requests/dashboard_spec.rb
git commit -m "Auto-expand the architecture section's ConceptReference on first exposure"
```

# Submit-flow consolidation + shorter architecture scenarios — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make finishing a day's work one sequence — rate, submit, request review, land on history — and stop the AI from generating five-constraint architecture scenarios.

**Architecture:** Change 1 folds the rating into the existing `ResponsesController#create` autosave payload, hides the Submit button until a rating exists, retires the duplicate `responses#show` page and the `PATCH /responses/:id/feedback` endpoint, and makes `/history` the single destination for viewing any day's response + review by rendering the existing `responses/_answered_sections` partial inside a collapsible block per entry. Change 2 is prompt text in `app/services/ai_service.rb` only.

**Tech Stack:** Rails 8.0.5, PostgreSQL, RSpec, ERB with inline `<script>` tags (Stimulus is not wired in this app — inline scripts are the convention).

Spec: `docs/superpowers/specs/2026-07-22-submit-flow-and-scenario-length-design.md`

## Global Constraints

- **No migrations.** `daily_responses.rating` and `.feedback_text` already exist. If any task seems to need a migration, stop and re-read the spec.
- **Review stays manual and on-demand.** Nothing in this plan may auto-trigger `AiService#review_response`.
- **Do not change:** magic-link auth, Resend/SMTP, `ConceptReference`'s always-visible display, concept tagging, `teaching_note`, timezone handling, the language-preference spec, `ARCHITECTURE_CONCEPTS`, the mastery loop (`self_rating_favorable? && ai_rating_favorable?`), or the review/evaluation criteria for architecture answers.
- **`/test_login` does not exist.** Do not reference it or try to preserve it.
- **No Stimulus.** The layout emits no importmap tags. Only inline `<script>` runs. `_exercise.html.erb` references a `regenerate` Stimulus controller that does nothing — leave it alone, it is out of scope.
- **All inline scripts are wrapped in an IIFE.** Turbo re-executes `<script>` tags when a partial is replaced by a broadcast; top-level `const`/`let` would redeclare on the second run.
- Run the full suite with `bundle exec rspec`. Run one file with `bundle exec rspec path/to/spec.rb`.
- Commit after every task.

## File Structure

| File | Responsibility after this plan |
| --- | --- |
| `app/services/ai_service.rb` | Prompt text only — Task 1 |
| `app/controllers/responses_controller.rb` | `create` (answers + rating), `review`, `email_review`. `show` and `feedback` deleted |
| `app/controllers/history_controller.rb` | Loads submitted responses **and their exercises** |
| `config/routes.rb` | `resources :responses, only: [:create]` + two member routes |
| `app/views/layouts/application.html.erb` | Gains the shared submission-rendering styles so both dashboard and history can render `_answered_sections` |
| `app/views/dashboard/show.html.erb` | Keeps only form-specific styles |
| `app/views/dashboard/_exercise.html.erb` | Problem-set form + rating widget + gated Submit + autosave script |
| `app/views/responses/_answered_sections.html.erb` | Read-only render of a day's sections — **unchanged markup**, now used by dashboard + history |
| `app/views/responses/_submission.html.erb` | Submitted badge, rating pill, review trigger + loading state, the review, email button |
| `app/views/history/index.html.erb` | One entry per submitted day: meta, collapsible problems+answers, collapsible review |
| `app/views/responses/_feedback_form.html.erb` | **DELETED** |
| `app/views/responses/show.html.erb` | **DELETED** |

---

### Task 1: Shorten architecture-scenario prompt instructions

Independent of Change 1. Prompt text only — no schema change, no parsing change, no migration.

**Files:**
- Modify: `app/services/ai_service.rb:197` (in `exercise_schema_for`) and `:284` (in `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the failing tests**

Add to `spec/services/ai_service_spec.rb` inside the existing `describe "#exercise_schema_for"` block:

```ruby
    it "caps the architecture scenario at 2-3 sentences and 2-3 constraints" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      expect(schema).to include("2-3 sentences")
      expect(schema).to include("2-3 concrete constraints")
      expect(schema).not_to include("team size")
    end

    it "caps the architecture question at one sentence" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      expect(schema).to include("ONE sentence")
    end
```

Add to `spec/services/ai_service_spec.rb` inside the existing `describe "#build_exercise_prompt"` block:

```ruby
    it "instructs a short architecture scenario with a hard constraint cap" do
      prompt = service.send(:build_exercise_prompt, user, third: :architecture)
      expect(prompt).to include("~50 words maximum")
      expect(prompt).to include("exactly 2-3 concrete constraints")
      expect(prompt).to include("Fewer constraints, not fuzzier ones")
    end

    it "no longer enumerates team size, budget, and timeline as things to include" do
      prompt = service.send(:build_exercise_prompt, user, third: :architecture)
      expect(prompt).not_to include("team size, scale, reliability needs, existing tech debt")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "architecture scenario" -e "architecture question" -e "team size"`

Expected: FAIL — the new strings are not in the prompt yet, and `"team size, scale, reliability needs, existing tech debt"` IS currently present.

- [ ] **Step 3: Replace the schema field descriptions**

In `app/services/ai_service.rb`, inside `exercise_schema_for`'s `ARCH` heredoc, replace these two lines:

```ruby
              "scenario":  "string — realistic production scenario with real constraints (team size, scale, reliability needs, existing tech debt)",
              "question":  "string — asks for a decision + justification",
```

with:

```ruby
              "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
              "question":  "string — ONE sentence asking for a decision + justification",
```

Leave every other line of the `ARCH` heredoc (`title`, `options`, `teaching_note`, `concept`, `reference`) exactly as it is.

- [ ] **Step 4: Replace the generation guidance**

In `app/services/ai_service.rb`, inside `build_exercise_prompt`'s `third_guidance` `ARCH` heredoc, replace this line:

```
          - The third section is an ARCHITECTURE decision, not a coding task. Give a realistic production scenario with concrete constraints (team size, scale, reliability needs, existing tech debt), present 2-3 viable options, and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
```

with these four lines (keep the two `- Choose the … vocabulary` lines that follow untouched):

```
          - The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
          - Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
          - Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
          - The architecture question itself is one sentence — do not restate the scenario in it.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`

Expected: PASS — all examples, including the pre-existing ones. If `it "lists the architecture vocabulary for the architecture section when third: :architecture"` fails, the two `- Choose the …` lines were dropped by mistake; restore them.

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Cap architecture scenarios at 2-3 sentences and 2-3 constraints"
```

---

### Task 2: `ResponsesController#create` accepts rating and feedback_text

Backend only. After this task the rating can ride along in the autosave payload; the view still uses the old widget until Task 3.

**Files:**
- Modify: `app/controllers/responses_controller.rb:20-24` (assignment) and `:99` (`response_params`)
- Test: `spec/requests/responses_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `POST /responses` accepts `response[rating]` (one of `"too_easy"`, `"right_level"`, `"too_hard"`) and `response[feedback_text]` (string) alongside `response[answers]` and `response[submit]`. Task 3's script sends both on every autosave and on final submit.

- [ ] **Step 1: Write the failing tests**

Add this whole block to `spec/requests/responses_spec.rb`, after the existing `describe "POST /responses concept_tags copy"` block. It uses the file's existing `create_exercise` helper and `login_as(user)` `before` hook.

```ruby
  describe "POST /responses rating + feedback_text" do
    let(:section) { { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } } }

    it "saves rating and feedback_text from an auto-save payload" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 },
                              rating: "right_level", feedback_text: "more SQL please" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("right_level")
      expect(resp.feedback_text).to eq("more SQL please")
      expect(resp.submitted_at).to be_nil
    end

    it "saves rating alongside answers on final submit" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, rating: "too_hard", submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("too_hard")
      expect(resp.submitted_at).to be_present
    end

    it "does not clear an existing rating when the payload omits the key" do
      exercise = create_exercise(section)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: {}, rating: :too_easy, feedback_text: "keep me")

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("too_easy")
      expect(resp.feedback_text).to eq("keep me")
    end

    it "ignores a rating value outside the enum instead of raising" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, rating: "bogus" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.rating).to be_nil
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/responses_spec.rb -e "rating + feedback_text"`

Expected: FAIL — `rating` is `nil` because `response_params` does not permit it. The "bogus" example may pass vacuously for the same reason; it will become meaningful after Step 3.

- [ ] **Step 3: Permit and assign the two fields**

In `app/controllers/responses_controller.rb`, change `response_params`:

```ruby
  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :rating, :feedback_text, answers: [ :code_review, :pattern, :challenge, :architecture ]
    )
  end
```

Then, in `create`, immediately after the existing `@response.assign_attributes(...)` call and before `saved = @response.save`, insert:

```ruby
    # Rating and notes ride along in the same autosave/submit payload as the
    # answers. Assign only when the key is present: an autosave fired before the
    # user picks a rating must not clear a rating they already picked. An
    # off-enum value is ignored rather than raising ArgumentError — the UI can
    # only ever send the three valid values.
    if response_params.key?(:rating)
      value = response_params[:rating].presence
      @response.rating = value if value.nil? || DailyResponse.ratings.key?(value)
    end
    @response.feedback_text = response_params[:feedback_text] if response_params.key?(:feedback_text)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/responses_spec.rb`

Expected: PASS, all examples in the file.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/responses_controller.rb spec/requests/responses_spec.rb
git commit -m "Accept rating and feedback_text in the response autosave payload"
```

---

### Task 3: Rating widget at the end of the problem set; Submit hidden until rated

**Files:**
- Modify: `app/views/dashboard/_exercise.html.erb` (add the widget before `.submit-row`; extend the inline script)
- Modify: `app/views/dashboard/show.html.erb` (`<style>` — add `.rating-section`, drop nothing yet)
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: Task 2's `POST /responses` accepting `response[rating]` and `response[feedback_text]`.
- Produces: the unsubmitted dashboard renders `button.rating-btn[data-rating]` for each of `too_easy` / `right_level` / `too_hard`, a `#feedback-text` textarea, a `#submit-row` that carries `style="display:none"` when the response has no rating, and a `#rating-nudge` paragraph shown in its place.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/dashboard_spec.rb`, after the existing `it "shows no feedback widget before submission"` example. Note that example asserts the *old* `.feedback-quiet` / `.feedback-prominent` classes are absent before submission — it still passes and stays.

```ruby
  it "renders the rating widget at the end of the unsubmitted problem set" do
    create_exercise
    get root_path
    expect(response.body).to include('data-rating="too_easy"')
    expect(response.body).to include('data-rating="right_level"')
    expect(response.body).to include('data-rating="too_hard"')
    expect(response.body).to include("How was today's difficulty?")
  end

  it "hides the submit row and shows the nudge when the draft has no rating" do
    exercise = create_exercise
    create_response(exercise, submitted: false)

    get root_path

    expect(response.body).to match(/id="submit-row"[^>]*style="display:none"/)
    expect(response.body).to include("Rate today's difficulty to finish up.")
  end

  it "shows the submit row and marks the active button when the draft is already rated" do
    exercise = create_exercise
    create_response(exercise, submitted: false).update!(rating: :right_level)

    get root_path

    expect(response.body).not_to match(/id="submit-row"[^>]*style="display:none"/)
    expect(response.body).to include('class="rating-btn active" data-rating="right_level"')
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "rating widget" -e "submit row"`

Expected: FAIL — no `data-rating` attributes and no `#submit-row` id exist yet.

- [ ] **Step 3: Add the rating widget and gate the submit row**

In `app/views/dashboard/_exercise.html.erb`, replace the existing `.submit-row` block (currently lines 91-95):

```erb
    <div class="submit-row">
      <%= f.hidden_field :submit, value: "1" %>
      <%= f.submit "Submit answers →", class: "btn btn-primary" %>
      <span style="font-size:.8rem;color:var(--muted)">Auto-saved as you type</span>
    </div>
```

with:

```erb
    <%# Rating is answered as part of finishing the day's work — it autosaves on
        click and reveals the Submit button. A set cannot be submitted unrated. %>
    <div class="section rating-section">
      <p class="feedback-title">How was today's difficulty?</p>
      <div class="rating-row">
        <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
          <button type="button" class="rating-btn<%= " active" if response.rating == value %>" data-rating="<%= value %>"><%= label.upcase_first %></button>
        <% end %>
      </div>
      <textarea name="response[feedback_text]" id="feedback-text" class="answer" style="min-height:70px;margin-top:.75rem" placeholder="Optional: anything specific to adjust next time?"><%= response.feedback_text %></textarea>
    </div>

    <div class="submit-row" id="submit-row"<%= " style=\"display:none\"".html_safe if response.rating.blank? %>>
      <%= f.hidden_field :submit, value: "1" %>
      <%= f.submit "Submit answers →", class: "btn btn-primary" %>
      <span style="font-size:.8rem;color:var(--muted)">Auto-saved as you type</span>
    </div>
    <p class="progress-label" id="rating-nudge"<%= " style=\"display:none\"".html_safe if response.rating.present? %>>Rate today's difficulty to finish up.</p>
```

`SELF_RATING_LABELS` is `{ "too_easy" => "too easy", "right_level" => "just right", "too_hard" => "too hard" }` on `DailyResponse:7`, so `upcase_first` yields "Too easy" / "Just right" / "Too hard".

- [ ] **Step 4: Extend the inline script**

In the same file's `<script>` IIFE, add these three declarations directly below the existing `const progressLabel = ...` line:

```js
    const ratingButtons = form.querySelectorAll("button[data-rating]");
    const feedbackText  = document.getElementById("feedback-text");
    const submitRow     = document.getElementById("submit-row");
    const ratingNudge   = document.getElementById("rating-nudge");
    const activeRating  = form.querySelector("button.rating-btn.active");
    let rating = activeRating ? activeRating.dataset.rating : null;
```

Add this helper directly above `let saveTimer;` — it becomes the single place the request body is built, so autosave and submit can never drift apart:

```js
    function payload(extra) {
      const answers = {};
      textareas.forEach(t => answers[t.dataset.field] = t.value);
      return { response: Object.assign(
        { answers: answers, rating: rating, feedback_text: feedbackText.value }, extra || {}
      ) };
    }
```

Replace the body of `autoSave`'s `setTimeout` callback — the four lines building `answers` and calling `fetch` — with:

```js
      saveTimer = setTimeout(async () => {
        await fetch(form.action, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
          },
          body: JSON.stringify(payload())
        });
      }, 800);
```

Add the rating and notes listeners directly below the existing `textareas.forEach(t => { ... })` block:

```js
    ratingButtons.forEach(btn => {
      btn.addEventListener("click", () => {
        rating = btn.dataset.rating;
        ratingButtons.forEach(b => b.classList.toggle("active", b === btn));
        submitRow.style.display = "flex";
        ratingNudge.style.display = "none";
        autoSave();
      });
    });

    feedbackText.addEventListener("input", autoSave);
```

Finally, in the `form.addEventListener("submit", ...)` handler, delete the two lines that rebuild `answers`:

```js
      const answers = {};
      textareas.forEach(t => answers[t.dataset.field] = t.value);
```

and change that fetch's body to:

```js
          body: JSON.stringify(payload({ submit: "1" }))
```

- [ ] **Step 5: Style the rating section**

In `app/views/dashboard/show.html.erb`'s `<style>` block, add below the existing `.rating-btn.active` rule:

```css
  .rating-section .feedback-title { font-size: 1rem; font-weight: 600; margin-bottom: .25rem; }
  #rating-nudge { margin-top: -1rem; margin-bottom: 1.5rem; }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`

Expected: PASS, all examples.

- [ ] **Step 7: Commit**

```bash
git add app/views/dashboard/_exercise.html.erb app/views/dashboard/show.html.erb spec/requests/dashboard_spec.rb
git commit -m "Move the difficulty rating into the problem set and gate submit on it"
```

---

### Task 4: Promote the shared submission styles to the layout

`responses/_answered_sections.html.erb` renders `.section`, `.question`, `.answer-display`, `details.ref`, and friends — but those rules live only in `dashboard/show.html.erb`'s inline `<style>`. That is why the old `responses#show` page rendered unstyled. Task 5 renders the same partial on `/history`, which would hit the identical problem. Move the shared rules to the layout first.

**Files:**
- Modify: `app/views/layouts/application.html.erb` (`<style>`)
- Modify: `app/views/dashboard/show.html.erb` (`<style>` — remove the moved rules)
- Modify: `app/views/history/index.html.erb` (`<style>` — remove `.history-pill`, now global)

**Interfaces:**
- Consumes: nothing.
- Produces: `.section`, `.section-label`, `.question`, `.why-box`, `details.ref`, `.ref-body`, `.answer-display`, `.submit-row`, `.submitted-badge`, `.review-section`, `details.hint`, `.hint-body`, and `.history-pill` are globally available on every page.

- [ ] **Step 1: Move the rules into the layout**

In `app/views/layouts/application.html.erb`, add this block inside the existing `<style>`, directly above the `.name-editor-input` rule:

```css
    /* Shared submission-rendering styles. Used by responses/_answered_sections,
       responses/_architecture_section, and responses/_submission — all of which
       render on BOTH the dashboard and the history page, so these cannot live in
       a per-page <style> block. */
    .section { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 1.5rem; margin-bottom: 1.5rem; }
    .section-label { font-size: .75rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--accent); margin-bottom: .95rem; }
    .section h2 { font-size: 1.1rem; margin-bottom: .75rem; }
    .section-scenario { font-size: .95rem; color: var(--muted); margin-bottom: .75rem; }
    .question { font-size: 1rem; line-height: 1.7; margin-bottom: 1.25rem; }
    .why-box { background: rgba(124,106,247,.08); border-left: 3px solid var(--accent); padding: .6rem .9rem; font-size: .9rem; color: var(--muted); border-radius: 0 6px 6px 0; margin-bottom: 1rem; }
    .arch-options { margin: 0 0 1.25rem 1.25rem; font-size: .95rem; line-height: 1.8; }

    details.ref { margin-bottom: 1rem; }
    details.ref summary { cursor: pointer; font-size: .85rem; color: var(--accent); padding: .4rem 0; list-style: none; }
    details.ref summary::before { content: "▶ "; }
    details.ref[open] summary::before { content: "▼ "; }
    .ref-body { background: #0d0d1a; border: 1px solid var(--border); border-radius: 6px; padding: 1rem; margin-top: .5rem; font-size: .88rem; line-height: 1.7; }

    details.hint { margin-bottom: 1rem; }
    details.hint summary { cursor: pointer; font-size: .85rem; color: var(--accent); padding: .4rem 0; list-style: none; }
    details.hint summary::before { content: "▶ "; }
    details.hint[open] summary::before { content: "▼ "; }
    details.hint.locked { pointer-events: none; opacity: .45; }
    .hint-body { background: rgba(124,106,247,.08); border-left: 3px solid var(--accent); padding: .6rem .9rem; font-size: .9rem; border-radius: 0 6px 6px 0; margin-top: .5rem; line-height: 1.6; }

    .submit-row { display: flex; gap: 1rem; align-items: center; margin-top: 1.5rem; }
    .submitted-badge { display: inline-block; background: rgba(74,222,128,.1); color: var(--green); border: 1px solid var(--green); border-radius: 4px; padding: .2rem .6rem; font-size: .8rem; font-weight: 600; }
    .answer-display { background: #0d0d1a; border: 1px solid var(--border); border-radius: 6px; padding: .75rem; font-size: .9rem; white-space: pre-wrap; word-break: break-word; }
    .review-section { margin-top: 1.5rem; }
    .history-pill { border: 1px solid var(--border); border-radius: 4px; padding: .15rem .5rem; font-size: .85rem; color: var(--muted); }
```

`.section-scenario` and `.arch-options` had no CSS anywhere before this change — they were rendered as bare divs and lists. These are new rules, deliberately minimal.

- [ ] **Step 2: Delete the moved rules from the dashboard**

In `app/views/dashboard/show.html.erb`'s `<style>`, delete these rules — every one of them now lives in the layout. Deleting a rule the layout does not define will break the page, so delete exactly this list and nothing else:

`.section`, `.section-label`, `.section h2`, `.question`, `.why-box`, `details.ref`, `details.ref summary`, `details.ref summary::before`, `details.ref[open] summary::before`, `.ref-body`, `.submit-row`, `.submitted-badge`, `.answer-display`, `.review-section`, `details.hint`, `details.hint summary`, `details.hint summary::before`, `details.hint[open] summary::before`, `details.hint.locked`, `.hint-body`.

What must **remain** in `dashboard/show.html.erb`: `.page-header` rules, `textarea.answer`, `textarea.answer:focus`, `textarea.code-answer`, the four `.progress-*` rules, `.progress-sticky` rules, `.rating-row`, `.rating-btn`, `.rating-btn:hover`, `.rating-btn.active`, and the two `.rating-section` / `#rating-nudge` rules added in Task 3.

Also delete `.feedback-quiet`, `.feedback-quiet .feedback-title`, `.feedback-prominent`, and `.feedback-prominent .feedback-title` — the partial that used them is deleted in Task 6, and nothing else references them.

- [ ] **Step 3: Delete `.history-pill` from the history page**

In `app/views/history/index.html.erb`'s `<style>`, delete the `.history-pill` rule (it is now in the layout). Leave `.page-header`, `.history-entry`, `.history-entry h2`, `.history-meta`, `.history-tag`, `details.review`, and `.no-review` in place.

- [ ] **Step 4: Run the suite to verify nothing regressed**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/history_spec.rb`

Expected: PASS. These are request specs asserting on markup, not CSS, so they cover "the pages still render" but not "the pages still look right" — that is checked in Task 7's browser pass.

- [ ] **Step 5: Commit**

```bash
git add app/views/layouts/application.html.erb app/views/dashboard/show.html.erb app/views/history/index.html.erb
git commit -m "Promote shared submission-rendering styles to the layout"
```

---

### Task 5: History renders each day's problems and answers

**Files:**
- Modify: `app/controllers/history_controller.rb`
- Modify: `app/views/history/index.html.erb`
- Test: `spec/requests/history_spec.rb`

**Interfaces:**
- Consumes: Task 4's globally available `.section` / `.answer-display` / `details.ref` styles.
- Produces: each history entry is wrapped in `<div class="history-entry" id="response-<id>">`, so `history_path(anchor: "response-#{id}")` scrolls to it. Task 6 redirects there.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/history_spec.rb` inside the existing `describe "GET /history"` block. The file's `create_session_for` helper builds a `code_review`-only problem set with the question `"q-#{date}"` and the answer `"Answer with plenty of substance"`.

```ruby
    it "renders each entry's problems and the user's answers" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("q-#{session.date}")
      expect(response.body).to include("Answer with plenty of substance")
      expect(response.body).to include("Problems &amp; answers")
    end

    it "anchors each entry by response id" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include(%(id="response-#{session.id}"))
    end

    it "opens the newest entry's problems and leaves older ones closed" do
      create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: 3.days.ago.to_date)

      login_as(user)
      get history_path

      # Two entries, exactly one open problems block — the first.
      expect(response.body.scan(/<details class="answers" open>/).size).to eq(1)
      expect(response.body.scan(/<details class="answers">/).size).to eq(1)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/history_spec.rb -e "problems"  -e "anchors"`

Expected: FAIL — history currently renders only the date, meta pills, and the review.

- [ ] **Step 3: Preload the exercises**

`_answered_sections` calls `exercise.code_review`, `exercise.pattern`, `exercise.architecture`. Without preloading, that is one query per entry.

In `app/controllers/history_controller.rb`, change:

```ruby
    @responses = current_user.daily_responses
                             .includes(:user)
                             .where.not(submitted_at: nil)
                             .order(date: :desc)
```

to:

```ruby
    @responses = current_user.daily_responses
                             .includes(:user, :daily_exercise)
                             .where.not(submitted_at: nil)
                             .order(date: :desc)
```

- [ ] **Step 4: Render the submission in each entry**

In `app/views/history/index.html.erb`, change the entry wrapper to carry an anchor id:

```erb
  <div class="history-entry" id="response-<%= daily_response.id %>">
```

Then, between the closing `</div>` of `.history-meta` and the `<% if daily_response.reviewed? %>` line, insert:

```erb
    <%# Same partial the dashboard's submitted state renders — history is the one
        destination for viewing any day's response, so there is no second
        rendering to keep in sync. Collapsed by default; newest entry open. %>
    <details class="answers"<%= " open".html_safe if i.zero? %>>
      <summary>Problems &amp; answers</summary>
      <%= render "responses/answered_sections", exercise: daily_response.daily_exercise, response: daily_response %>
    </details>
```

Add to the same file's `<style>` block, below the `details.review` rules:

```css
  details.answers { margin: .75rem 0; }
  details.answers summary { cursor: pointer; font-size: .85rem; color: var(--accent); padding: .4rem 0; list-style: none; }
  details.answers summary::before { content: "▶ "; }
  details.answers[open] summary::before { content: "▼ "; }
  details.answers .section { margin-top: 1rem; }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/history_spec.rb`

Expected: PASS, all examples.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/history_controller.rb app/views/history/index.html.erb spec/requests/history_spec.rb
git commit -m "Show each day's problems and answers on the history page"
```

---

### Task 6: Retire `responses#show` and the feedback endpoint; retarget every redirect

The consolidation itself. `responses#show` renders exactly `_answered_sections` + `_submission` — the same pair `dashboard/_exercise.html.erb:19-21` already renders — and after Task 5 history covers the same ground. Nothing links to it: no nav entry, no mailer link, no Turbo Stream target. `PATCH /responses/:id/feedback` had exactly one caller, `_feedback_form.html.erb`, which Task 3 replaced.

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/responses_controller.rb`
- Modify: `app/views/responses/_submission.html.erb`
- Modify: `app/views/responses/_answered_sections.html.erb` (header comment only)
- Delete: `app/views/responses/show.html.erb`, `app/views/responses/_feedback_form.html.erb`
- Test: `spec/requests/responses_spec.rb`, `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: Task 5's `id="response-<id>"` anchors on the history page.
- Produces: `response_path` and `feedback_response_path` no longer exist. Any spec or view referencing either must be updated in this task.

- [ ] **Step 1: Update the specs first**

In `spec/requests/responses_spec.rb`:

1. Delete the entire `describe "GET /responses/:id (review page)" do ... end` block (currently lines 315-397, ending with the `"redirects a still-unsubmitted draft away from the review page"` example). The page is gone; Task 5's history specs cover the same rendering.

2. Replace the whole `describe "POST /responses redirect targets on final submit"` block with:

```ruby
  describe "POST /responses redirect targets on final submit" do
    it "returns the dashboard URL in the JSON redirect key on submit" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)["redirect"]).to eq(root_path)
    end

    it "does not include a redirect key on a non-submitting auto-save" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)).not_to have_key("redirect")
    end

    it "redirects a native (no-JS) final submit back to the dashboard" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }

      expect(response).to redirect_to(root_path)
    end
  end
```

3. In the `review` and `email_review` describes, replace every
`expect(response).to redirect_to(response_path(daily_response))` with the right new target. Success and "already reviewed" paths go to history; guard and error paths go back to the dashboard:

```ruby
expect(response).to redirect_to(history_path(anchor: "response-#{daily_response.id}"))
```

for: review success, "already reviewed", `email_review` success, and `email_review`'s "no review to email yet" guard. And:

```ruby
expect(response).to redirect_to(root_path)
```

for: review's "submit your answers first" guard, and the three `AiService` error rescues (authentication, rate limit, generic).

Run `bundle exec rspec spec/requests/responses_spec.rb` and read the failures to confirm you have found all of them — `response_path` will raise `NoMethodError` once the route is gone, so nothing can be missed silently.

In `spec/requests/dashboard_spec.rb`:

4. Delete the `it "round-trips rating and feedback text through the feedback action"` example (currently lines 123-129). Task 2 already covers the same round-trip through `POST /responses`.

5. Delete the `it "shows the quiet feedback widget after submission, before review"` and `it "shows the prominent feedback card after the review, not the quiet one"` examples (currently ~lines 68-80). Both assert on `.feedback-quiet` / `.feedback-prominent`, which no longer exist after this task. Keep `it "shows no feedback widget before submission"` only if it still passes — it asserts *absence* of those classes, which stays true; if it now reads as vacuous, delete it too and note that in the commit message.

6. Add:

```ruby
  it "shows the day's rating as a read-only pill after submission" do
    create_response(create_exercise).update!(rating: :right_level)
    get root_path
    expect(response.body).to include("Rated: just right")
    expect(response.body).not_to include('data-rating="too_hard"')
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/responses_spec.rb spec/requests/dashboard_spec.rb`

Expected: FAIL — the redirect assertions still point at the old targets, and the rating pill does not render yet.

- [ ] **Step 3: Shrink the routes**

In `config/routes.rb`, replace:

```ruby
  resources :responses, only: [ :create, :show ] do
    member do
      patch :feedback     # rating + feedback_text after submission
      post  :review       # trigger Claude inline review
      post  :email_review # email the completed review to the user
    end
  end
```

with:

```ruby
  # Submit/update today's answers. Rating rides along in #create's payload; there
  # is no per-day show page — /history renders every submitted day, today included.
  resources :responses, only: [ :create ] do
    member do
      post :review       # trigger the inline AI review
      post :email_review # email the completed review to the user
    end
  end
```

- [ ] **Step 4: Update the controller**

In `app/controllers/responses_controller.rb`:

Change the `before_action` to:

```ruby
  before_action :set_response, only: [ :feedback, :review, :email_review ]
```
→
```ruby
  before_action :set_response, only: [ :review, :email_review ]
```

In `create`, change the two redirect targets:

```ruby
          payload[:redirect] = root_path if response_params[:submit] == "1"
```

and

```ruby
          redirect_to root_path
```

(the HTML branch no longer needs its ternary — both the submit and autosave cases go to `root_path`; keep the `alert:` failure branch as is).

Delete the entire `show` action and its comment block, and the entire `feedback` action and its comment. Delete the `feedback_params` private method.

Rewrite `review` and `email_review` with the new targets:

```ruby
  # POST /responses/:id/review — trigger the inline AI review. Synchronous: the
  # request blocks for as long as the provider takes, then lands the user on the
  # history page anchored to the day they just had reviewed.
  def review
    return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?
    return redirect_to history_anchor, notice: "Already reviewed." if @response.reviewed?

    ai_review = AiService.for(current_user).review_response(current_user, @response.daily_exercise, @response)

    @response.update!(ai_review: ai_review)
    redirect_to history_anchor, notice: "Review ready!"
  rescue AiService::AuthenticationError => e
    redirect_to root_path, alert: "Your API key was rejected — check it in Settings. (#{e.message})"
  rescue AiService::RateLimitError => e
    redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
  end

  # POST /responses/:id/email_review — email the completed review to the user
  def email_review
    return redirect_to history_anchor, alert: "No review to email yet." unless @response.reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to history_anchor, notice: "Review sent to #{current_user.email}."
  end
```

Add to the `private` section, above `set_response`:

```ruby
  # Errors send the user back to the dashboard, where the retry button lives.
  # Everything else lands on the history entry for the day in question.
  def history_anchor
    history_path(anchor: "response-#{@response.id}")
  end
```

- [ ] **Step 5: Rewrite `_submission.html.erb`**

Replace the whole of `app/views/responses/_submission.html.erb` with:

```erb
<%# Submitted badge, the day's self-rating, the on-demand review trigger, the AI
    review, and the email button. Rendered by the dashboard's submitted state and
    by each history entry. Review stays manual: the button only appears when
    unreviewed; nothing auto-triggers it. Local: response. %>
<div class="submit-row">
  <span class="submitted-badge">✓ Submitted</span>
  <% if response.rating.present? %>
    <span class="history-pill">Rated: <%= response.self_rating_label %></span>
  <% end %>
  <% unless response.reviewed? %>
    <%= button_to t("review.get_button", provider: response.user.provider_label),
          review_response_path(response), method: :post,
          class: "btn btn-primary btn-sm",
          form: { class: "review-form", data: { turbo: false } } %>
  <% end %>
</div>

<% if response.reviewed? %>
  <div class="review-section">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem">
      <h3 style="font-size:1rem"><%= t("review.heading", provider: response.user.provider_label) %></h3>
      <%= button_to "Email me this review", email_review_response_path(response), method: :post, class: "btn btn-ghost btn-sm" %>
    </div>
    <%= render "shared/ai_review", response: response %>
  </div>
<% end %>

<script>
// The review call is synchronous — the request blocks for as long as the
// provider takes. Disable the button and swap its label so the wait reads as
// progress rather than a dead click. History renders one of these per entry, so
// wire each form once. Inline script, matching the gym-form convention; Stimulus
// is not wired in this app.
(() => {
  document.querySelectorAll("form.review-form:not([data-review-wired])").forEach(form => {
    form.dataset.reviewWired = "1";
    form.addEventListener("submit", () => {
      const button = form.querySelector('input[type="submit"]');
      if (!button) return;
      // Deferred a tick: disabling synchronously inside the submit handler can
      // cancel the submission in some browsers.
      setTimeout(() => { button.disabled = true; button.value = "Generating review…"; }, 0);
    });
  });
})();
</script>
```

- [ ] **Step 6: Delete the retired views and fix the stale comment**

```bash
git rm app/views/responses/show.html.erb app/views/responses/_feedback_form.html.erb
```

In `app/views/responses/_answered_sections.html.erb`, update the header comment's last sentence — it currently says "Shared by the dashboard submitted state and the responses#show review page." Change to:

```erb
    dropdown when one is cached. Shared by the dashboard's submitted state and
    each entry on the history page. Locals: exercise, response. %>
```

- [ ] **Step 7: Verify no reference to the retired routes survives**

Run: `grep -rn "response_path(\|feedback_response_path\|responses#show\|feedback_form" app spec config`

Expected: only `review_response_path` and `email_review_response_path` hits. Any bare `response_path(` or `feedback_response_path` hit is a leftover — fix it before continuing.

- [ ] **Step 8: Run the full suite**

Run: `bundle exec rspec`

Expected: PASS, entire suite.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Retire the per-day review page and fold feedback into the submit flow"
```

---

### Task 7: Browser verification and documentation

Request specs assert on markup, not on whether the flow works. Task 4 moved CSS between files and Task 3 added a script with no test coverage — both are only verifiable in a browser. Per project convention, UI and JS changes are driven in Chrome before being called done.

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Run the full suite and the linter**

Run: `bundle exec rspec && bin/rubocop`

Expected: PASS / no offenses. Fix anything that fails before continuing.

- [ ] **Step 2: Start the app**

Run: `bin/dev`

Log in as a user who has an API key and a generated exercise for today.

- [ ] **Step 3: Drive the flow in Chrome**

Walk the whole sequence and confirm each checkpoint:

1. Dashboard, unsubmitted: the three sections render styled (cards, coloured section labels, code snippets in dark blocks) — this is the Task 4 style move.
2. The rating widget appears at the end, above where Submit would be. The Submit button is **not visible**; "Rate today's difficulty to finish up." is.
3. Type in a section — the progress bar advances, no console errors.
4. Click a rating — the button highlights, the Submit button appears, and a `POST /responses` fires (check the Network tab; the payload carries `rating`).
5. Reload the page — the rating is still highlighted and Submit is still visible. This proves the autosave persisted it.
6. Submit — the page returns to the dashboard showing "✓ Submitted", the rating pill, and "Get … review →". No raw JSON, no separate page.
7. Click "Get … review →" — the button immediately reads "Generating review…" and is disabled.
8. When it completes, the browser lands on `/history` scrolled to today's entry, which is expanded and shows the review.
9. On `/history`, expand an older entry's "Problems & answers" — the sections render styled, with the user's answers.

If any checkpoint fails, fix it and re-run the affected spec file before continuing.

- [ ] **Step 4: Update CLAUDE.md**

In the Architecture diagram's "User interacts" block, replace these lines:

```
  └→ ResponsesController#create      → auto-save answers (debounced fetch, idempotent)
  └→ ResponsesController#review      → AiService#review_response → ai_review saved
  └→ ResponsesController#feedback    → saves rating (too_easy/right_level/too_hard) + text
  └→ ResponsesController#email_review→ mails the completed review to the user
```

with:

```
  └→ ResponsesController#create      → auto-saves answers + difficulty rating +
       feedback text in one debounced fetch (idempotent). The rating renders at
       the end of the problem set and gates the Submit button — a set cannot be
       submitted unrated. Final submit returns to the dashboard.
  └→ ResponsesController#review      → AiService#review_response → ai_review saved,
       then redirects to /history anchored at that day. Synchronous; the button
       disables and relabels while it runs. Still manual/on-demand.
  └→ ResponsesController#email_review→ mails the completed review to the user
```

And in the `HistoryController#index` line, replace:

```
  └→ HistoryController#index         → past submitted sessions
```

with:

```
  └→ HistoryController#index         → every submitted session, newest first —
       the single destination for viewing any day's problems, answers, and
       review, today's included. There is no per-day review page.
```

In the "Key Design Decisions" section, add a bullet after the "One 'answered' rule" bullet:

```
- **One finish action**: the difficulty rating lives at the end of the problem set and autosaves on click, revealing the Submit button. Answers and rating land in one `ResponsesController#create` call. The AI review stays a separate, manual step afterward — cost-conscious by design.
```

In the "File Map" section, update the `responses_controller.rb` line to:

```
- `app/controllers/responses_controller.rb` — auto-save (answers + rating), review, email-review endpoints
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the consolidated submit flow"
```

---

## Self-review notes

Spec coverage check, section by section:

| Spec item | Task |
| --- | --- |
| Rating at end of problem set | 3 |
| Rating folds into `#create` | 2 |
| Rating required to submit, hidden not disabled | 3 |
| No server-side missing-rating rejection | 2 (deliberate — recorded in the spec) |
| Post-submit shows "Request AI review", review not auto-triggered | 6 |
| Review loading state via inline script | 6 |
| `PATCH feedback` retired | 6 |
| `responses#show` retired | 6 |
| History renders `_answered_sections`, no forked rendering | 5 |
| History entries collapsed, today auto-open | 5 |
| `includes(:daily_exercise)` | 5 |
| All redirects retargeted | 6 |
| Architecture scenario capped at 2-3 sentences / 2-3 constraints | 1 |
| Architecture question capped at one sentence | 1 |
| No migrations | Global constraint |

One item is in this plan but not in the spec: **Task 4, promoting the shared styles to the layout.** It surfaced while writing the plan — `application.css` is not linked in the layout, and the classes `_answered_sections` renders exist only in `dashboard/show.html.erb`'s inline `<style>`. The retired `responses#show` page was therefore already rendering unstyled. Without Task 4, history's new problems-and-answers blocks would render unstyled the same way. Task 4 is a prerequisite for Task 5, not scope creep.

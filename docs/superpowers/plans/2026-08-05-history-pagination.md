# History Pagination + Parsons Arrow Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paginate the History page at 10 sessions per page using Pagy's offset paginator, and remove the Parsons Problem up/down arrows from the default render so drag-and-drop is the primary input.

**Architecture:** `HistoryController#index` wraps its existing scope in `pagy(:offset, …)`. A new `DailyResponse#history_page` lets `ResponsesController`'s post-review redirect target the page that actually contains the entry. Separately, the Parsons partial stops emitting arrow buttons; an inline script injects them only if the SortableJS CDN import fails or stalls.

**Tech Stack:** Rails 8, PostgreSQL, RSpec, ERB with inline `<script>` tags (no Turbo/Stimulus loaded), Pagy 43.

## Global Constraints

- Branch is `feature/history-pagination`, already created. Never commit to `main`.
- Design spec: `docs/superpowers/specs/2026-08-05-history-pagination-design.md`.
- Pagy version: `~> 43.6`. **Pagy 43 is a full API rewrite.** `Pagy::Backend`, `Pagy::Frontend`, `pagy_nav`, `pagy_url_for`, and the `extras` system no longer exist. Use only `include Pagy::Method`, `pagy(:offset, scope, limit:)`, and methods on the pagy object (`@pagy.previous_tag`, `@pagy.next_tag`, `@pagy.page`, `@pagy.last`, `@pagy.count`). Do not follow v6/v9 examples.
- No `config/initializers/pagy.rb`. All options are passed at the call site.
- Page size is 10, defined once as `DailyResponse::HISTORY_PAGE_SIZE`.
- Code must be self-documenting. Add a comment only to explain a non-obvious *why*. Never comment what the code does.
- Run the full suite with `bundle exec rspec`; run a single file with `bundle exec rspec path/to/spec.rb`.
- Do not weaken or delete existing assertions.

---

### Task 1: `DailyResponse` page-size constant, `submitted` scope, and `#history_page`

Pure ActiveRecord — no Pagy yet. This gives Task 2 and Task 3 the shared vocabulary they both need.

**Files:**
- Modify: `app/models/daily_response.rb`
- Test: `spec/models/daily_response_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `DailyResponse::HISTORY_PAGE_SIZE` → `Integer` (`10`)
  - `DailyResponse.submitted` → `ActiveRecord::Relation`
  - `DailyResponse#history_page` → `Integer`, 1-based

- [ ] **Step 1: Write the failing tests**

Append this `describe` block to `spec/models/daily_response_spec.rb`, immediately before the file's final `end`. It uses the file's existing `let(:user)`.

```ruby
  describe "#history_page" do
    def submitted_response_on(owner, date)
      exercise = owner.daily_exercises.create!(
        date: date,
        generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      owner.daily_responses.create!(
        daily_exercise: exercise,
        date: date,
        answers: { "code_review" => "An answer with real substance" },
        submitted_at: Time.current
      )
    end

    it "puts the ten newest sessions on page 1 and the eleventh on page 2" do
      responses = (0..10).map { |i| submitted_response_on(user, i.days.ago.to_date) }

      expect(responses[0].history_page).to eq(1)
      expect(responses[9].history_page).to eq(1)
      expect(responses[10].history_page).to eq(2)
    end

    it "ignores unsubmitted drafts, which never appear in history at all" do
      target = submitted_response_on(user, 20.days.ago.to_date)
      (0..9).each do |i|
        date = i.days.ago.to_date
        draft_exercise = user.daily_exercises.create!(
          date: date,
          generated_at: Time.current,
          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
        )
        user.daily_responses.create!(daily_exercise: draft_exercise, date: date, answers: {})
      end

      expect(target.history_page).to eq(1)
    end

    it "ignores another user's sessions" do
      other = User.create!(email: "other@example.com", name: "Other")
      (0..9).each { |i| submitted_response_on(other, i.days.ago.to_date) }
      target = submitted_response_on(user, 20.days.ago.to_date)

      expect(target.history_page).to eq(1)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/models/daily_response_spec.rb -e "#history_page"`

Expected: 3 failures, `NoMethodError: undefined method 'history_page'`.

- [ ] **Step 3: Add the constant, scope, and method**

In `app/models/daily_response.rb`, add the constant directly after the existing `MAX_FOLLOW_UPS_PER_SECTION` constant:

```ruby
  # How many History entries render per page. Lives on the model rather than
  # HistoryController because #history_page needs the same number to work out
  # which page a given response lands on.
  HISTORY_PAGE_SIZE = 10
```

Add the scope directly after the existing `validates :date, uniqueness: ...` line:

```ruby
  scope :submitted, -> { where.not(submitted_at: nil) }
```

Add the method after the existing `def submitted? = submitted_at.present?` line:

```ruby
  # History orders `date: :desc`, so the number of strictly-newer submitted
  # sessions is this response's zero-based position in that ordering.
  def history_page
    newer = user.daily_responses.submitted.where("date > ?", date).count
    (newer / HISTORY_PAGE_SIZE) + 1
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`

Expected: all examples pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/daily_response.rb spec/models/daily_response_spec.rb
git commit -m "Add DailyResponse.submitted scope and #history_page

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Paginate the History page

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`
- Modify: `app/controllers/history_controller.rb`
- Modify: `app/views/history/index.html.erb`
- Test: `spec/requests/history_spec.rb`

**Interfaces:**
- Consumes: `DailyResponse::HISTORY_PAGE_SIZE`, `DailyResponse.submitted` (Task 1).
- Produces: `@pagy` (a `Pagy::Offset`) and `@responses` (an Array) for the History view. `GET /history` accepts a `page` query parameter.

- [ ] **Step 1: Add the gem and install it**

Add to `Gemfile`, directly after the `gem "resend"` line and its comment:

```ruby
# Offset pagination for the History page (HistoryController)
gem "pagy", "~> 43.6"
```

Run: `bundle install`

Expected: `Bundle complete`, with `pagy` at some `43.6.x` version in the output. Ruby must be 3.3+ (this repo is on 3.3.6).

- [ ] **Step 2: Write the failing tests**

Add this `describe` block to `spec/requests/history_spec.rb`, immediately before the file's final `end`. It reuses the `create_session_for` helper and `let(:user)` already defined at the top of the outer describe.

```ruby
  describe "pagination" do
    def create_sessions(count)
      (0...count).map { |i| create_session_for(user, date: (i + 1).days.ago.to_date) }
    end

    def formatted(session)
      session.date.strftime("%A, %B %-d, %Y")
    end

    def pagination_nav
      response.body[/<nav class="pagination".*?<\/nav>/m]
    end

    it "shows the ten newest sessions on page 1 and the eleventh on page 2" do
      sessions = create_sessions(11)
      login_as(user)

      get history_path
      expect(response.body).to include(formatted(sessions[0]))
      expect(response.body).to include(formatted(sessions[9]))
      expect(response.body).not_to include(formatted(sessions[10]))

      get history_path(page: 2)
      expect(response.body).to include(formatted(sessions[10]))
      expect(response.body).not_to include(formatted(sessions[0]))
    end

    it "reports the total session count on every page, not the page size" do
      create_sessions(11)
      login_as(user)

      get history_path
      expect(response.body).to include("11 submitted sessions")

      get history_path(page: 2)
      expect(response.body).to include("11 submitted sessions")
    end

    it "renders no nav when every session fits on one page" do
      create_sessions(10)
      login_as(user)

      get history_path

      expect(response.body).not_to include('class="pagination"')
    end

    it "links forward from the first page and back from the last" do
      create_sessions(11)
      login_as(user)

      get history_path
      expect(pagination_nav).to include("Page 1 of 2")
      expect(pagination_nav).to include(%(href="#{history_path(page: 2)}"))

      get history_path(page: 2)
      expect(pagination_nav).to include("Page 2 of 2")
      expect(pagination_nav).to include(%(href="#{history_path}"))
    end

    it "redirects an out-of-range page to the last real page" do
      create_sessions(11)
      login_as(user)

      get history_path(page: 99)

      expect(response).to redirect_to(history_path(page: 2))
    end

    it "serves page 1 for a non-numeric page rather than erroring" do
      sessions = create_sessions(11)
      login_as(user)

      get history_path(page: "abc")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(formatted(sessions[0]))
    end

    it "auto-opens the newest entry on page 1 and nothing on later pages" do
      create_sessions(11)
      login_as(user)

      get history_path
      expect(response.body.scan(/<details class="answers" open>/).size).to eq(1)

      get history_path(page: 2)
      expect(response.body.scan(/<details class="answers" open>/).size).to eq(0)
    end

    it "still renders the empty state when the user has no sessions at all" do
      login_as(user)

      get history_path

      expect(response.body).to include("No submitted sessions yet.")
      expect(response.body).not_to include('class="pagination"')
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/history_spec.rb -e "pagination"`

Expected: failures — page 2 shows the same entries as page 1, and no `<nav class="pagination">` is rendered.

- [ ] **Step 4: Rewrite the controller**

Replace the entire contents of `app/controllers/history_controller.rb` with:

```ruby
class HistoryController < ApplicationController
  include Pagy::Method

  # Pagy serves an out-of-range page as an empty result set by default, which
  # here would render the "no sessions yet" empty state to someone who has
  # plenty. Raise instead, and land them on the last real page.
  rescue_from Pagy::RangeError, with: :redirect_to_last_page

  # GET /history — all past submitted sessions, newest first. Drafts
  # (auto-saved but unsubmitted) stay on the dashboard, not here.
  def index
    @pagy, @responses = pagy(
      :offset,
      current_user.daily_responses.submitted
                  .includes(:user, :daily_exercise, :review_follow_ups)
                  .order(date: :desc),
      limit: DailyResponse::HISTORY_PAGE_SIZE,
      raise_range_error: true
    )
  end

  private

  def redirect_to_last_page(error)
    redirect_to history_path(page: error.pagy.last)
  end
end
```

- [ ] **Step 5: Update the view**

In `app/views/history/index.html.erb`, make four edits.

First, add these rules to the end of the `<style>` block, just before its closing `</style>` — after the existing `@media (max-width: 600px) { ... }` block:

```css
  .pagination { display: flex; align-items: center; justify-content: center; gap: 1rem; margin: 2rem 0 1rem; font-size: .9rem; }
  .pagination a { color: var(--accent); text-decoration: none; border: 1px solid var(--border); border-radius: 6px; padding: .4rem .7rem; }
  .pagination a[aria-disabled="true"] { color: var(--muted); opacity: .5; pointer-events: none; }
  .pagination span { color: var(--muted); }
```

Second, replace the count line and the empty-state guard. Change:

```erb
  <div class="count"><%= pluralize(@responses.size, "submitted session") %></div>
</div>

<% if @responses.empty? %>
```

to:

```erb
  <div class="count"><%= pluralize(@pagy.count, "submitted session") %></div>
</div>

<% if @pagy.count.zero? %>
```

Third, gate both auto-open rules on page 1, since their intent is "the newest entry". Change:

```erb
    <details class="answers"<%= " open".html_safe if i.zero? %>>
```

to:

```erb
    <details class="answers"<%= " open".html_safe if i.zero? && @pagy.page == 1 %>>
```

and change:

```erb
      <details class="review" <%= "open" if i.zero? %>>
```

to:

```erb
      <details class="review" <%= "open" if i.zero? && @pagy.page == 1 %>>
```

Fourth, append the nav to the very end of the file, after the closing `<% end %>` of the `@responses.each_with_index` loop:

```erb
<% if @pagy.last > 1 %>
  <%# Raw output: Pagy returns pre-escaped HTML without calling html_safe. %>
  <nav class="pagination" aria-label="History pages">
    <%== @pagy.previous_tag(text: "← Newer") %>
    <span>Page <%= @pagy.page %> of <%= @pagy.last %></span>
    <%== @pagy.next_tag(text: "Older →") %>
  </nav>
<% end %>
```

- [ ] **Step 6: Run the History specs to verify they pass**

Run: `bundle exec rspec spec/requests/history_spec.rb`

Expected: all examples pass, 0 failures — including the pre-existing ones for script dedup and the single open `details.answers`, which all use fewer than 11 sessions and stay on page 1.

If the `pagination_nav` assertions fail on exact markup, inspect the rendered `<nav>` with a temporary `puts pagination_nav` and adjust the assertion to match Pagy's real output — but do not weaken what is being asserted (a real href to the other page, and the "Page X of Y" text).

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock app/controllers/history_controller.rb app/views/history/index.html.erb spec/requests/history_spec.rb
git commit -m "Paginate History at 10 sessions per page with pagy

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Point the post-review redirect at the right page

**Files:**
- Modify: `app/controllers/responses_controller.rb` (the `history_anchor` private method, around line 226)
- Test: `spec/requests/responses_spec.rb`

**Interfaces:**
- Consumes: `DailyResponse#history_page` (Task 1), the `page` query parameter on `GET /history` (Task 2).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing tests**

In `spec/requests/responses_spec.rb`, find the `describe` block that contains `def create_submitted_response` (around line 255). Add this helper directly below `create_submitted_response`:

```ruby
    def create_submitted_response_on(date)
      exercise = DailyExercise.create!(
        user: user, date: date,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } },
        generated_at: Time.current
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end
```

Then add these two examples inside that same describe block, after the existing `"saves the ai_review from the user's configured provider"` example:

```ruby
    it "sends the user to the history page that actually holds the reviewed entry" do
      target = create_submitted_response_on(30.days.ago.to_date)
      (1..10).each { |i| create_submitted_response_on(i.days.ago.to_date) }
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(target)

      expect(response).to redirect_to(history_path(page: 2, anchor: "response-#{target.id}"))
    end

    it "omits the page parameter when the entry is on the first page" do
      target = create_submitted_response_on(1.day.ago.to_date)
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(target)

      expect(response).to redirect_to(history_path(anchor: "response-#{target.id}"))
    end
```

- [ ] **Step 2: Run the tests to verify the first one fails**

Run: `bundle exec rspec spec/requests/responses_spec.rb -e "history page that actually holds"`

Expected: FAIL — redirects to `/history#response-N` instead of `/history?page=2#response-N`.

- [ ] **Step 3: Update `history_anchor`**

In `app/controllers/responses_controller.rb`, replace:

```ruby
  # Errors send the user back to the dashboard, where the retry button lives.
  # review's non-error redirects land on the history entry for the day in
  # question; email_review always goes to root_path (see above).
  def history_anchor
    history_path(anchor: "response-#{@response.id}")
  end
```

with:

```ruby
  # Errors send the user back to the dashboard, where the retry button lives.
  # review's non-error redirects land on the history entry for the day in
  # question; email_review always goes to root_path (see above).
  #
  # History is paginated, so the anchor only resolves if the request lands on
  # the page holding that entry. A nil page is dropped by the url helper, which
  # keeps page 1 on its bare /history URL.
  def history_anchor
    page = @response.history_page
    history_path(page: (page unless page == 1), anchor: "response-#{@response.id}")
  end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/responses_spec.rb`

Expected: all examples pass. The four pre-existing `history_path(anchor: ...)` expectations (around lines 291, 304, 409, 953) still hold because each creates a single response, which sits on page 1.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/responses_controller.rb spec/requests/responses_spec.rb
git commit -m "Target the correct history page after a review

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Remove Parsons arrows from the default render

**Files:**
- Modify: `app/views/responses/_parsons_problem_section.html.erb`
- Test: `spec/requests/dashboard_spec.rb`
- Create: `spec/system/parsons_reorder_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing consumed by later tasks. On each `ol[data-parsons-blocks]` element the script defines `list.parsonsSync()` (existing) and `list.parsonsAddControls()` (new).

- [ ] **Step 1: Write the failing request specs**

Add these two examples to the `describe "parsons_problem third section"` block in `spec/requests/dashboard_spec.rb` (around line 607), after the existing examples and before that block's closing `end`:

```ruby
    it "renders the blocks without server-side move controls, since drag is the primary input" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include("data-parsons-blocks")
      expect(response.body).not_to include(%(<div class="parsons-controls">))
    end

    it "ships the arrow-injection fallback and a touch delay so a stalled CDN is survivable" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include("parsonsAddControls")
      expect(response.body).to include("delayOnTouchOnly: true")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "parsons_problem third section"`

Expected: 2 failures — the `parsons-controls` div is still server-rendered, and neither `parsonsAddControls` nor `delayOnTouchOnly` appears.

- [ ] **Step 3: Strip the controls from the markup**

In `app/views/responses/_parsons_problem_section.html.erb`, replace:

```erb
        <li class="parsons-block" data-block-id="<%= block_id %>">
          <pre class="snippet"><code<% if (lang = hljs_language(language)) %> data-hljs="<%= lang %>"<% end %>><%= blocks[block_id] %></code></pre>
          <div class="parsons-controls">
            <button type="button" class="btn btn-ghost btn-sm parsons-move-up" aria-label="Move block up">↑</button>
            <button type="button" class="btn btn-ghost btn-sm parsons-move-down" aria-label="Move block down">↓</button>
          </div>
        </li>
```

with:

```erb
        <li class="parsons-block" data-block-id="<%= block_id %>">
          <pre class="snippet"><code<% if (lang = hljs_language(language)) %> data-hljs="<%= lang %>"<% end %>><%= blocks[block_id] %></code></pre>
        </li>
```

Leave the `.parsons-controls` CSS rule in `app/views/layouts/application.html.erb:119` alone — the injected buttons reuse it.

- [ ] **Step 4: Rewrite the classic script to inject controls on demand**

In the same file, replace the entire first `<script>` block (from `// Up/down buttons are the baseline` through the `</script>` that closes it) with:

```html
    <script>
    // Drag (SortableJS, imported below) is the primary way to reorder. The
    // up/down buttons are a recovery path, injected only when that import
    // fails or never resolves. Neither path syncs the hidden field on wire-up
    // — only on an actual move — so the section reads as unanswered until the
    // learner does something, matching every other section.
    (() => {
      function syncHiddenField(list) {
        const ids = [...list.querySelectorAll(".parsons-block")].map(li => li.dataset.blockId);
        const textarea = list.parentElement.querySelector('textarea[data-field="parsons_problem"]');
        textarea.value = "order:" + ids.join(",");
        textarea.dispatchEvent(new Event("input", { bubbles: true }));
      }

      function moveBlock(list, li, direction) {
        if (direction === "up") {
          const prev = li.previousElementSibling;
          if (!prev) return;
          list.insertBefore(li, prev);
        } else {
          const next = li.nextElementSibling;
          if (!next) return;
          list.insertBefore(next, li);
        }
        syncHiddenField(list);
      }

      function controlButton(list, li, direction) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = `btn btn-ghost btn-sm parsons-move-${direction}`;
        btn.textContent = direction === "up" ? "↑" : "↓";
        btn.setAttribute("aria-label", `Move block ${direction}`);
        btn.addEventListener("click", () => moveBlock(list, li, direction));
        return btn;
      }

      function addControls(list) {
        if (list.dataset.parsonsControls) return;
        list.dataset.parsonsControls = "1";
        list.querySelectorAll(".parsons-block").forEach(li => {
          const controls = document.createElement("div");
          controls.className = "parsons-controls";
          controls.append(controlButton(list, li, "up"), controlButton(list, li, "down"));
          li.appendChild(controls);
        });
      }

      document.querySelectorAll("ol[data-parsons-blocks]:not([data-parsons-wired])").forEach(list => {
        list.dataset.parsonsWired = "1";
        list.parsonsSync = () => syncHiddenField(list);
        list.parsonsAddControls = () => addControls(list);
        // A CDN that hangs rather than errors never rejects the import below,
        // so its catch never runs. Without this the section would stay
        // unanswerable for as long as the request is stalled.
        setTimeout(() => { if (!list.dataset.sortableDone) addControls(list); }, 3000);
      });
    })();
    </script>
```

- [ ] **Step 5: Update the module script**

In the same file, replace the entire `<script type="module">` block with:

```html
    <script type="module">
      // Version pinned exactly, same posture as the Mermaid import in
      // _architecture_section — a blocked CDN falls back to the injected
      // up/down buttons above.
      try {
        const { default: Sortable } = await import("https://cdn.jsdelivr.net/npm/sortablejs@1.15.6/modular/sortable.esm.js");
        document.querySelectorAll("ol[data-parsons-blocks]:not([data-sortable-done])").forEach(list => {
          list.dataset.sortableDone = "1";
          // delayOnTouchOnly: a touch drag needs a brief hold, so an ordinary
          // swipe still scrolls the page instead of picking up a block. With
          // the arrows gone this is the only input on a phone. Mouse dragging
          // is unaffected.
          Sortable.create(list, {
            animation: 150,
            delay: 150,
            delayOnTouchOnly: true,
            onEnd: () => list.parsonsSync?.()
          });
        });
      } catch {
        document.querySelectorAll("ol[data-parsons-blocks]").forEach(list => list.parsonsAddControls?.());
      }
    </script>
```

- [ ] **Step 6: Run the request specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/history_spec.rb`

Expected: all examples pass. The pre-existing `history_spec.rb:58` assertion that a submitted Parsons render contains no `parsons-move-up` still holds — the script block is emitted only for unsubmitted sections, so that page has neither the buttons nor the script text.

- [ ] **Step 7: Write the system spec**

Create `spec/system/parsons_reorder_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Parsons reorder controls", type: :system do
  it "shows no arrow buttons once drag is available" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_css("ol[data-parsons-blocks]", wait: 10)

      # data-sortable-done is set by the SortableJS module once drag is wired,
      # so waiting on it is what makes the absence assertion below meaningful
      # rather than merely early.
      expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end
end
```

`FakeService` returns every section kind at once, so a fake-provider user's dashboard always includes a `parsons_problem` section.

- [ ] **Step 8: Run the system spec**

If Playwright is not installed locally yet, run the one-time setup first (documented at the top of `spec/support/system_test_helper.rb`):

```bash
npm --prefix spec/playwright ci
./spec/playwright/node_modules/.bin/playwright-core install --with-deps chromium
```

Run: `bundle exec rspec spec/system/parsons_reorder_spec.rb`

Expected: 1 example, 0 failures.

If this fails because the CDN is unreachable from the test machine, that is the *fallback* path working correctly — `data-sortable-done` will never be set and arrows will appear. Confirm that is the cause before changing any code, and note it rather than weakening the spec.

- [ ] **Step 9: Commit**

```bash
git add app/views/responses/_parsons_problem_section.html.erb spec/requests/dashboard_spec.rb spec/system/parsons_reorder_spec.rb
git commit -m "Make Parsons drag primary and inject arrows only on drag failure

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Full-suite verification and documentation

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Run the full suite**

Run: `bundle exec rspec`

Expected: 0 failures. Investigate and fix any failure rather than adjusting the assertion, unless the assertion is provably describing removed behavior.

- [ ] **Step 2: Update the project documentation**

In `CLAUDE.md`, find this line in the architecture diagram:

```
  └→ HistoryController#index         → every submitted session, newest first —
```

Replace that single line with these two, leaving the three lines that follow it untouched:

```
  └→ HistoryController#index         → every submitted session, newest first,
       paginated 10 per page (pagy, offset) —
```

Then, in the "Key Design Decisions" list, add a new bullet at the end:

```markdown
- **Paginated history**: `/history` renders 10 submitted sessions per page via
  Pagy's offset paginator (`DailyResponse::HISTORY_PAGE_SIZE`). Pagy 43's API
  is a full rewrite — `Pagy::Method`, `pagy(:offset, …)`, and helper methods on
  the pagy object; the `Pagy::Backend`/`pagy_nav` API in most documentation is
  gone. An out-of-range page raises and redirects to the last real page rather
  than rendering the empty state to someone who has sessions. The post-review
  redirect uses `DailyResponse#history_page` so its anchor still resolves.
- **Parsons input**: drag (SortableJS, CDN) is the primary reorder mechanism;
  up/down arrow buttons are injected by script only if that import fails or
  stalls for 3s.
```

In the "File Map", add after the `app/controllers/daily_exercises_controller.rb` entry:

```markdown
- `app/controllers/history_controller.rb` — paginated list of submitted sessions
```

- [ ] **Step 3: Commit and open the PR**

```bash
git add CLAUDE.md
git commit -m "Document history pagination and Parsons drag-first input

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push -u origin feature/history-pagination
gh pr create --base main \
  --title "Paginate History and make Parsons drag-first" \
  --body "Paginates /history at 10 sessions per page using pagy's offset paginator, and removes the Parsons up/down arrows from the default render so drag is the primary input (arrows are injected only if the SortableJS CDN import fails or stalls).

Design spec: docs/superpowers/specs/2026-08-05-history-pagination-design.md"
```

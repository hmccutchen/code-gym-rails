# Mobile Gutter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On screens 600px and narrower, let problem-set section cards span the full screen width so their text stops sitting inside 48px of padding per side.

**Architecture:** One `@media (max-width: 600px)` rule added to the shared `<style>` block in `app/views/layouts/application.html.erb`. The rule targets only `.section`, using a negative inline margin to cancel the `.container` gutter it sits inside. `.container` itself is not modified, so nav, flash messages, and page headings keep their padding and need no changes. There is no Ruby, markup, or JavaScript change.

**Tech Stack:** Rails 8.0.5 ERB layout with an inline `<style>` block (this app has no CSS build pipeline and loads no JS framework). RSpec request specs.

**Spec:** `docs/superpowers/specs/2026-07-31-mobile-gutter-design.md`

## Global Constraints

- Breakpoint is exactly `max-width: 600px`. Phones only; 601px and up must render identically to today.
- The negative margin must be exactly `-1.5rem`, matching the `.container` padding it cancels (`.container { max-width: 800px; margin: 0 auto; padding: 0 1.5rem; }`, line 20 of the layout). These two values are coupled.
- Do not modify `.container`.
- Do not modify the Parsons drag-and-drop implementation, its CSS, or `app/views/responses/_parsons_problem_section.html.erb`. An earlier draft of the spec included that work and it was explicitly dropped.
- The new CSS must go in the layout's shared `<style>` block, not a per-page `content_for` style block, because `.section` renders on both the dashboard and the history page.
- This project has no Capybara, Selenium, or system-spec tooling. Do not add any. Layout is verified manually; the automated test only guards that the rule is present in the rendered page.
- Run tests with `bundle exec rspec`.

---

### Task 1: Full-bleed section cards below 600px

**Files:**
- Modify: `app/views/layouts/application.html.erb:101` (insert after the `.arch-options` rule, inside the shared submission-rendering style group that begins at line 92)
- Test: `spec/requests/dashboard_spec.rb` (add a new `describe` block after the existing `describe "brand title link"` block, which ends at line 315)

**Interfaces:**
- Consumes: nothing. This is the only task.
- Produces: nothing consumed by later tasks.

**Context an implementer needs before starting:**

The layout has no CSS file — all styles are inline in a `<style>` block in `app/views/layouts/application.html.erb`. There is currently exactly one media query in the whole app (`@media (hover: hover) and (pointer: fine)`, around line 136), so `@media (max-width: 600px)` will be the first responsive rule in the codebase.

Lines 92-94 of the layout carry this comment, which explains why the new rule belongs in this block:

```
    /* Shared submission-rendering styles. Used by responses/_answered_sections,
       responses/_architecture_section, and responses/_submission — all of which
       render on BOTH the dashboard and the history page, so these cannot live in
       a per-page <style> block. */
```

The request spec asserts on raw `response.body`. Because the `<style>` block is inline in the layout, the CSS text itself appears in the body of every rendered page, which is what makes this assertion possible at all.

- [ ] **Step 1: Write the failing test**

Open `spec/requests/dashboard_spec.rb`. Find the existing block:

```ruby
  describe "brand title link" do
    it "links the brand title back to the dashboard when logged in" do
      login_as(create_user_with_key(email: "brand@example.com", name: "Brand"))

      get root_path

      expect(response.body).to match(%r{<a class="brand" href="/">⚡ Code Gym</a>})
    end
  end
```

Immediately after that block's closing `end`, add:

```ruby
  describe "mobile section gutter" do
    it "renders a 600px breakpoint that pulls section cards out to the screen edges" do
      create_exercise
      get root_path

      expect(response.body).to include("@media (max-width: 600px)")
      expect(response.body).to include("margin-inline: -1.5rem")
    end
  end
```

Note: the file already has `let(:user) { create_user_with_key }`, a top-level `before { login_as(user) }` at line 47, and a `create_exercise` helper at line 20, so no additional setup is needed.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "mobile section gutter"`

Expected: 1 example, 1 failure. The failure message is an `expected ... to include "@media (max-width: 600px)"` diff, because no such rule exists yet.

If it passes at this point, stop — it means a media query with that exact text already exists somewhere in the layout and this plan's assumptions are stale.

- [ ] **Step 3: Add the media query**

Open `app/views/layouts/application.html.erb`. Find line 101, the last rule of the shared submission-rendering group, followed by a blank line and the Parsons rules:

```
    .arch-options { margin: 0 0 1.25rem 1.25rem; font-size: .95rem; line-height: 1.8; }

    .parsons-list { list-style: none; margin: 0 0 1.25rem; padding: 0; }
```

Insert the new rule between them, so the result reads:

```
    .arch-options { margin: 0 0 1.25rem 1.25rem; font-size: .95rem; line-height: 1.8; }

    /* Phones only. The negative inline margin cancels .container's 1.5rem
       gutter so cards run edge to edge, reclaiming ~64px of text width on a
       375px screen; the two values are coupled and must change together.
       Scoped to .section rather than zeroing .container's padding, which would
       drag the nav and every page heading flush against the screen edge. */
    @media (max-width: 600px) {
      .section {
        margin-inline: -1.5rem;
        padding: 1.25rem 1rem;
        border-radius: 0;
        border-left: none;
        border-right: none;
      }
    }

    .parsons-list { list-style: none; margin: 0 0 1.25rem; padding: 0; }
```

Do not change any other line. In particular, leave `.container` (line 20) and `.section` (line 95) exactly as they are — the media query overrides `.section` rather than replacing it, so the desktop rule must stay intact.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "mobile section gutter"`

Expected: `1 example, 0 failures`.

- [ ] **Step 5: Run the full request specs to check for regressions**

Run: `bundle exec rspec spec/requests`

Expected: 0 failures. Nothing should have changed — this step exists because the layout renders on every page in this directory's specs, so a malformed `<style>` block or a broken ERB tag would show up here.

If anything fails, the most likely cause is a typo that unbalanced the `<style>` block or the surrounding ERB. Re-read the inserted lines before changing anything else.

- [ ] **Step 6: Verify the layout manually in a browser**

Start the app: `bin/dev`

Then, in the browser at http://localhost:3000, logged in as a user with a generated exercise for today:

1. Open DevTools device toolbar and set the viewport width to 375px.
2. On the dashboard: confirm each section card's background and top/bottom borders reach both screen edges, with no rounded corners and no left/right border.
3. Confirm the nav bar contents and any flash message still sit inset from the edge — they must be unaffected.
4. Scroll the full page and confirm no horizontal scrollbar appears and nothing is clipped off-screen to the right.
5. Visit `/history` and repeat checks 2-4 there, since it renders the same section partials in their submitted state.
6. Set the viewport to 601px and confirm the cards return to rounded corners with full borders and visible side gutters.

All six checks must pass before committing. If check 4 fails, the `-1.5rem` value has drifted from `.container`'s padding — re-read the Global Constraints.

- [ ] **Step 7: Commit**

```bash
git add app/views/layouts/application.html.erb spec/requests/dashboard_spec.rb
git commit -m "Let section cards run edge to edge on phones

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

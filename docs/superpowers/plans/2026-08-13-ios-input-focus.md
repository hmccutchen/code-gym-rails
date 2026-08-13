# iOS Input-Focus Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop iOS auto-zooming when a text control is focused, by giving every focusable control a 16px floor, and ask the viewport to resize around the keyboard instead of scrolling under it.

**Architecture:** One CSS custom property, `--input-font-size: max(1rem, 16px)`, declared beside the existing colour tokens in the layout's `:root`, referenced from every focusable control's rule. One attribute added to the viewport meta tag. A system spec walks the rendered page and asserts no visible text control computes below 16px, so a future seventh input is caught without anyone having to know the property exists.

**Tech Stack:** Rails 8.0.5, plain CSS in `<style>` blocks (no asset pipeline processing of these rules), RSpec + Capybara + capybara-playwright-driver for the system spec.

## Global Constraints

- **No JavaScript.** No scroll handlers, no keyboard-height measurement, no `visualViewport` listeners.
- **Never add `maximum-scale=1` or `user-scalable=no`.** They suppress zoom by disabling pinch-zoom entirely, which is an accessibility regression. The 16px floor achieves the same result without it. The tag carries neither today — keep it that way.
- **Never use `transform: scale()` on an input** to fake a smaller size; it breaks caret positioning.
- **Do not change any non-focusable typography.** `pre.snippet`, section labels, review headings, and every code block keep the sizes they have. The only rendered-size changes are the six controls in Task 2.
- **Do not touch the mobile padding work** or any `@media` block other than to leave it alone.
- Exact property name and value, verbatim: `--input-font-size: max(1rem, 16px)`.
- Run the suite with `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"` (1303 examples) and system specs with `bundle exec rspec spec/system/` (23 examples). Lint with `bundle exec rubocop app/ spec/`.
- Branch is `fix/ios-input-focus-zoom`, already created from `main`.
- **The spec doc at `docs/superpowers/specs/2026-08-13-ios-input-focus-design.md` and this plan must both be deleted before the PR is opened** (Task 5). They are committed so they can be read during the work; they do not land in the PR diff.

## File Structure

| File | Change |
| --- | --- |
| `spec/system/input_font_size_spec.rb` | **Create.** Walks two rendered pages, asserts no visible text control is under 16px. |
| `app/views/layouts/application.html.erb` | Declare `--input-font-size` in `:root`; apply it to `.self-explanation-input`, `.follow-up-input`, `.duck-input`, `.name-editor-input`; add `interactive-widget=resizes-content` to the viewport meta. |
| `app/views/dashboard/show.html.erb` | Apply the property to `textarea.answer` and `textarea.code-answer`. |
| `app/views/sessions/new.html.erb` | Replace the literal `1rem` on `.form-field input` with the property. |
| `app/views/api_keys/edit.html.erb` | Same, for `.form-field input` and `.form-field select`. |

---

### Task 1: The regression guard, failing

Written first so it demonstrably detects the bug before anything is fixed. It walks the DOM rather than naming the six controls, because the failure mode that matters is someone adding a *seventh* input without ever seeing the custom property — an enumerated list cannot catch that.

**Files:**
- Create: `spec/system/input_font_size_spec.rb`

**Interfaces:**
- Consumes: `create_fake_provider_user`, `visit_as`, `a_weekday` from `spec/support/auth_helpers.rb` and `spec/support/system_test_helper.rb`
- Produces: nothing later tasks depend on

- [ ] **Step 1: Write the failing spec**

Create `spec/system/input_font_size_spec.rb`:

```ruby
require "rails_helper"

# iOS auto-zooms a focused input whose computed font-size is under 16px, which
# shifts the layout and doesn't cleanly restore. Nothing else in the suite
# catches that: it is invisible on desktop and only manifests on a device.
#
# Deliberately walks the DOM instead of naming known controls. The regression
# that matters is a NEW input added below the floor by someone who never saw
# --input-font-size, and an enumerated list cannot catch one.
RSpec.describe "Focusable controls are large enough not to trigger iOS zoom", type: :system do
  IOS_ZOOM_THRESHOLD_PX = 16

  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # Every visible control iOS would zoom on focus, with the size it renders at.
  def undersized_controls
    page.evaluate_script(<<~JS)
      Array.from(
        document.querySelectorAll("textarea, select, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])")
      )
        .filter(el => el.offsetParent !== null)
        .map(el => ({
          id: el.id || el.name || el.className || el.tagName.toLowerCase(),
          size: parseFloat(getComputedStyle(el).fontSize)
        }))
        .filter(c => c.size < #{IOS_ZOOM_THRESHOLD_PX});
    JS
  end

  # FakeService returns every section kind at once and architecture wins
  # DailyPlan's third-slot precedence, so generation would never render the
  # challenge section — and textarea.code-answer only exists there.
  def seed_challenge_exercise
    DailyExercise.create!(
      user: user,
      date: weekday.to_date,
      language: "ruby_rails",
      generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "challenge"   => { "title" => "C", "question" => "q", "starter_code" => "def x; end", "concept" => "n_plus_one" }
      }
    )
  end

  it "renders no undersized control on the dashboard answer form" do
    travel_to(weekday) do
      seed_challenge_exercise
      visit_as(user)
      expect(page).to have_css("textarea.answer", wait: 10)

      expect(undersized_controls).to be_empty
    end
  end

  it "renders no undersized control on the login form" do
    visit login_path
    expect(page).to have_css(".form-field input", wait: 10)

    expect(undersized_controls).to be_empty
  end
end
```

- [ ] **Step 2: Run it and confirm it FAILS for the right reason**

Run: `bundle exec rspec spec/system/input_font_size_spec.rb`

Expected: the dashboard example FAILS, listing controls under 16px — `answer` at 15.2, `code-answer` at 13.6, `duck-input` at 13.6, `name-editor-input` at 14.4. The login example should PASS already, because `.form-field input` is `1rem`.

**If the dashboard example passes, stop and report.** It means the walk isn't finding the controls, and a guard that cannot fail is worse than none.

- [ ] **Step 3: Commit the failing spec**

```bash
git add spec/system/input_font_size_spec.rb
git commit -m "Add a guard for iOS's 16px input-zoom threshold

Walks the rendered DOM rather than naming known controls: the regression
that matters is a new input added below the floor by someone who never
saw the constraint, and an enumerated list cannot catch one.

Fails as committed — the dashboard renders four controls under 16px."
```

---

### Task 2: The 16px floor

**Files:**
- Modify: `app/views/layouts/application.html.erb` (`:root` block at line 11; `.self-explanation-input` line 81; `.follow-up-input` line 91; `.duck-input` line 102; `.name-editor-input` line 201)
- Modify: `app/views/dashboard/show.html.erb` (`textarea.answer` line 7; `textarea.code-answer` line 9)
- Modify: `app/views/sessions/new.html.erb` (`.form-field input`)
- Modify: `app/views/api_keys/edit.html.erb` (`.form-field input`, `.form-field select`)

**Interfaces:**
- Consumes: the failing spec from Task 1
- Produces: CSS custom property `--input-font-size`, available to every rule in the layout and in per-page `<style>` blocks

- [ ] **Step 1: Declare the property**

In `app/views/layouts/application.html.erb`, the `:root` block currently reads:

```css
    :root {
      --bg: #0f0f1a; --surface: #1a1a2e; --border: #2a2a4a;
      --accent: #7c6af7; --text: #e0e0f0; --muted: #888;
      --green: #4ade80; --red: #f87171; --yellow: #fbbf24;
    }
```

Add the property with its reason:

```css
    :root {
      --bg: #0f0f1a; --surface: #1a1a2e; --border: #2a2a4a;
      --accent: #7c6af7; --text: #e0e0f0; --muted: #888;
      --green: #4ade80; --red: #f87171; --yellow: #fbbf24;
      /* iOS auto-zooms a focused input below 16px, which shifts the layout and
         doesn't cleanly restore. max() keeps the floor without overriding a
         user who has set a larger default. */
      --input-font-size: max(1rem, 16px);
    }
```

- [ ] **Step 2: Apply it to the four layout controls**

Each of these keeps every other declaration exactly as-is; only `font-size` changes.

`.self-explanation-input` (line 81): `font-size: .85rem;` → `font-size: var(--input-font-size);`

`.follow-up-input` (line 91): `font-size: .85rem;` → `font-size: var(--input-font-size);`

`.duck-input` (line 102): `font-size: .85rem;` → `font-size: var(--input-font-size);`

`.name-editor-input` (line 201): `font-size: inherit;` → `font-size: var(--input-font-size);`

- [ ] **Step 3: Apply it to the two dashboard textareas**

In `app/views/dashboard/show.html.erb`:

`textarea.answer` (line 7): `font-size: .95rem;` → `font-size: var(--input-font-size);`

`textarea.code-answer` (line 9): `font-size: .85rem;` → `font-size: var(--input-font-size);`

Leave `font-family`, `min-height`, and every other declaration untouched. Do **not** change `pre.snippet`.

- [ ] **Step 4: Point the already-correct form fields at the property too**

`.form-field input` in `app/views/sessions/new.html.erb` and both `.form-field input` and `.form-field select` in `app/views/api_keys/edit.html.erb` are already `font-size: 1rem`, so they do not zoom today. Change each to `font-size: var(--input-font-size);` anyway.

This is beyond the spec's list of six and is deliberate: a flat `1rem` reintroduces the bug for a user whose browser default is below 16px, and leaving two rules encoding the floor as a literal means the property is no longer the single home for it. Note it in the commit message as an addition rather than letting a reviewer find an unexplained file in the diff.

- [ ] **Step 5: Run the guard and confirm it now PASSES**

Run: `bundle exec rspec spec/system/input_font_size_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 6: Run the whole suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"` — expect 1303 examples, 0 failures.
Run: `bundle exec rspec spec/system/` — expect 25 examples (23 + the 2 new), 0 failures.
Run: `bundle exec rubocop app/ spec/` — expect 0 offenses.

- [ ] **Step 7: Check the two layout consequences in a browser**

Start the app and open the dashboard at a 390px viewport (iPhone 14 width) in Chrome's device mode.

1. **The nav name editor** (`.name-editor-input`, `width: 9rem`) now renders at 16px instead of 14.4px, so fewer characters are visible. Confirm text scrolls within the input rather than clipping or overflowing the nav.
2. **The duck-thread row** (`.duck-form`, `flex-wrap: wrap`) may wrap one breakpoint earlier now that `.duck-input` has a larger intrinsic minimum width. Confirm it still looks deliberate when it wraps.

**If the row wraps earlier, let it wrap.** Do not shrink an input back below 16px to avoid a cosmetic wrap — that reintroduces the bug this change exists to fix. If either consequence looks worse than cosmetic, stop and report rather than adjusting font sizes.

- [ ] **Step 8: Commit**

```bash
git add app/views/
git commit -m "Give every focusable control a 16px floor

iOS auto-zooms a focused input under 16px, which shifts the layout and
doesn't cleanly restore. Six controls were under the threshold — every
text entry point in the app, from 13.6px to 15.2px — because no html or
:root font-size is set, so rem resolves to 16px and every .85rem/.95rem
rule lands beneath it.

One custom property rather than the number written six times, and
max(1rem, 16px) rather than either alone: a flat 1rem reintroduces the
bug for a user whose browser default is below 16px, and a flat 16px
overrides a user who raised theirs.

Applied unconditionally rather than behind a media query, because the
trigger is a font-size threshold and not a screen-size condition — an
iPad and a narrow desktop window zoom the same way.

Also points sessions/new and api_keys/edit's .form-field rules at the
property. Those were already 1rem and do not zoom today; this is beyond
the original six, so that the property is the single home for the floor
rather than one of three places encoding it.

Visible change: textarea.code-answer goes 13.6px to 16px and no longer
matches pre.snippet, which is unchanged. Accepted deliberately — they sit
in different containers and read as distinct objects, code-answer appears
only on challenge days, and preserving the match would mean leaving the
zoom bug in the section with the most typing."
```

---

### Task 3: The viewport attribute

**Files:**
- Modify: `app/views/layouts/application.html.erb:5`

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Add the attribute**

Line 5 currently reads:

```erb
  <meta name="viewport" content="width=device-width, initial-scale=1">
```

Change it to:

```erb
  <meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
```

Preserve `width=device-width` and `initial-scale=1` exactly. Add nothing else — in particular no `maximum-scale` and no `user-scalable`.

- [ ] **Step 2: Confirm it renders**

```bash
bundle exec rails runner 'puts ApplicationController.render(template: "dashboard/show", layout: "application") rescue nil' 2>/dev/null | grep -o '<meta name="viewport"[^>]*>' | head -1
```

If that render is awkward outside a request, verify in the browser instead: load any page and read the tag in DevTools' Elements panel. Expected content, exactly:
`width=device-width, initial-scale=1, interactive-widget=resizes-content`

- [ ] **Step 3: Run the suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"` — 1303 examples, 0 failures.
Run: `bundle exec rspec spec/system/` — 25 examples, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "Ask the viewport to resize around the keyboard

Without interactive-widget the default resizes-visual applies: the
document scrolls to reveal the focused field above the keyboard rather
than the layout resizing around it, which is what reads as unmoored next
to a native app.

Included on honest terms rather than as the fix. interactive-widget is
well-supported in Chromium but, as far as is known, not implemented in
WebKit — which is both iPhone Safari and the installed PWA. It is
spec-correct, costs one attribute, and benefits Android and any future
WebKit release, but the improvement felt on an iPhone comes almost
entirely from the font-size floor.

No maximum-scale and no user-scalable: those suppress zoom by disabling
pinch-zoom entirely."
```

---

### Task 4: Device verification

Not code. The one thing this branch claims that cannot be verified from a desktop, and the reason it stays unclaimed until someone does it.

**Files:** none

- [ ] **Step 1: Hand the checklist to the author**

Report to the human partner that the branch is ready for device testing, with this checklist, to be run **twice** — once in iPhone Safari and once in the installed standalone PWA, since the two contexts can differ:

1. Open a day's exercise and focus the code-review answer textarea. **Confirm the page does not zoom.**
2. Type a few characters, then dismiss the keyboard. **Confirm the layout returns to where it started.**
3. Repeat on a challenge day for `textarea.code-answer` — the one control with a visible size change — and confirm it reads acceptably at 16px monospace next to the snippet, which stays smaller.
4. Open a duck thread and focus its input; confirm no zoom and that the input row still looks deliberate.
5. On a reviewed day in history, focus a follow-up input and a self-explanation input; confirm no zoom.

- [ ] **Step 2: Wait for the result before claiming the fix works**

Do not describe the iOS behaviour as fixed in the PR description or anywhere else until the author confirms it. The desktop checks prove the mechanism — every control computes at or above 16px — not the outcome.

---

### Task 5: Remove the planning docs

**Files:**
- Delete: `docs/superpowers/specs/2026-08-13-ios-input-focus-design.md`
- Delete: `docs/superpowers/plans/2026-08-13-ios-input-focus.md`

- [ ] **Step 1: Read the remaining steps before deleting this file**

Deleting the plan removes your own instructions. Read Steps 2-4 first.

- [ ] **Step 2: Confirm everything is green**

```bash
bundle exec rspec --exclude-pattern "system/**/*_spec.rb"
bundle exec rspec spec/system/
bundle exec rubocop app/ spec/
```

Expected: 1303 / 25 / 0 offenses.

- [ ] **Step 3: Delete both docs and commit**

```bash
git rm docs/superpowers/specs/2026-08-13-ios-input-focus-design.md
git rm docs/superpowers/plans/2026-08-13-ios-input-focus.md
git commit -m "Remove the planning docs from the branch

Spec and plan stay out of PRs; both were committed so they could be read
while the work was in progress. Added and removed on the same branch, so
the PR diff carries neither."
```

- [ ] **Step 4: Verify the branch before handing back**

```bash
git status --short --branch
git log --oneline main..HEAD
git diff --stat main..HEAD -- docs/
```

Expected: on `fix/ios-input-focus-zoom`, six commits, and the `docs/` diff empty.

**If `git status` prints `## HEAD (no branch)`, stop and report** — `gh` has detached HEAD in this repository before.

Do not push or open the PR. Report the branch state and wait.

---

## Self-Review

**Spec coverage:** The 16px floor and its `max()` form → Task 2 Steps 1-4. Unconditional application, no media query → Task 2 (no `@media` written anywhere). Edited in place rather than a grouped selector → Task 2 Steps 2-4. The viewport attribute → Task 3. No `maximum-scale`/`user-scalable`/`transform: scale()`/JS → Global Constraints, repeated in Task 3 Step 1. The accepted `code-answer` visual change → Task 2 Step 8's commit message, and it must reach the PR description. The two browser-checked consequences and the let-it-wrap rule → Task 2 Step 7. The regression guard → Task 1. Device verification and what stays unclaimed → Task 4. Planning-doc removal → Task 5. No gaps.

**Placeholder scan:** No TBD/TODO. Every CSS change shows the before and after text. The spec file's full contents are given.

**Type consistency:** The property is `--input-font-size` in all six references and `max(1rem, 16px)` in its single declaration. `IOS_ZOOM_THRESHOLD_PX` is used both in the Ruby assertion and interpolated into the JS, so the two cannot disagree. `undersized_controls` returns an array of hashes in both examples that call it.

**One deviation from the spec, deliberate and flagged:** Task 2 Step 4 also converts `.form-field input` and `.form-field select`, which the spec's list of six does not include. They are already 16px so nothing renders differently; the reason is that leaving them as a literal `1rem` keeps two rules encoding the floor independently of the property, and `1rem` alone breaks for a user with a smaller browser default. Called out in the commit message so it is not an unexplained file in the diff.

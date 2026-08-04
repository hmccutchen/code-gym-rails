# Viewport-Safe Glossary Tooltips on Mobile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop glossary tooltips from running off the right edge of a phone screen by making the panel span the width of the section that contains the term.

**Architecture:** A mobile-only CSS rule reads the panel's horizontal geometry from two custom properties (`--gloss-shift`, `--gloss-width`), each falling back to today's values so a JS-less render is unchanged. The existing delegated `.gloss-term` click/keydown handler in the layout sets those properties when a term opens, measuring the nearest `.section` (or `.container`), and a resize listener recomputes them for whichever term is open.

**Tech Stack:** Rails 8 ERB layout with inline `<style>`/`<script>` (no JS framework, no asset pipeline step for this), RSpec, Capybara + capybara-playwright-driver.

## Global Constraints

- All work happens on the existing `mobile-glossary-tooltip` branch, never on `main`.
- No new JS framework, no new dependency, no external file: the CSS goes in the layout's existing `<style>` block and the JS extends the existing delegated glossary IIFE in `app/views/layouts/application.html.erb`.
- No markup changes. `app/helpers/glossary_helper.rb` and the `.gloss-term` span it emits stay exactly as they are, so `spec/helpers/glossary_helper_spec.rb` and the glossary assertions in `spec/requests/dashboard_spec.rb` must keep passing untouched.
- Mobile breakpoint is `max-width: 600px`, matching the layout's only existing breakpoint.
- Both custom properties must be declared with fallbacks (`var(--gloss-shift, 0)`, `var(--gloss-width, max-content)`) equal to current behavior.
- The desktop hover path (`@media (hover: hover) and (pointer: fine)`) must not change.
- Vertical positioning (`bottom: 100%`) must not change — the panel stays attached to the term's own line.
- Do not add a flip-below rule for vertical overflow; it is explicitly out of scope in the spec.
- Code must be self-documenting. Only add a comment to explain a non-obvious *why* (the layout's existing comments are the model), never to restate *what* the code does.

---

### Task 1: Make the mobile tooltip panel span its section

**Files:**
- Modify: `app/views/layouts/application.html.erb` — the `.gloss-term` CSS rules at lines 139-153, and the glossary `<script>` IIFE at lines 341-361
- Test: `spec/system/glossary_tooltip_spec.rb` (create)

**Interfaces:**
- Consumes: `create_fake_provider_user` and `visit_as(user)` from `spec/support/auth_helpers.rb` (already included for `type: :system`); `FakeService`'s `code_review` glossary, which already contains `{ "term" => "loyalty tier", "definition" => "A customer segment (bronze/silver/gold) based on total spend." }`.
- Produces: two CSS custom properties set as inline styles on a `.gloss-term` element — `--gloss-width` (px string) and `--gloss-shift` (px string). Nothing else consumes them; they are read only by the `.gloss-term::after` rule added in this task.

- [ ] **Step 1: Write the failing system spec**

Create `spec/system/glossary_tooltip_spec.rb`. Two details matter and were both
established empirically — do not simplify them away:

1. **The exercise is built directly, not generated through `FakeService`.** The
   bug only reproduces when the term sits away from the left edge, because the
   old panel was anchored at the term. `FakeService`'s own wording wraps
   "loyalty tier" to the start of a line (measured `termLeft` of 16px), where
   overflow is impossible and the test would pass against the unfixed code.
2. **Assert on the change in `document.documentElement.scrollWidth`, not on an
   absolute width.** At 320px the page already overflows to 353px because of the
   code snippet, so an absolute "no overflow" assertion would fail for unrelated
   reasons. Also note `getComputedStyle(el, "::after").width` returns `auto`
   (parses to `NaN`) whenever the panel is narrower than its 16rem cap, so it is
   not a dependable measurement on its own.

Use the file content given in Steps 1 and 7 of this plan verbatim; the finished
file is the source of truth.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/system/glossary_tooltip_spec.rb`

Expected: the first example FAILS on
`expect(box["scrollAfter"]).to be <= box["scrollBefore"]` with `expected: <= 353,
got: 377` — opening the panel pushes the page 24px further off screen.

If it passes instead, the fixture is not reproducing the bug: check that
`termLeft` is greater than a quarter of the viewport width. Do not proceed until
the failure is that overflow assertion.

- [ ] **Step 3: Add the mobile CSS rule**

In `app/views/layouts/application.html.erb`, find these two lines (they sit immediately after the `.gloss-term::after` block):

```css
    @media (hover: hover) and (pointer: fine) {
      .gloss-term:hover::after { display: block; }
    }
```

Insert the new rule directly **above** that `@media (hover: hover)` block, so the file reads:

```css
    /* Below this breakpoint .section breaks out of .container
       (margin-inline: -1.5rem) and sets its own padding, so the panel is
       measured against the section — not the container — to line up with the
       text it defines. Both fallbacks equal the desktop values, so a render
       where the script has not run is unchanged. */
    @media (max-width: 600px) {
      .gloss-term::after {
        left: var(--gloss-shift, 0);
        width: var(--gloss-width, max-content);
        max-width: none;
      }
    }
    @media (hover: hover) and (pointer: fine) {
      .gloss-term:hover::after { display: block; }
    }
```

- [ ] **Step 4: Set the properties when a term opens**

In the same file, the glossary script currently reads:

```js
    (() => {
      const toggleTerm = (term) => {
        document.querySelectorAll(".gloss-term.gloss-open").forEach((el) => {
          if (el !== term) el.classList.remove("gloss-open");
        });
        if (term) term.classList.toggle("gloss-open");
      };
```

Replace those lines with:

```js
    (() => {
      const positionPanel = (term) => {
        const box = term.closest(".section, .container");
        if (!box) return;
        const rect = box.getBoundingClientRect();
        const pad = parseFloat(getComputedStyle(box).paddingLeft) || 0;
        term.style.setProperty("--gloss-width", `${rect.width - pad * 2}px`);
        term.style.setProperty("--gloss-shift", `${rect.left + pad - term.getBoundingClientRect().left}px`);
      };

      const toggleTerm = (term) => {
        document.querySelectorAll(".gloss-term.gloss-open").forEach((el) => {
          if (el !== term) el.classList.remove("gloss-open");
        });
        if (term && term.classList.toggle("gloss-open")) positionPanel(term);
      };
```

Note that `classList.toggle` returns `true` when the class was added, so the panel is measured only on open, never on close.

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/system/glossary_tooltip_spec.rb`
Expected: PASS (1 example, 0 failures).

- [ ] **Step 6: Add the resize recomputation**

Still in the same script, the file currently ends the IIFE with:

```js
      document.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        const term = event.target.closest(".gloss-term");
        if (!term) return;
        event.preventDefault();
        toggleTerm(term);
      });
    })();
```

Add a resize listener before the closing `})();`, so it reads:

```js
      document.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        const term = event.target.closest(".gloss-term");
        if (!term) return;
        event.preventDefault();
        toggleTerm(term);
      });

      window.addEventListener("resize", () => {
        const open = document.querySelector(".gloss-term.gloss-open");
        if (open) positionPanel(open);
      });
    })();
```

- [ ] **Step 7: Add a rotation regression test**

Add a second example that rotates **landscape → portrait**, not the reverse: a
panel sized for the wider screen is the one that no longer fits afterwards.
Rotating portrait → landscape cannot fail, because a panel that already fits the
narrow screen still fits the wide one.

Without the Step 6 listener this example fails with a panel right edge of
`552` against a `320` viewport — the stale landscape width. Copy the second `it`
block from the finished `spec/system/glossary_tooltip_spec.rb`.

- [ ] **Step 8: Run the full spec file**

Run: `bundle exec rspec spec/system/glossary_tooltip_spec.rb`
Expected: PASS (2 examples, 0 failures).

- [ ] **Step 9: Verify nothing else regressed**

Run: `bundle exec rspec spec/helpers/glossary_helper_spec.rb spec/requests/dashboard_spec.rb`
Expected: PASS, 0 failures. These cover the markup this task must not change.

Then run the whole suite: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 10: Lint**

Run: `bundle exec rubocop app/views/layouts/application.html.erb spec/system/glossary_tooltip_spec.rb`
Expected: no offenses. (Rubocop does not inspect `.erb`; it will report on the spec file only. That is expected, not an error.)

- [ ] **Step 11: Commit**

```bash
git add app/views/layouts/application.html.erb spec/system/glossary_tooltip_spec.rb
git commit -m "Keep glossary tooltips inside the viewport on mobile"
```

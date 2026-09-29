# Accessibility audit, 2026-09-29

Four checks: reduced motion, screen-reader announcements for content that
arrives after a request, color contrast, and keyboard focus. Items 1 and 2 are
fixed in this branch. Items 3 and 4 are findings with proposed fixes, applied
only once the proposals are agreed.

How it was checked: axe-core 4.13.0 ran in the system-spec browser against the
dashboard (answer form and submitted state), history, Learn index, a Learn
concept page, Progress, Account, Setup and login, with every disclosure opened
first. axe-core was installed in a scratch directory for the run and is not
added to the app or its dev dependencies. Keyboard order came from tabbing
through the same pages and recording each stop, and focus visibility from
comparing each control's computed style focused and at rest, backed by
screenshots.

## 1. Reduced motion (fixed)

Every animation and transition in the app:

| Where | What moves | Under `prefers-reduced-motion: reduce` |
| --- | --- | --- |
| `.spinner` (dashboard "generating" state) | ring spins | stops turning |
| `.btn-loading::before` (buttons while a request runs) | ring spins | stops turning |
| `.pull-refresh.is-refreshing .spinner` | ring spins while reloading | stops turning |
| `.pull-refresh.is-settling` | indicator slides and fades | moves instantly |
| `.progress-fill` (dashboard progress bar) | width slides over .3s | changes instantly |
| Parsons drag (SortableJS `animation: 150`) | blocks slide into place | no slide (`animation: 0`) |

Three things in the request had no motion to remove. Folding a section uses a
native `<details>` with no transition, so it already opens and closes
instantly. The save-status banner appears and disappears with no animation.
There are no hover transitions and no smooth scrolling anywhere.

A spinner stops rather than disappearing because each one sits beside text
that already says work is under way ("Submitting…", "Generating your
personalized exercise set…"). The pull-to-refresh ring still follows the
finger during a pull, since that movement is the person's own gesture rather
than an animation.

`spec/system/reduced_motion_spec.rb` checks the computed styles with the
setting on and off. `spec/views/reduced_motion_coverage_spec.rb` fails when a
view declares an animation or transition without a reduced-motion rule, so a
new one cannot skip this.

## 2. Screen-reader announcements (fixed where missing)

| Content | Before | Change |
| --- | --- | --- |
| Duck replies | Announced: `.duck-turns` is a polite live region | none |
| Duck status ("Thinking…") | Announced | none |
| Save-status banner | **Often silent.** A polite region toggled with `hidden`, and screen readers often skip a region that appears with its text already in it. | Always-present, visually hidden `role="alert"` copy. Assertive, because a failed save means the work did not reach the server. |
| Pseudocode critique | Announced: the output container is a polite live region | none |
| Pseudocode translation | Not dynamic: rendered by the server with the review | none |
| Review "Explain this differently" | **Silent on success.** The status line said "Thinking…" and was then cleared, and the explanation lands outside the live region. | Status now says "A different explanation was added above.", the pattern the concept reference's alternates already use |
| Review follow-up answers | **Silent.** Only the status line was live. | Follow-up thread is a polite live region, as the duck's thread is |
| Concept reference alternates | Announced ("A different explanation was added above.") | none |
| Learn "Write this up" polling | Announced: polite status, then the page reloads | none |
| Dashboard "generating" hint, rewritten when generation runs long | **Silent** | Polite live region |
| Name editor save status | Announced | none |
| Parsons move status | Announced | none |
| Judge-edited review text | Not dynamic: the review arrives with a full page load after the redirect | none |

Two regions were left alone on purpose. The dashboard's "N of M answered"
label and the submit nudge change on nearly every keystroke. Making them live
would interrupt someone mid-answer, and the submit button's enabled state
already carries the same information. The exercise-mix ladder-preparation
text also updates after a save without announcing itself. It was not in the
requested list and is low stakes. Worth a decision if Setup gets a
screen-reader pass.

`spec/system/live_regions_spec.rb` covers the three changed behaviors, and a
request spec covers the generating hint.

## 3. Color contrast (findings, not yet applied)

WCAG AA: 4.5:1 for normal text, 3:1 for large text and UI components. The
failures come from three colors. Each misses narrowly, but on text that
appears on every page.

| Element (pages) | Colors | Ratio | Needs |
| --- | --- | --- | --- |
| Links on the surface color: nav, Learn list, footers (every page) | `#7c6af7` on `#1a1a2e` | 4.27 | 4.5 |
| Disclosure summaries: "Reference", "Structure diagram", history "Show review" (dashboard, history) | `#7c6af7` on `#1a1a2e` | 4.27 | 4.5 |
| Section labels ("1 — CODE REVIEW"), `.section-title`, glossary terms in labels (dashboard, history) | `#7c6af7` on `#1a1a2e`, 12px | 4.27 | 4.5 |
| History concept tags `.history-tag` | `#7c6af7` on `#1a1a2e` | 4.27 | 4.5 |
| AI rating pill `.review-rating` (dashboard, history) | `#7c6af7` on `#252146` / `#2e2a56` | 3.8 / 3.32 | 4.5 |
| History review heading `h4.review-rating` | `#7c6af7` on `#201f3a` | 3.99 | 4.5 |
| "Why it exists" box `.why-box` text (dashboard, history) | `#888` on `#22203e` | 4.4 | 4.5 |
| Difficulty note and small buttons in history panels | `#888` on `#201f3a` | 4.49 | 4.5 |
| Primary buttons: "Save key →", "Send code →" (Setup, login) | `#fff` on `#7c6af7` | 3.99 | 4.5 |

Not a failure: the "Need a nudge?" hint shows at 1.87:1 while locked. It is
deliberately dimmed as an inactive control, and WCAG exempts inactive
controls. Section 4 covers its keyboard problem, which is a real one.

Proposed adjustments. Each ratio was checked against every background the
color actually sits on.

1. **Split accent into fill and text.** Keep `--accent: #7c6af7` for borders,
   the progress fill and other non-text uses. Add `--accent-text: #988bf9` and
   use it wherever accent colors text. That gives 6.01 on the surface, 5.5 in
   the why-box, 5.61 in history panels, and 5.34 and 4.68 on the two rating
   pills.
2. **Darken the primary button fill** to `#6a57e8`, giving white text 5.07:1.
   The button still reads as the same purple, one step deeper.
3. **Lighten `--muted` from `#888` to `#999`:** 5.99 on the surface, 5.48 in
   the why-box, 5.59 in history panels, 6.68 on the page background.

These change only lightness, keep the same hues, and touch no layout. The
risk is how much `var(--accent)` is used as text: the split has to be applied
by hand to each rule, not by a global swap.

## 4. Keyboard focus and tab order (findings, not yet applied)

Tab order follows visual order on every audited page:

- **Dashboard:** nav, "Generate new set", then per section the summary,
  reference, hint, answer, the three ratings, and the duck.
- **Exercise mix:** per kind, the slider, the exclude checkbox, then the
  difficulty radios.
- **Learn index and concept pages:** match the layout.
- **Login and Setup forms:** fields in reading order.

The disabled Submit button and the disabled lock checkboxes are skipped, which
is correct for disabled controls. Most controls keep the browser's own focus
ring, and screenshots confirm it shows clearly on the dark theme.

### Clearly broken (proposed fixes)

1. **Exercise-mix sliders have no visible focus.** Setup's
   `.form-field input:not([type="checkbox"], [type="radio"]):focus { outline: none; border-color: … }`
   also matches the range sliders, which have no border to recolor, so a
   focused slider looks identical to an unfocused one. Fix: add
   `[type="range"]` to that `:not()` list, so sliders keep the browser's ring.
2. **A locked "Need a nudge?" hint opens from the keyboard.** The lock is
   `pointer-events: none`, which only stops the mouse. Tabbing to it and
   pressing Enter opens the hint before the section is answered, which
   bypasses the gating the dim styling promises. Fix: set `inert` on a locked
   hint in the same `updateProgress` call that toggles `.locked`. That takes it
   out of the tab order and blocks opening. The trade-off is that `inert` also
   hides it from screen readers until it unlocks. `aria-disabled` plus a
   prevented toggle is the alternative, if the hint should stay discoverable
   while locked.

### Judgment calls (flagged, not changed)

3. **Text fields show focus as a 1px accent border** (answer textareas, Setup
   inputs and selects, login). The border changes from `#2a2a4a` to `#7c6af7`,
   a 3.44:1 change, which meets the AA 3:1 requirement for non-text contrast.
   But at 1px it is thin, and the AAA focus-appearance guidance asks for 2px.
   A `box-shadow` ring alongside the border would strengthen it without moving
   the layout.
4. **The dashboard's sticky progress bar can cover a focused control** when
   tabbing backwards, because the browser scrolls the control to the top edge,
   under the bar. `scroll-padding-top` set to the bar's height would keep
   focused controls clear of it. Whether this happens in practice depends on
   screen height, so it is worth checking on a phone first.
5. **Glossary terms inside section summaries are focusable** (each is a
   `<span role="button" tabindex="0">` inside a `<summary>`). They work, but a focusable element
   nested in another interactive element is discouraged, and some screen
   readers announce the pair confusingly. There is no obvious alternative
   that keeps the tap-to-define behavior, so this is flagged only.
6. **Rating buttons do not expose their selected state** (no
   `aria-pressed`). The selection shows visually but is not announced. This is
   outside the focus audit and noted for completeness.

No migration was needed for any of this.

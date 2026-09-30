# Accessibility audit, 2026-09-29

Four checks: reduced motion, screen-reader announcements for content that
arrives after a request, color contrast, and keyboard focus. Items 1 and 2 are
fixed in this branch. Items 3 and 4 were reported first, and the agreed fixes
are now applied.

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
| `.pull-refresh.is-settling`, `.pull-settling` | indicator and page content slide back after a pull | move instantly |
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
setting on and off. `spec/views/reduced_motion_coverage_spec.rb` fails when any
single animation or transition, selector by selector, has no matching
reduced-motion rule, so a new one cannot skip this even in a file that handles
others.

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

## 3. Color contrast (applied)

WCAG AA: 4.5:1 for normal text, 3:1 for large text and UI components. The
failures came from three colors. Each missed narrowly, but on text that appears
on every page. The fix changes shared variables in the layout, not individual
elements:

- `--accent` stays `#7c6af7` for borders, fills and the progress bar.
- `--accent-text: #988bf9` is new. Every rule that colored text with
  `--accent` now reads it: links, the brand, disclosure summaries, section
  labels, review headings and rating pills, history tags, pagination, the
  featured-concept label, the drill markers, and highlighted code keywords.
- `--muted` goes from `#888` to `#999`.
- `--button-bg: #6a57e8` (hover `--button-bg-hover: #5b48d9`) is the fill
  behind white text: primary buttons and the selected rating button. The white
  text is unchanged.

| Element | Background | Before | After |
| --- | --- | --- | --- |
| Accent text (links, summaries, labels, tags) | `#1a1a2e` surface | 4.27 | 6.01 |
| | `#0f0f1a` page | 4.77 | 6.70 |
| | `#0d0d1a` code and fields | 4.83 | 6.79 |
| | `#22203e` why-box | 3.91 | 5.50 |
| | `#201f3a` history panel | 3.99 | 5.61 |
| AI rating pill | `#252146` | 3.80 | 5.34 |
| | `#2e2a56` | 3.33 | 4.68 |
| Muted text | `#1a1a2e` surface | 4.81 | 5.99 |
| | `#0f0f1a` page | 5.37 | 6.68 |
| | `#22203e` why-box | 4.41 | 5.48 |
| | `#201f3a` history panel | 4.49 | 5.59 |
| | `#2e2a56` rating pill | 3.75 | 4.66 |
| White on primary button / selected rating | fill | 3.99 | 5.07 |
| White on primary button, hover | fill | 5.14 | 6.22 |

Muted text still reads as secondary. Body text `#e0e0f0` against the new
`#999` is 2.18:1 (it was 2.72:1 against `#888`), so muted text stays a clear
step down from body text.

`spec/views/palette_contrast_spec.rb` reads these variables and the tinted
backgrounds from the layout and fails if any pair above drops below its
minimum, so a later palette edit cannot quietly undo this.

After the change, axe-core's contrast rule reports no violations on the
dashboard (answer form, with a rating selected, and submitted state), history,
Learn index, a Learn concept page, Progress, Account, Setup and login, with
every disclosure open. The locked hint is no longer dimmed (section 4), so its
exemption no longer applies.

## 4. Keyboard focus and tab order (applied)

Tab order follows visual order on every audited page:

- **Dashboard:** nav, "Generate new set", then per section the summary,
  reference, hint (once unlocked), answer, the three ratings, and the duck.
- **Exercise mix:** per kind, the slider, the exclude checkbox, then the
  difficulty radios.
- **Learn index and concept pages:** match the layout.
- **Login and Setup forms:** fields in reading order.

What changed:

1. **One focus ring.** `--focus-ring: #c9c0ff`, 2px wide with a 2px offset
   (`--focus-ring-width`, `--focus-ring-offset`), applied with `:focus-visible`
   to text inputs, textareas, selects, Parsons blocks and glossary terms. It is
   at least 7.88:1 against every background it can sit on. The page rules that
   set `outline: none` on focus now only recolor the border, so the ring is not
   removed anywhere. No field sits inside an `overflow: hidden` or scrolling
   parent, so the ring is not clipped. The only such elements are
   visually-hidden text and the progress page's rung bar.
2. **Sliders show focus on the thumb.** Chromium and Safari accept an outline
   on the native `::-webkit-slider-thumb` and Firefox on `::-moz-range-thumb`,
   so the slider keeps its native look and only the thumb gets the ring. Each
   thumb rule stands alone, because a browser drops a whole selector list over
   one vendor pseudo-element it doesn't know.
3. **The locked "Need a nudge?" hint cannot be opened.** While the section is
   unattempted, the page shows the plain line "Available after you attempt this
   section". The disclosure itself waits in a `<template>`, outside the
   document, and the dashboard script puts it in place once the answer counts
   (and takes it out again if the answer is cleared). There is nothing to tab
   to, press or announce before then.
4. **The sticky progress bar no longer covers a focused field.** The bar takes
   its height from `--progress-sticky-height` (3.25rem; it measured 50.27px
   against the new 52px). `scroll-padding-top` on the root reads the same
   variable, plus the focus ring's reach, so a browser that scrolls a field to
   the top edge (iOS Safari does) stops with the field and its ring below the
   bar. At 390px wide the field lands 4px below the bar with no sideways
   scroll. Without the padding it lands underneath the bar.
5. **Glossary terms are no longer wrapped in section titles.** A title is a
   heading, and on the answer form it is also the summary that folds the
   section. Terms are still wrapped in the scenario, question and other body
   text.
6. **Rating buttons announce their state.** Each row is a group named "How
   hard was <section> for you?", and each button carries `aria-pressed`, set
   from the same state that draws the selected style, including a rating
   stored before the page loaded.

Specs: `spec/system/focus_ring_spec.rb` (a field on each form page, and a
screenshot check for the slider thumb), `spec/system/teaching_hint_lock_spec.rb`
(Tab, Enter and Space on a locked hint, then unlocking and re-locking),
`spec/system/sticky_progress_focus_spec.rb`, `spec/system/rating_buttons_spec.rb`,
and request specs for the hint's server render and unwrapped titles.

No migration was needed for any of this, and no dependency was added.

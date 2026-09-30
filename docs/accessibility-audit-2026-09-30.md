# Accessibility audit, Tier 3, 2026-09-30

The WCAG 2.2 AA items left after the 2026-09-29 audit: semantics, touch
targets, zoom and reflow, the login code, and text spacing, plus a VoiceOver
checklist to run by hand. Two things are fixed in this branch: page titles and
the login code field's error and expiry messages. Everything else is reported
here with a recommendation, awaiting a decision.

How it was checked: a throwaway system spec, not committed, seeded a
fake-provider user (today's answer form, Setup, Learn, Progress, Account) and a
preview-seed user (a submitted, part-reviewed dashboard, and history). A script
running in Chromium through the system-spec driver visited each page with every
`<details>` open and the phone menu open. It recorded landmarks, headings,
title and `lang`, the box of every visible interactive element, horizontal
overflow, and text clipped or overlapping under the WCAG text-spacing override.
It ran at 390px and 320px wide, with default display preferences and with the
largest ones (text 140%, loose line spacing, Atkinson). Full-page and
element screenshots were read by eye where the numbers were ambiguous. 400%
browser zoom of a 1280px window is a 320 CSS px viewport, so the 320px run
covers it. No migration and no new dependency.

## 1. Semantics

| Check | Result |
| --- | --- |
| `<html lang>` | `lang="en"` on every page. No change needed. |
| Page titles | **Every page was titled "Code Gym".** Fixed: each page now names itself, for example "History – Code Gym" and "N plus one – Learn – Code Gym". |
| `<main>` | **Missing on every page.** Content sits in `div.container`. |
| `<header>` | None. The brand and menu live inside `<nav>`, which is fine as long as `<main>` exists. |
| `<nav>` | Present on every page, the login page included. |
| Skip link | **None.** The first stop on a signed-in page is the brand link, then the menu. |
| One `<h1>` per page | Yes, on every page. |

Heading order:

| Page | Headings | Gap |
| --- | --- | --- |
| Login, Setup, Account, Learn concept, Progress | h1, then h2 where present | none |
| Learn index | h1, h2 per bucket, h3 per group | none |
| Dashboard, answer form | h1 only. Section titles are the fold `<summary>`s, not headings | **No way to jump between sections by heading** |
| Dashboard, submitted | h1 "Today's Workout", h3 "Claude's Review", h4 per section | **h1 to h3** |
| History | h1, h2 per day, h4 per reviewed section | **h2 to h4** |

The fix: `page_title` in `ApplicationHelper` sets the page's name, and the
layout's `<title>` renders it through `document_title`, so a page without one
still reads "Code Gym". `spec/requests/page_titles_spec.rb` covers each page.

Recommendations, awaiting approval:

- Wrap the layout's `div.container` in `<main id="main">`. This changes the
  markup only.
- Add a skip link, visually hidden until focused, as the first element in
  `<body>`, pointing at `#main`. On a phone it matters little, but it removes
  six Tab stops on every signed-in page for a keyboard user.
- Give each answer-form section a heading inside its `<summary>` (an `<h2>`
  holding the existing label text) so VoiceOver's heading rotor reaches each
  section. Styles stay the same. This is the most useful of the heading fixes.
- Make "Claude's Review" an `<h2>` and its per-section headings `<h3>` on the
  dashboard, and make history's per-section review headings `<h3>`. Both keep
  their current look through their existing classes.

## 2. Touch targets (390px wide)

WCAG 2.5.8 asks for 24 by 24 CSS px, or enough space around a smaller target
(a 24px circle centred on it must not touch another target). Inline links and
terms inside a sentence are exempt. Measured sizes are width by height.

**Under 24px:**

| Element | Size | Where | Passes by exception? |
| --- | --- | --- | --- |
| Exercise mix "Exclude" checkboxes | 13 × 13 (label 72 × 22) | Setup | **No.** Too close to the slider and the lock box. |
| Exercise mix "Lock at this level" checkboxes | 13 × 13 (label 316 × 22) | Setup | **No** |
| "Adjust set size to my recent completion" checkbox | 13 × 13 (label 342 × 22) | Setup | **No** |
| Exercise mix difficulty radios | 13 × 13 (label 187 × 22) | Setup | Yes, by spacing |
| Learn "Only ones I've seen" checkbox | 13 × 13 (label 157 × 26) | Learn index | Yes, and its label is 26 tall |
| Section fold summaries ("1 — Code Review") | 358 × 19 | Dashboard | Yes, by spacing |
| "← All concepts" link | 106 × 17 | Learn concept | **No.** Sits against the next control. |
| Glossary terms | 91–114 × 18 | Dashboard, history | Yes, inline in a sentence |
| Setup's provider links (console.anthropic.com, aistudio.google.com) | 114–128 × 15 | Setup | Yes, inline in a sentence |

Counting the label as part of the checkbox's target, as a click on it toggles
the box, still leaves the lock, exclude and set-size rows 22px tall.

**Between 24 and 44px:**

| Element | Size | Where |
| --- | --- | --- |
| Rating buttons | 111 × 33 | Dashboard |
| Submit answers | 169 × 32 | Dashboard |
| Menu button | 40 × 40 | Every signed-in page |
| Duck toggle ("Stuck? Talk it through") | 181 × 27 | Dashboard |
| Generate new set | 134 × 27 | Dashboard |
| Email me this review | 154 × 27 | Submitted dashboard |
| Explain this differently | 165 × 27 | Submitted dashboard, history |
| Follow-up input and Ask | 249–265 × 34, 51 × 34 | Submitted dashboard, history |
| Reference summaries | 324–358 × 34 | Dashboard, history |
| "This didn't quite land — try a different explanation" | 290–324 × 42 | Dashboard, history |
| Exercise mix summary | 342 × 26 | Setup |
| Exercise mix sliders | 316 × 39 (the whole track responds to a tap) | Setup |
| Learn and Progress concept links | 59–256 × 26 | Learn index, Progress |
| Learn "Write this up", "Drill this", "Drill this group", "Write up the rest" | 77–126 × 25 | Learn |
| Filter concepts input | 342 × 33 | Learn index |
| Nav name field | 336 × 25 | Every signed-in page |
| Save key, Log out, Pause, Delete account | 32–34 tall | Setup, Account |
| Login fields and Send code / Verify code | 40–41 tall | Login |

At or above 44px: the open menu's links (342 × 47) and the brand link.

The slider thumb is the browser's own. The app never sizes it, so Chromium
draws about 16px and iOS draws its larger native thumb. The thumb is not the
only target, though: a tap anywhere on the 39px-tall track moves the value.

Recommendations, awaiting approval:

- **Fix the three failures.** Give the Setup checkboxes and radios a 24px box
  (`width`/`height` on the input, or pad the label to 24px tall), and pad
  "← All concepts" to 24px tall. The look stays the same apart from slightly
  larger boxes.
- **Bring the primary controls to 44px tall:** rating buttons, Submit answers,
  the menu button (40 to 44), and the section fold summaries, which are what
  someone taps most. Padding only; widths stay as they are.
- Leave the rest between 24 and 44. They pass AA, and raising every button to
  44px would change the page's density, which is closer to a redesign.

## 3. Zoom and reflow

The viewport meta tag is `width=device-width, initial-scale=1,
interactive-widget=resizes-content`. It sets no `user-scalable=no` and no
`maximum-scale`, so pinch zoom works. The iOS input-zoom fix uses a 16px input
font size (`--input-font-size`) and does not restrict zoom.

Horizontal scrolling at 320px (the same as 400% zoom on a 1280px window):

| Page | Default display settings | Largest display settings | Cause |
| --- | --- | --- | --- |
| Login | none | none | |
| Every signed-in page | **scrolls, 344px wide** | **scrolls, 373px wide** | The brand logo and name leave no room for the menu button, which ends up half off screen. Reaching the menu means scrolling sideways first. |
| Submitted dashboard | **scrolls, 458px wide** | **scrolls, 638px wide** | `.submit-row` is a one-line flex row: the Submitted badge, one rating pill per section, and "Finish review" or "Get review". It does not wrap. This overflows **at 390px too**, on an ordinary phone at 100% zoom. |
| History, largest settings | | scrolls | The follow-up input inside a review overflows its panel. |

The 390px run found no other overflow. Code blocks scroll inside their own box,
which reflow allows.

Recommendations, awaiting approval:

- `.submit-row { flex-wrap: wrap; }`. This one fails at normal phone width, so
  it is the most urgent item in this report. A one-line change, and the row
  looks the same whenever it fits.
- Let the brand shrink in the nav (`min-width: 0` on the brand, with a
  `max-width` or smaller height for the logo under about 360px) so the menu
  button always fits. It changes the logo's size on the narrowest screens only.
- Give the review follow-up input `min-width: 0` (it sits in a flex row), so it
  shrinks with its panel.

## 4. Login code

| Check | Result |
| --- | --- |
| `autocomplete="one-time-code"` | Present |
| Numeric keyboard | `inputmode="numeric"` and `pattern="[0-9]*"` |
| Paste | Allowed. Nothing blocks paste or autofill. The email sends the code as six plain digits. |
| Memorizing or retyping | Not required. The code can be copied from the email and pasted. The email address is typed once, and the code step never asks for it again. |
| Wrong code or expiry announced | **Was not.** Fixed, see below. |

The page after sending a code, and the page after a wrong code, both put focus
in the code field when they load. The message above the field ("Check your
email … It expires in 15 minutes", or "Incorrect or expired code …") was
neither a live region nor tied to the field. So a screen reader started at the
field and never read why the person was there. It now does:

- The flash messages carry ids (`flash-notice`, `flash-alert`).
- The code field's `aria-describedby` names whichever flash is on the page,
  then the "Enter the 6-digit code" line. VoiceOver reads them after the field's
  label as soon as focus lands.
- After an error the field carries `aria-invalid="true"`.

Two new request specs in `spec/requests/sessions_spec.rb` cover the error and
the notice.

Left as is, to decide:

- `maxlength="6"` truncates a pasted code that starts with a space. Copying from
  Mail on iOS selects the digits alone, so this is unlikely. Accepting any
  pasted text and stripping non-digits on submit would remove the edge, at the
  cost of changing what the field accepts. Recommend leaving it unless someone
  hits it.

## 5. Text spacing

The override (line height 1.5, paragraph spacing 2em, letter spacing 0.12em,
word spacing 0.16em) was injected on every page above, with default and with
the largest display settings.

- **No text is clipped** on any page. No element with `overflow: hidden` or a
  fixed height cuts its text off.
- **No text overlaps.** The script flagged the Progress legend, where each term
  and its definition are inline, so their boxes intersect by construction. The
  screenshot shows it reading correctly.
- The spacing makes the section 3 overflows worse. With the largest display
  settings plus the override, the menu button is pushed off screen at 390px on
  every signed-in page. The submitted dashboard's row reaches 734px wide. The
  section 3 fixes cover both.

## 6. VoiceOver checklist (installed app on iPhone)

These are expected results, not results. Nothing here was run with VoiceOver.

1. Log in: on the email field, hear "Work email, star, text field, required" (the asterisk is part of the label). After Send code, focus lands on the code field: hear "6-digit code from the email, text field", then the "check your email … expires in 15 minutes" message.
2. Enter a wrong code: back on the code field, hear the field's label, "invalid data", and "Incorrect or expired code. Try again, or request a new one below."
3. Dashboard: the page title is announced as "Today's Workout – Code Gym". Swipe to a section's summary, hear its title and "expanded".
4. Answer a section: double-tap the answer field, hear "text area". Type an answer.
5. Rate it: hear "How hard was Code Review for you?", then "Just right, toggle button, not selected". Double-tap, hear "selected".
6. Only if a save fails: hear the failure message read out without focus moving.
7. Duck: double-tap "Stuck? Talk it through", hear "collapsed" change to "expanded". The text field reads as "What are you stuck on?". Ask, hear "Thinking…", then the reply read automatically.
8. Submit: the button reads "Submit answers, right arrow". The page reloads onto the submitted state once the review is done. Rotor to Headings, expect "Claude's Review".
9. Review: swipe through a section's rating pill and feedback. "Explain this differently" announces "A different explanation was added above." when done.
10. Setup, Exercise mix: double-tap the "Exercise mix" summary, hear "expanded". On a slider, hear the kind's name, a value, then its stop ("Much less" to "Much more"). Swipe up or down to change it.
11. Tick "Exclude", hear "checkbox, checked". A save warning, if any, is announced without moving focus.

Worth listening for in steps 7 and 10: the duck's field is named only by its
placeholder, and the sliders set no `aria-valuetext`, so VoiceOver may read the
position as a number or a percentage before the word. If either reads badly, both are small fixes.

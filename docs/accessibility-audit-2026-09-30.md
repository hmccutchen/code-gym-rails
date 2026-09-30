# Accessibility audit, Tier 3, 2026-09-30

The WCAG 2.2 AA items left after the 2026-09-29 audit: semantics, touch
targets, zoom and reflow, the login code, and text spacing, plus a VoiceOver
checklist to run by hand. The first pass fixed page titles and the login code
field's error and expiry messages. The second pass, approved on 2026-09-30,
fixed the reflow, target size, landmark and heading findings below, the duck
and follow-up fields' labels, and the sliders' spoken values. Section 7 covers
the one item still on hold: a real heading for each dashboard section.

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
| `<main>` | Was missing on every page. **Fixed:** `<main id="main-content">` inside the layout's `div.container`. |
| `<header>` | None. The brand and menu live inside `<nav>`, which is fine as long as `<main>` exists. |
| `<nav>` | Present on every page, the login page included. |
| Skip link | Was missing. **Fixed:** "Skip to content" is the first Tab stop on every page that shows the nav. It shows only when focused and moves focus to `<main>`. |
| One `<h1>` per page | Yes, on every page. |

Heading order:

| Page | Headings | Gap |
| --- | --- | --- |
| Login, Setup, Account, Learn concept, Progress | h1, then h2 where present | none |
| Learn index | h1, h2 per bucket, h3 per group | none |
| Dashboard, answer form | h1, then an h2 per section, inside its fold `<summary>` | Was h1 only, with no way to jump between sections by heading. **Fixed**, see section 7. |
| Dashboard, submitted | h1 "Today's Workout", h2 "Claude's Review", h3 per section | Was h1 to h3. **Fixed.** |
| History | h1, h2 per day, h3 per reviewed section | Was h2 to h4. **Fixed.** |

The fix: `page_title` in `ApplicationHelper` sets the page's name, and the
layout's `<title>` renders it through `document_title`, so a page without one
still reads "Code Gym". `spec/requests/page_titles_spec.rb` covers each page.

What changed:

- The layout wraps the flash messages and each page's content in
  `<main id="main-content" tabindex="-1">`, inside `div.container`. The
  `tabindex` lets the skip link move focus there as well as scroll. Main shows
  no focus ring, since a ring around the whole page would read as an error.
- The skip link sits before `<nav>`. It is off screen until focused, then
  appears at the top left, fixed, so the nav does not move.
- "Claude's Review" on the submitted dashboard is an `<h2>`, and each
  section's review heading (`shared/_ai_review`, used by the dashboard and by
  History) is an `<h3>`. Sizes come from the same inline style and the
  `.review-block h3` rule, so they look as before.

Checked in Chromium at 390px on the answer form: Tab from the top of the page
lands on the skip link (visible, 47px tall). Enter moves focus to `<main>`, and
the next Tab goes to "Generate new set", the page's first control, not back to
the nav. The jump leaves `<main>`'s top at 56px, exactly the
`scroll-padding-top` the dashboard sets for its sticky progress bar (the bar's
height plus the focus ring's reach). The bar sits lower on the page at that
point, so nothing covers the target. `[data-pull-content]` is still the
`div.container`, now holding `<main>`, so pull-to-refresh moves the same area;
its system spec passes unchanged.

Specs: `spec/requests/page_structure_spec.rb` (landmark, skip link target,
heading order on both pages, labels, slider values) and
`spec/system/small_screen_layout_spec.rb` (skip link focus).

## 2. Touch targets (390px wide)

WCAG 2.5.8 asks for 24 by 24 CSS px, or enough space around a smaller target
(a 24px circle centred on it must not touch another target). Inline links and
terms inside a sentence are exempt. Measured sizes are width by height.

**Under 24px:**

| Element | Size | Where | Passes by exception? |
| --- | --- | --- | --- |
| Exercise mix "Exclude" checkboxes | 13 × 13 (label 72 × 22) | Setup | **No.** Too close to the slider and the lock box. **Fixed:** label 24 tall. |
| Exercise mix "Lock at this level" checkboxes | 13 × 13 (label 316 × 22) | Setup | **No. Fixed:** label 24 tall. |
| "Adjust set size to my recent completion" checkbox | 13 × 13 (label 342 × 22) | Setup | **No. Fixed:** label 24 tall. |
| Exercise mix difficulty radios | 13 × 13 (label 187 × 22) | Setup | Yes, by spacing. Label now 24 tall too. |
| Learn "Only ones I've seen" checkbox | 13 × 13 (label 157 × 26) | Learn index | Yes, and its label is 26 tall |
| Section fold summaries ("1 — Code Review") | 358 × 19 | Dashboard | Yes, by spacing. **Now 44 tall.** |
| "← All concepts" link | 106 × 17 | Learn concept | **No.** Sits against the next control. **Fixed:** 25 tall. |
| Glossary terms | 91–114 × 18 | Dashboard, history | Yes, inline in a sentence |
| Setup's provider links (console.anthropic.com, aistudio.google.com) | 114–128 × 15 | Setup | Yes, inline in a sentence |

Counting the label as part of the checkbox's target, as a click on it toggles
the box, still leaves the lock, exclude and set-size rows 22px tall.

**Between 24 and 44px:**

| Element | Size | Where |
| --- | --- | --- |
| Rating buttons | 111 × 33, **now 44 tall** | Dashboard |
| Submit answers | 169 × 32, **now 44 tall** | Dashboard |
| Menu button | 40 × 40, **now 44 × 44** | Every signed-in page |
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

What changed:

- **The Setup checkboxes and radios.** Their labels (`.mix-exclude`,
  `.mix-lock`, the difficulty radios' labels, and the set-size label) get
  `min-height: 24px`. A tap on the label toggles the box, so the label is the
  target. The boxes themselves are unchanged, so they look the same; each row
  is 2px taller.
- **"← All concepts"** is `inline-block` with 4px of vertical padding, 25px
  tall. Its line was already that tall, so nothing moves.
- **Rating buttons and Submit answers** get more vertical padding, to 44px.
  Widths, font and colors are unchanged. Padding in rem plus a fixed amount, so
  at larger text sizes they grow past 44 with their text, as before.
- **The section fold summaries** get 12.5px of padding above and below (44px
  tall), with matching negative margins, so the label stays exactly where it
  was and the target grows into the space around it. A system spec checks
  that a folded section's label still sits at the section's top padding.
- **The menu button** is 44 × 44px, set in px rather than rem. See section 3
  for why. At the default text size it was 40px; at the largest it was 56px
  and is now 44px.

Added vertical space at 390px, answer form, measured before and after:

| | Before | After | Added |
| --- | --- | --- | --- |
| Section summary | 19 | 44 | 0 (negative margins) |
| Rating row | 33 | 44 | 11 per section |
| Submit answers | 32 | 44 | 12, once per page |
| Folded section | 61 | 61 | 0 |
| Whole page, 4 sections | 3363 | 3419 | 56 |

So each open section is 11px taller, from the rating row alone. At 1024px the
page grows by the same 56px.

The rest between 24 and 44 are left as they were.

## 3. Zoom and reflow

The viewport meta tag is `width=device-width, initial-scale=1,
interactive-widget=resizes-content`. It sets no `user-scalable=no` and no
`maximum-scale`, so pinch zoom works. The iOS input-zoom fix uses a 16px input
font size (`--input-font-size`) and does not restrict zoom.

Horizontal scrolling found in the first pass, at 320px (the same as 400% zoom
on a 1280px window):

| Page | Default display settings | Largest display settings | Cause |
| --- | --- | --- | --- |
| Every signed-in page | scrolled, 344px wide | scrolled, 373px wide | The brand left no room for the menu button. |
| Submitted dashboard | scrolled, 458px wide (also at 390px) | scrolled, 638px wide | `.submit-row` did not wrap. |
| History, largest settings | | scrolled | The follow-up input overflowed its panel. |

What changed:

- **`.submit-row` wraps.** With four sections at 1024px the row does not
  fit on one line either, so before this change the browser squeezed each
  rating pill until its text broke over two lines ("Pattern: just / right").
  Now the "Finish review" button moves to a second line and each pill keeps
  its text on one line. That is the one visible difference at wide widths. A
  row that fits on one line, such as a two- or three-section day at desktop
  width, looks the same as before.
- **The nav logo shrinks** on narrow screens. Inside the nav's collapsed
  state (the same container query that shows the menu button), the brand may
  shrink, and the logo absorbs all of it. `object-fit: contain` keeps its
  aspect ratio, and the nav's height does not change. The wordmark "Code Gym" keeps its size. The logo is 112px
  wide wherever it fits; measured widths where it does not:

  | | Default settings | Largest settings |
  | --- | --- | --- |
  | 390px | 112 (unchanged) | 96 |
  | 320px | 52 | 26 |

  At the largest settings on a 320px screen, the logo is 26px wide. That is
  the room left once the 32px wordmark and the 44px button fit. The
  alternative would be shrinking the wordmark too, which this pass did not
  do. The menu button went from rem to px for the same reason: at 140% text
  a 2.75rem button would be 62px and leave no room for the logo at all.
  `image-rendering: pixelated` is not set anywhere in the app today (checked
  in `app/`, `config/` and `lib/`), so there was nothing to keep. The browser
  scales the logo smoothly, as it did before. Setting it would change how the
  logo looks at every size, so it was left out.
- **The follow-up and duck fields** get `min-width: 0`, so they shrink with
  their row instead of overflowing it.
- Two more overflows showed up only at 320px with the largest settings plus
  the text-spacing override, a combination the first pass did not measure:
  Progress rows (a long concept name plus "not yet") and the email address on
  Account. Progress rows now wrap (`flex-wrap: wrap`), so the status word drops
  to its own line when it does not fit, and the email breaks anywhere
  (`overflow-wrap: anywhere`).

Measured again after the changes, every page at 320px and 390px, each with
and without the text-spacing override, and the eight signed-in pages with both
the default and the largest display settings (72 combinations over ten pages;
the two login pages have no user to hold settings): **no page scrolls
sideways**, no text is clipped, and no heading level is skipped. Every page
has one `<main>` and a skip link. `spec/system/small_screen_layout_spec.rb`
pins the menu button at 320px (both text sizes), the submitted row at 390px,
and the 44px targets.

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
- After a wrong code the field carries `aria-invalid="true"`.
- Only an alert from checking the code is tied to the field. The pending page
  also offers "request a new code", and an error from that form (an invalid
  address, or too many requests) says nothing about the code. It stays in the
  flash but is not read as part of the code field, and the field is not marked
  invalid. Refusing a code attempt for being over the limit is tied to the
  field, since it is about that form, but is not marked invalid, since no code
  was checked. (Found by Copilot's second review.)

Request specs cover each case: the wrong code and the notice in
`spec/requests/sessions_spec.rb`, which also covers a failed new-code request,
and both rate limits in `spec/requests/login_rate_limit_spec.rb`.

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
- The spacing made the section 3 overflows worse: with the largest display
  settings plus the override, the menu button was pushed off screen at 390px,
  and the submitted dashboard's row reached 734px wide. After the section 3
  fixes, no page scrolls sideways under the override at 320px or 390px.

## 6. VoiceOver checklist (installed app on iPhone)

These are expected results, not results. Nothing here was run with VoiceOver.

1. Log in: on the email field, hear "Work email, star, text field, required" (the asterisk is part of the label). After Send code, focus lands on the code field: hear "6-digit code from the email, text field", then the "check your email … expires in 15 minutes" message.
2. Enter a wrong code: back on the code field, hear the field's label, "invalid data", and "Incorrect or expired code. Try again, or request a new one below."
3. Dashboard: the page title is announced as "Today's Workout – Code Gym". Swipe to a section's summary, hear its title and "expanded".
4. Answer a section: double-tap the answer field, hear "text area". Type an answer.
5. Rate it: hear "How hard was Code Review for you?", then "Just right, toggle button, not selected". Double-tap, hear "selected".
6. Only if a save fails: hear the failure message read out without focus moving.
7. Duck: double-tap "Stuck? Talk it through", hear "collapsed" change to "expanded". The text field reads as "What are you stuck on?, text field", and keeps that name after you start typing. Ask, hear "Thinking…", then the reply read automatically.
8. Submit: the button reads "Submit answers, right arrow". The page reloads onto the submitted state once the review is done. Rotor to Headings, expect "Claude's Review" (heading level 2), then one level 3 heading per section.
9. Review: swipe through a section's rating pill and feedback. "Explain this differently" announces "A different explanation was added above." when done.
10. Setup, Exercise mix: double-tap the "Exercise mix" summary, hear "expanded". On a slider, hear the kind's name, then its stop word as the value ("Default, adjustable"). Swipe up or down, hear the new stop ("Less", "Much less").
11. Tick "Exclude", hear "checkbox, checked". A save warning, if any, is announced without moving focus.
12. Any signed-in page, with a keyboard attached: the first Tab shows "Skip to content" at the top left. Activating it moves VoiceOver to the page's first heading.
13. Rotor to Landmarks: expect "navigation" and "main".

Steps 7 and 10 were fixed rather than left to listen for:

- **The duck's field** was named only by its placeholder. Chrome's
  accessibility tree gave its name as "What are you stuck on?" from the
  `placeholder` source, the fallback that disappears for some screen readers
  once text is typed. It now has a visually hidden `<label for>` with the same
  words, and Chrome reports the name from the label, with the placeholder
  superseded. The review's follow-up field had the same problem and got the
  same fix ("Ask a follow-up about this feedback"), with an id unique per
  response and section.
- **The Exercise mix sliders** exposed the value 2 (of 0 to 4) and no value
  text. The stop word reached assistive technology only as a description
  (`aria-describedby` on the `<output>`). Each slider now renders
  `aria-valuetext` with its stop word, and the script updates it on every
  move. Chrome's tree reads "Coding Challenge, slider, Much less" after
  pressing Home. The `aria-describedby` is gone, since it would repeat the
  same word.

## 7. A heading for each dashboard section

Implemented after the VoiceOver checklist was run, with the markup
recommended below: each answer-form section's title is an
`<h2 class="section-title">` inside its `<summary>`, and the status line stays
outside the heading. `.section-label .section-title` resets the heading's
font and margin to the label's, and screenshots of the section header before
and after are pixel-identical at 390px and 1024px, with the default and the
largest display settings. Chrome's accessibility tree now lists each section
as a level-2 heading under "Today's Workout", and each summary's name is
unchanged. `spec/requests/page_structure_spec.rb` holds each summary to one
`h2` and no `role`, and the answer form to no skipped heading level.

The submitted day's read-only render is unchanged: its labels are still plain
text. That render is shared with History, where a section heading would sit
at level 3 rather than 2, so it needs its own decision.

The research that led to the recommendation follows.

**What the browser exposes.** Measured in this environment's Chromium through
the DevTools accessibility tree, on a test page. A `<summary>` maps to the
`DisclosureTriangle` role. An `<h2>` inside it stays in the tree as a real
heading, level 2, a child of the disclosure triangle. The same holds for
`<span role="heading" aria-level="2">`. The summary's accessible name is all
its text, so a summary holding a heading and a status reads "Code Review in
progress". HTML-AAM maps `summary` to a button role on platforms without a
disclosure-triangle role, and to the disclosure triangle in the Mac API
([W3C HTML-AAM](https://www.w3.org/TR/html-aam-1.0/)). A button role's
children are presentational, which is where the risk comes from.

**What screen readers do with it**, from published testing:

- VoiceOver announces a heading inside `<summary>` and lets you navigate to it
  (rotor and heading navigation). JAWS with Chrome and Firefox does not
  ([Scott O'Hara, "The details and summary elements, again"](https://www.scottohara.me/blog/2022/09/12/details-summary.html)).
- Browsers that expose `summary` as a plain button strip the child heading's
  role, so it is not treated as a heading. Adding `role="button"` to the
  summary yourself does the same in every browser, including Safari
  ([Hassell Inclusion, "Accessible accordions part 2"](https://hassellinclusion.com/blog/accessible-accordions-part-2-using-details-summary/)).

These sources could not be fetched from this environment, so the two lines
above come from their published summaries rather than a fresh reading. The
Chromium result is measured. How Safari and VoiceOver on iOS handle the current
release is exactly what the checklist run will show.

**Recommendation:** an `<h2>` inside the existing `<summary>`, holding the
section title only, with the status span left outside it:

```erb
<summary class="section-label">
  <h2 class="section-title"><%= label %></h2>
  <span class="section-status">…</span>
</summary>
```

- VoiceOver, the target here, keeps the heading, and the summary still works
  as the disclosure. The layout already styles `.section-title`, so the look
  stays the same once `h2` gets the label's font size and weight.
- `<summary>` must stay the details' first child, so the heading cannot sit
  outside it and still be the toggle. A heading outside, above a
  `<details>` whose summary repeats the title, doubles every section title for
  a screen reader and adds a second target.
- Keep `role="button"` off the summary. It would erase the heading.
- The one known loss is JAWS on Windows, which will not list these headings.
  That is no worse than today, where there is no heading at all.

On the VoiceOver run, check: the rotor's Headings list shows each section
title at level 2, reading a summary says the title, the status, and
"expanded" or "collapsed", and double-tapping a heading in the rotor still
toggles the section.

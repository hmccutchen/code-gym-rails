# iOS input-focus zoom and keyboard behaviour

Date: 2026-08-13
Branch: `fix/ios-input-focus-zoom`, from `main`.

CSS and one meta attribute. No JavaScript, no behaviour change to anything
other than the rendered size of six form controls.

## The problem

On iPhone — Safari and the installed standalone PWA alike — focusing a textarea
makes the layout shift and fail to cleanly restore. Two causes were suspected;
investigation confirmed both.

### Cause 1: every focusable control is under 16px

iOS auto-zooms any focused input or textarea whose computed font-size is below
16px. No `html` or `:root` font-size is set, so `rem` resolves to the browser
default of 16px, and every control in the app lands under the threshold:

| Control | Rule | Computed |
| --- | --- | --- |
| `textarea.answer` | `.95rem` | 15.2px |
| `textarea.code-answer` | `.85rem` | 13.6px |
| `.self-explanation-input` | `.85rem` | 13.6px |
| `.follow-up-input` | `.85rem` | 13.6px |
| `.duck-input` | `.85rem` | 13.6px |
| `.name-editor-input` | `inherit` (from `nav .nav-links`, `.9rem`) | 14.4px |

No media query raises any of them. This is the primary cause and accounts for
the zoom on every text entry point in the app, not just the answer box.

### Cause 2: the viewport does not resize around the keyboard

`app/views/layouts/application.html.erb:5` reads
`width=device-width, initial-scale=1` with no `interactive-widget`, so the
default `resizes-visual` applies: the document scrolls to reveal the field
above the keyboard rather than the layout resizing around it. That is the
"unmoored" feeling relative to a native app.

**Expectation management.** `interactive-widget=resizes-content` is
well-supported in Chromium but, to the best of current knowledge, not
implemented in WebKit — which is both iPhone Safari and the standalone PWA.
The attribute is spec-correct, costs nothing, and benefits Android and any
future WebKit release, but the improvement actually felt on an iPhone will come
almost entirely from Cause 1. It is included on those terms, not as the fix.

Nothing to undo: the tag carries no `maximum-scale` or `user-scalable=no`
today, so pinch-zoom is already intact and stays that way.

## The fix

### One custom property, six call sites

```css
:root {
  /* iOS auto-zooms a focused input below 16px, which shifts the layout and
     doesn't cleanly restore. max() keeps the floor without overriding a user
     who has set a larger default. */
  --input-font-size: max(1rem, 16px);
}
```

Each of the six rules above becomes `font-size: var(--input-font-size)`.

**`max(1rem, 16px)` rather than either alone.** iOS's threshold is 16 *CSS
pixels*, absolute. A flat `1rem` reintroduces the bug for anyone whose browser
default is below 16px; a flat `16px` overrides anyone who raised their default
for readability. `max()` gives the floor without the cap.

**Applied unconditionally, with no media query.** The trigger is a font-size
threshold, not a screen-size condition — an iPad at 834px and a narrow desktop
Safari window zoom the same way. Gating on `max-width: 600px` would leave the
same bug in less-visited places.

**Edited in place rather than added as one grouped selector.** `textarea.code-answer`
has specificity `(0,1,1)`; a trailing `.code-answer` rule would silently lose to
it. Editing each rule avoids leaving a specificity puzzle behind.

### The meta tag

```erb
<meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
```

Existing values preserved. Nothing else added.

## Accepted visual change

`textarea.code-answer` goes 13.6px → 16px, an 18% increase, and it no longer
matches `pre.snippet` (`.85rem`), which stays as it is. The two were previously
the same size: you wrote your answer in the same type as the code under review.

Accepted deliberately. They sit in structurally different containers — a dark
bordered code block versus a bordered input — so they read as distinct objects
regardless of matched size, and `code-answer` only appears on challenge days,
one of four third-slot kinds. Preserving the pairing would mean leaving the
zoom bug in the section that receives the most typing.

**This must be called out in the PR description** so it is reviewed
deliberately rather than discovered after merge.

## Consequences to check in a browser, not decide in code

- `.name-editor-input` is `width: 9rem` in the nav. At 16px fewer characters
  are visible at once. It is an `<input>`, so text scrolls rather than clips.
- `.duck-input` and `.follow-up-input` are `flex: 1` in flex rows with buttons,
  and `.duck-form` sets `flex-wrap: wrap`. A larger intrinsic minimum width may
  make that row wrap one breakpoint earlier.

If the row does wrap earlier, **let it wrap.** Shrinking an input back below
16px to avoid a cosmetic wrap would reintroduce the bug this change exists to
fix.

## Regression guard

A system spec asserts every focusable control computes to at least 16px. This
bug is invisible on desktop and only manifests on iOS, so nothing else in the
suite would catch a regression — and the failure mode that matters is someone
adding a *seventh* input without ever encountering the custom property. A
comment cannot catch that; a spec iterating the controls on a rendered page
can.

It runs in the existing `system_test` CI job against the `FakeService` test
user, like every other system spec.

## Verification

**Verifiable here:** all six controls compute ≥16px at a 375px viewport, the
meta tag renders with all three values, and neither of the two layout
consequences above is worse than cosmetic.

**Requires the author's device, and is not claimed until then:** that iOS
actually stops zooming, and how WebKit treats `interactive-widget`. To be
checked in both Safari and the installed standalone PWA, since the two contexts
can differ: focus a textarea, confirm no zoom, type, dismiss the keyboard,
confirm the layout returns where it started. The challenge section deserves a
specific look, being the one with a visible size change.

## Out of scope

- Any non-input typography, including `pre.snippet` and every code block.
- The mobile padding work.
- `maximum-scale` / `user-scalable=no` — these suppress zoom by disabling
  pinch-zoom entirely, an accessibility regression. The 16px floor achieves the
  same result without it.
- `transform: scale()` on inputs, which breaks caret positioning.
- Any JavaScript scroll or keyboard-height workaround.
- This spec is not committed to the PR; planning docs stay out of PRs by
  standing preference, and it is removed before the branch is pushed.

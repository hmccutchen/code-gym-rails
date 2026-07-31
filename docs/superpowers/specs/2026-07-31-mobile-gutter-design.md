# Mobile Gutter

## Problem

The app has no mobile styling at all. The layout's `<style>` block contains one
media query (`hover: hover`), and nothing else adapts below desktop width.

The visible cost is horizontal space. `.container` contributes `1.5rem` of side
padding and `.section` contributes another `1.5rem`. They nest, so problem-set
text sits inside `3rem` (48px) of chrome per side. On a 375px phone that is
roughly a quarter of the screen, and problem text — which is prose plus wrapped
code — is squeezed into what remains.

That padding exists for a reason on desktop: it keeps problem-set text from
crowding the card edge. The mobile and desktop views do not have to match, so
the fix is a breakpoint, not a global reduction.

## Scope

In scope: the mobile gutter for section cards.

Explicitly out of scope:

- **Parsons drag styling.** An earlier draft of this spec reworked the drag
  preview so only bare text moved between stable code panels. That is dropped —
  the current whole-block drag suits the mobile feel, and the section is left
  exactly as it is. If it is revisited later it gets its own spec.
- Nav links, rating button rows, follow-up inputs, type scale, and tap-target
  sizing. These may have their own mobile problems; folding them in would make
  the diff unreviewable. Deliberately deferred.

No Ruby, no markup, no JavaScript, and no data-shape changes. The entire change
is one CSS media query in the layout's shared `<style>` block.

## Design

The breakpoint is 600px: phones only. Small tablets and landscape phones keep
the desktop treatment.

Section cards break out of the container gutter rather than the container
zeroing its own padding:

```css
@media (max-width: 600px) {
  .section {
    margin-inline: -1.5rem;
    padding: 1.25rem 1rem;
    border-radius: 0;
    border-left: none;
    border-right: none;
  }
}
```

`.container` keeps `padding: 0 1.5rem` untouched. This is the key decision: the
negative margin is scoped to `.section`, so nav, flash messages, page headings,
and every non-card page (account, login) are unaffected and need no audit. The
alternative — setting the container gutter to 0 under the breakpoint — would
push the nav and every heading flush against the screen edge and require
re-padding them individually.

Interior horizontal chrome drops from `3rem` to `1rem` per side, returning about
64px of text width on a 375px screen.

Square corners and no side borders: a rounded card flush against the screen edge
reads as a rendering bug. Top and bottom borders stay so consecutive cards still
separate visually.

This rule lives in the layout's shared `<style>` block beside the existing
`.section` rule, not in a per-page block, because sections render on both the
dashboard and the history page — the same reason given in the existing comment
above the shared submission-rendering styles.

Because the rule targets `.section` and nothing else, it applies uniformly to
every section kind (code review, pattern, challenge, architecture, security
review, Parsons) with no per-kind handling.

### History page

On `/history` the shared section partials render inside `.history-entry`
(`app/views/history/index.html.erb`), which is itself inside `.container` — two
padded ancestors rather than one. A `-1.5rem` margin cancels only the inner one,
so the cards would overhang the entry's rounded border instead of reaching the
screen edge.

The entry wrapper therefore gets the same full-bleed treatment on phones, and
nested `.section` cards are reset to `margin-inline: 0` with their rounded
corners and side borders restored, so they stay inset and keep the card-in-card
look they have on desktop. These rules live in the history page's own `<style>`
block, not the layout, because the selectors are page-specific.

This was found during final review, after the rest of this spec was written.

## Testing

This project has no Capybara, Selenium, or system-spec tooling, and CSS layout
cannot be asserted programmatically here. Existing view coverage is request
specs asserting on rendered markup, and the new assertion follows that
convention.

Automated:

- `spec/requests/dashboard_spec.rb`: assert the layout's `@media (max-width:
  600px)` block contains `.section { … margin-inline: -1.5rem }`.
- `spec/requests/history_spec.rb`: assert the history page's own block contains
  both `.history-entry { … margin-inline: -1.5rem }` and `.history-entry
  .section { … margin-inline: 0 }`.

Each assertion pins a declaration to its selector rather than matching either in
isolation. Matching the breakpoint alone is worthless on the history page — the
layout's block renders there too, so that string survives even if the page's
entire media query is deleted. Matching a bare selector is equally worthless:
`.history-entry .section` also appears in the border rules, so the one
declaration that prevents the double break-out could be removed with the test
still green. Both weaknesses were real and were caught in review; the
replacements were verified by deleting each declaration in turn and confirming
the corresponding test fails.

These tests guard that the rules ship, not that they render correctly. Only the
manual checks below can establish the latter.

Manual, to be recorded as explicit steps in the implementation plan:

- DevTools at 375px on the dashboard: section cards reach both screen edges,
  nav and flash messages keep their gutter, no horizontal scrollbar appears.
- Same check on the history page, which renders the shared section partials in
  their submitted state.
- Confirm at 601px and above that nothing changed.

## Risks

Low. The change is a single media query affecting one selector, with no Ruby,
markup, or JavaScript involved. The worst realistic outcome is a visual
regression. The one value worth a second look in review is the `-1.5rem` margin:
if it ever drifts out of sync with the `.container` padding it is meant to
cancel, the result is either a visible inset or a horizontal scrollbar.

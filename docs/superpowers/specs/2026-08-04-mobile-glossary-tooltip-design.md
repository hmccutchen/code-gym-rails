# Viewport-Safe Glossary Tooltips on Mobile

**Date:** 2026-08-04
**Status:** Approved

## Problem

On a phone, tapping a glossary term often reveals a tooltip whose right edge runs
past the screen, cutting off the definition with no way to scroll or pan to the
rest of it.

The cause is in the layout's tooltip rule:

```css
.gloss-term { position: relative; }
.gloss-term::after {
  position: absolute; left: 0; bottom: 100%;
  width: max-content; max-width: 16rem;
}
```

The panel is anchored to the term's **left edge** and grows rightward up to
`16rem` (256px). Nothing clamps it to the viewport. `.container` is
`max-width: 800px` with `1.5rem` side padding, so on a 375px phone the usable
width is about 327px — any term starting more than ~70px from the left pushes a
full-width panel off the right edge, and terms late in a line are worst. The
only existing breakpoint (`max-width: 600px`) does not touch `.gloss-term`.

## Constraint That Shaped the Design

The panel should span the container's width so it always fits. That cannot be
done in pure CSS here: because `.gloss-term` is `position: relative` and is an
*inline* element, the tooltip's containing block is the term's own line box, so
`left: 0` means "the term's left edge." Moving the positioning context to a
block-level ancestor would pin the panel horizontally to the container, but the
vertical offset (`bottom: 100%`) would then resolve against that ancestor too,
detaching the panel from the term's line. CSS gives us one or the other.

Anchor positioning (`anchor-name`/`position-anchor`) would solve this natively
but lacks the browser support this app can rely on, iOS Safari in particular.

So the horizontal geometry is computed once per open, in JavaScript, and handed
to CSS through custom properties. The app already requires JavaScript for the
dashboard (rating, autosave, progress, submit), and a delegated `.gloss-term`
handler already exists — this extends that handler rather than adding a new one.

## Design

### 1. CSS: mobile-only media query

In `app/views/layouts/application.html.erb`, alongside the existing
`.gloss-term` rules:

```css
@media (max-width: 600px) {
  .gloss-term::after {
    left: var(--gloss-shift, 0);
    width: var(--gloss-width, max-content);
    max-width: none;
  }
}
```

Each custom property falls back to the value the rule uses today. If the
JavaScript never runs, rendering is identical to current behavior, so this
cannot regress. The desktop hover path is untouched: it is guarded by the
existing `@media (hover: hover) and (pointer: fine)` query, and above 600px this
new rule does not apply at all.

Vertical positioning (`bottom: 100%`) is deliberately unchanged, which is what
keeps the panel attached to the term's own line.

### 2. JavaScript: measure on open

Extend the existing delegated handler. When a term opens, measure the
`.container` content box and the term, then set both properties on the term so
the panel's edges land on the container's content edges:

```js
const positionPanel = (term) => {
  const container = term.closest(".container");
  if (!container) return;
  const box = container.getBoundingClientRect();
  const pad = parseFloat(getComputedStyle(container).paddingLeft) || 0;
  term.style.setProperty("--gloss-width", `${box.width - pad * 2}px`);
  term.style.setProperty("--gloss-shift", `${box.left + pad - term.getBoundingClientRect().left}px`);
};
```

Called only when a term is being opened, from the existing `toggleTerm`. Terms
outside a `.container` fall back to current behavior rather than throwing.

The properties are not cleared on close. They are only read while the panel is
visible and are recomputed on every open, so a stale value can never be
displayed. Reading `paddingLeft` and doubling it assumes symmetric side padding,
which matches `.container`'s `padding: 0 1.5rem`.

### 3. JavaScript: recompute on resize

Rotating a phone while a tooltip is open would leave the measured values stale.
A resize listener recomputes the geometry for whichever term is currently open:

```js
window.addEventListener("resize", () => {
  const open = document.querySelector(".gloss-term.gloss-open");
  if (open) positionPanel(open);
});
```

## Testing

A Playwright system spec at a 375px-wide viewport (`spec/system/`) opens the
`loyalty tier` tooltip — already present in `FakeService`'s `code_review`
glossary — and asserts the panel's left edge is at or right of the viewport's
left edge and its right edge is at or left of the viewport's right edge. This
tests the reported symptom directly rather than asserting on CSS text.

No markup changes, so `spec/helpers/glossary_helper_spec.rb` and the glossary
assertions in `spec/requests/dashboard_spec.rb` remain valid and untouched.

## Out of Scope

Vertical overflow when a term sits on the first visible line: `bottom: 100%`
could place the panel above the viewport top. Not reported, and it needs a
separate flip-below rule. Deliberately excluded.

Desktop hover behavior, tooltip styling, the glossary helper, and the closed
concept vocabulary are all unchanged.

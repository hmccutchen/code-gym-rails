# Mobile Gutter and Parsons Drag Styling

## Problem

Two unrelated-looking complaints with a shared cause: the app has no mobile
styling at all. The layout's `<style>` block contains one media query
(`hover: hover`), and nothing else adapts below desktop width.

1. **Horizontal space.** `.container` contributes `1.5rem` of side padding and
   `.section` contributes another `1.5rem`. They nest, so problem-set text sits
   inside `3rem` (48px) of chrome per side. On a 375px phone that is roughly a
   quarter of the screen, and problem text — which is prose plus wrapped code —
   is squeezed into what remains.

2. **Parsons drag feel.** Dragging a block moves the entire `<li>`: the code
   text, its dark panel, its border, and the ↑/↓ button column all travel with
   the cursor. The list visibly comes apart during a move. The intent is that
   the code panels read as a stable stack of slots and only the text is what
   gets rearranged.

## Scope

In scope: the mobile gutter for section cards, and the Parsons drag styling.

Explicitly out of scope: nav links, rating button rows, follow-up inputs, type
scale, and tap-target sizing. Those may have their own mobile problems; folding
them in would make the diff unreviewable. They are deliberately deferred.

No Ruby, no markup, and no data-shape changes. Every change is either CSS in the
layout's shared `<style>` block or an option passed to `Sortable.create`.

## Design

### 1. Mobile gutter (max-width: 600px)

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
dashboard and the history page.

### 2. Parsons drag: stable slots, bare text moves

The blocks continue to reorder as whole `<li>` elements — the markup and the
`parse_order` / hidden-field contract are unchanged. The "fixed slots" effect is
produced entirely by styling, and is visually indistinguishable from real fixed
slots because every panel shares one background treatment.

`Sortable.create` in `app/views/responses/_parsons_problem_section.html.erb`
gains four options:

```js
Sortable.create(list, {
  animation: 150,
  forceFallback: true,
  ghostClass: "parsons-ghost",
  dragClass: "parsons-dragging",
  delay: 150,
  delayOnTouchOnly: true,
  onEnd: () => list.parsonsSync?.()
});
```

`forceFallback: true` is load-bearing, not a preference. With native HTML5
drag-and-drop the browser snapshots the dragged element *before* `dragClass` is
applied, so the moving image cannot be styled. Forcing SortableJS's fallback
clone makes the moving element a real, styleable DOM node and makes mouse and
touch behave identically.

`delayOnTouchOnly: true` with a 150ms `delay` keeps a vertical finger swipe
scrolling the page instead of immediately hijacking into a drag. Mouse dragging
is unaffected.

Companion CSS in the layout's shared block:

```css
.parsons-ghost pre.snippet code,
.parsons-ghost .parsons-controls { visibility: hidden; }
.parsons-dragging pre.snippet { background: transparent; border-color: transparent; }
.parsons-dragging .parsons-controls { visibility: hidden; }
.parsons-list:not(.parsons-list-readonly) .parsons-block:active { cursor: grabbing; }
```

The ghost is the placeholder at the drop position: it keeps its full code panel
but hides its text, so it reads as an empty slot. The drag clone is the element
following the cursor: transparent background, no border, controls hidden, so
only bare text moves. The column therefore always shows the same N panels
throughout a drag.

`visibility: hidden` rather than `display: none` or `opacity` — it preserves the
element's box so panel height does not collapse mid-drag.

Class assignment verified against the pinned `sortablejs@1.15.6` source rather
than assumed: `_appendGhost` applies `fallbackClass` *and* `dragClass` to the
cursor-following clone while explicitly removing `ghostClass` from it, and
`_dragStarted` applies `ghostClass` to the element left behind in the list. So
`dragClass` does reach the fallback clone, contrary to some secondhand
documentation. The clone is appended to `document.body`, outside the list, which
is why the `.parsons-dragging` rules must not be nested under `.parsons-list`.

Slots size to their content. Blocks that wrap to two or three lines on a phone
are taller than single-line blocks, and that is accepted: the stable background
plus the bare-text drag preview carry the effect without forcing a uniform
height that would leave large dead space around short blocks.

### 3. What is deliberately not touched

- The ↑/↓ buttons remain the baseline reorder mechanism and are unchanged. They
  matter more on mobile, where dragging is fiddly, and they are the only path
  when the SortableJS CDN import fails.
- The `catch {}` CDN-failure fallback is unchanged.
- `syncHiddenField` and the `order:` answer format are unchanged.
- The read-only submitted render (`.parsons-list-readonly`, with its green
  `.parsons-correct` / red `.parsons-misplaced` borders) is untouched. Every
  drag style is scoped so it cannot apply there: the cursor rule uses
  `:not(.parsons-list-readonly)`, and the ghost/drag classes are only ever
  applied by SortableJS, which is never instantiated on a submitted list.

## Testing

This project has no Capybara, Selenium, or system-spec tooling. Drag behavior
cannot be asserted programmatically, and this spec does not pretend otherwise.
Existing view coverage is request specs asserting on rendered markup, and the
new assertions follow that convention.

Automated:

- `spec/requests/dashboard_spec.rb`, inside the existing
  `parsons_problem third section` describe block: assert the rendered page
  includes `forceFallback`, `parsons-ghost`, and `parsons-dragging`, so the
  options cannot be silently dropped in a later edit.
- `spec/requests/dashboard_spec.rb`: assert the layout renders
  `@media (max-width: 600px)`, guarding the mobile block against removal.
- `spec/requests/history_spec.rb`: assert a submitted Parsons render still
  carries `parsons-list-readonly` and does **not** carry `parsons-ghost` or
  `parsons-dragging`. This is the regression that actually matters, since the
  correctness borders share selectors with the drag styling.

Manual, to be recorded as explicit steps in the implementation plan:

- DevTools at 375px: confirm section cards reach both screen edges, nav and
  flash messages keep their gutter, and no horizontal scrollbar appears.
- Desktop drag: confirm only bare text follows the cursor and the source
  position shows an empty panel.
- Touch drag: confirm a vertical swipe scrolls the page, a press-and-hold starts
  a drag, and the reordered answer still saves.

## Risks

Low. The worst realistic outcome is a visual regression, not a broken submit:
the hidden-field sync, the answer format, and the up/down fallback are all
untouched. The two changes most worth a second look in review are the negative
margin (a wrong value produces a horizontal scrollbar) and `forceFallback`,
which changes the drag implementation path on desktop and should be exercised
manually in at least one browser before merge.

# pages/today.css

Today's styles. The layout links it on the dashboard only, through
`page_stylesheet` (`docs/decisions/page-stylesheets.md`). It holds what the
dashboard view's `<style>` held, then rules for the elements that carried a
`style` attribute: the regenerate row, the regeneration failure flash, the
"saves as you type" note, the trial banner, the empty and in-progress states
(`.today-state` and its parts) and the review heading row on a submitted day.

It styles the dashboard's own partials and the response partials the answer
form renders. Rules for a response partial that History also renders, such
as `.section` and the teaching hint, stay in the layout, since this sheet
loads on Today only.

## Sticky progress bar height

The sticky progress bar has a fixed height, `--progress-sticky-height`, so the
page can keep a focused field clear of it. A browser that scrolls a field to
the top edge stops at `scroll-padding-top`, which reads the same variable. The
focus ring's width and offset are added because the ring sits outside the
field.

## The progress fill

`.progress-fill` starts at `width: 0`; the answer-form controller sets its
width from the answered count once it connects.

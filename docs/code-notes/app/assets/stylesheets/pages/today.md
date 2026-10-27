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

## Under 600px

The phone rules sit in one `@media (max-width: 599.98px)` block at the end,
the width `phone_cards.css` gives the phone gutter, so the cards, the gaps and
the Submit row change together.

- **Cards.** `.today-page` takes the phone gutter from `phone_cards.css`, so
  each section is a card `max(16px, inset)` from the screen edge, as on the
  card pages. The title block, the progress bar and each section are 16px
  apart. A trial's banner gets its own margin there: its
  wider rule pulls it up into the title block's 2rem margin, which the 16px
  gap would otherwise cancel.
- **The side column.** It ends the page: the Submit row, with the button full
  width and 48px tall and the "saves as you type" note and the nudge centered
  under it, then the regenerate row.
- **No sticky Submit bar.** The phone board drew Submit as a bar stuck above
  the tab bar, and one was built. It was taken out before merge: with the
  progress bar already stuck at the top, a bar and the tab bar at the bottom
  left the answers scrolling through a narrow middle of the screen the whole
  time. It also needed space reserved above it for focus, a lifted save
  banner, a rule for while someone types and a minimum window height.
- **A held submit.** When a submit waits on another save, the answer-form
  controller scrolls its notice into view
  (`docs/code-notes/app/javascript/controllers/answer_form_controller.md`).

## At 900px and wider

- The page takes the 1040px column (`wide_page`). The day is a grid: the
  answers, then a 280px side column 24px to their right, drawn as a card.
- The side column stacks Submit, the note and the nudge, then "Generate new
  set" and "Start over", each full width and at least 44px tall.
- **Sticky only in a tall window.** In a window at least 640px tall the side
  column sticks 24px from the top while the answers scroll, so Submit stays in
  reach. Below that it scrolls with the page, so a short window is never left
  with a column it can't scroll to the end of. It is a side column, so it
  takes nothing from the answers' height, unlike the phone bar that was taken
  out.
- The progress bar stays in the main column, still stuck to the top, and the
  featured concept card stays below the day, as the dashboard's code note
  says.

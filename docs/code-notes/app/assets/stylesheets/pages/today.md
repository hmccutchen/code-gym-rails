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

## 600px and narrower

The phone rules sit in one `@media (max-width: 600px)` block at the end,
matching the layout's own `.section` rule at that width.

- **Cards.** `.today-page` takes the phone gutter from `phone_cards.css`, so
  each section is a card `max(16px, inset)` from the screen edge, as on the
  card pages. The title block, the regenerate row, the progress bar and each
  section are 16px apart.
- **The Submit bar.** The submit row becomes a bar stuck to the bottom of the
  window while the form is on screen, and settles in place after the last
  section. It holds the button, full width, the "saves as you type" note and
  the nudge. The nudge sits inside the bar so a refused submit's sentence,
  which takes focus, shows where the reader is rather than at the end of the
  form.
- **`position: sticky`, not `fixed`.** Pull-to-refresh moves
  `.container[data-pull-content]` with a `transform`, and a transform makes a
  fixed element position itself against the container instead of the window,
  so a fixed bar would jump to the end of the page during a pull.
- **Two bottom offsets.** In the home-screen app at phone width the tab bar
  covers the bottom of the window, so the bar sits on top of it; in a browser
  tab it sits at the bottom and pads itself clear of the home indicator. Both
  come from the layout's `--tab-bar-clearance` and `--bottom-safe-inset`
  (`docs/decisions/home-screen-app.md`), so the standalone test stays in one
  place.
- **It lets go while someone types.** While an answer field or the duck's
  field has focus the bar is static. On a phone whose keyboard shrinks the
  window, a stuck bar would take a third of what is left and could cover the
  line being typed.
- **What it covers.** A focused control scrolled into view stops above the
  bar (`scroll-padding-bottom`), and a failed save's message is lifted above
  it. Both use `--submit-bar-reach`, a deliberate overestimate (10rem plus the
  offsets): the bar holds three lines of rem-sized text and the nudge wraps
  at narrow widths, so its height isn't fixed. Too much only leaves a little
  more space; too little would hide the control. `today_phone_layout_spec`
  checks it at 320px with the largest text.


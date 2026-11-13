# spec/system/daily_kind_swap_spec.rb

## Reduced motion for every example

The `before` block asks Chromium for reduced motion before the page loads,
so the swap sheet opens without its 0.2s slide (the layout turns the slide
off under `prefers-reduced-motion`). Without that, a click inside a sheet
that is still sliding can be lost on a slow runner, as CI showed in #807.

How the click is lost:

- Chrome holds a new CSS animation at its first frame for two or three
  animation frames before it starts. Playwright calls an element stable
  after two frames with the same position, so it can pass that check while
  the sheet hasn't moved yet, then read the option's position once the
  slide is under way.
- Playwright checks that the pointer lands on its target only on the first
  event of a click, the press. If the sheet moves between the press and the
  release, the release lands on the row below, the browser sends the click
  to the list that holds both rows, and no radio is chosen. Playwright still
  reports the click as done.

On CI the first `confirm_swap(1, "pattern")` clicked Pattern, Pattern stayed
unchecked, and the Swap button was "not stable" twice and then "not enabled"
until the 22s timeout. Reading "not stable" as the sheet still sliding is an
inference from that log.

Holding the slide still part way and letting it jump ahead on the next press
reproduces the outcome: the press lands on Pattern, the release on
Architecture Decision, and the click on the list, so Pattern stays unchecked
and Swap stays disabled. It does not reproduce the two leading "not stable"
lines, and it holds the slide mid-way where the real hold is at the first
frame. When this was reproduced for #807, most of the file's examples failed,
through every way a sheet appears: the trigger, a reply that reopens a sheet,
and a re-rendered panel. So the fix covers the whole file instead of waiting
in `open_sheet` alone.

A person doesn't release a click a frame after pressing it, so the page
itself is unchanged. The example "opens the daily kind sheet without sliding
when the OS asks for less motion" in `spec/system/reduced_motion_spec.rb`
checks that the sheet's animation is off under this setting (and on without
it), and `spec/views/reduced_motion_coverage_spec.rb` holds every animation
to a reduced-motion rule, which is what this setting relies on.

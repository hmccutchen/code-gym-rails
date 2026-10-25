# app/views/layouts/application.html.erb

## Viewport meta tag

`viewport-fit=cover` lets the installed app's page reach under the iPhone home
indicator, which is what makes `env(safe-area-inset-*)` report real values.
The bottom tab bar pads itself by `safe-area-inset-bottom`, and the nav and tab
bar pad by the left and right insets for landscape. The status bar styles the
app uses (`black`, `default`) are opaque, so nothing reaches under the status
bar and no rule needs the top inset.

`interactive-widget=resizes-content` is spec-correct and included for Chromium
and any future WebKit support, but WebKit is believed not to implement it yet.
It is not what keeps iOS from zooming on focus; `--input-font-size`, on every
focusable control's rule, does that.

## Home-screen meta tags

iOS reads the manifest's `display: standalone` only from 17.4, so
`apple-mobile-web-app-capable` is what actually drops Safari's address bar,
reload and "aA" buttons on a home-screen launch. `mobile-web-app-capable` is
the standardised spelling of the same declaration. Both status-bar-style
values `DisplayPreferences` uses, `black` and `default`, keep the app's content
below the status bar; only the bottom of the screen needs a safe-area inset
(see the viewport tag above).

## `--accent-text`

`--accent` is too dark to read as text on the surface colors (4.27:1 on
`--surface`), so text takes a lighter shade of the same hue and `--accent`
stays for borders and fills. White on `--button-bg` is 5.07:1.

## `--input-font-size`

iOS auto-zooms a focused input below 16px, which shifts the layout and does not
cleanly restore. `max()` keeps the floor without overriding a user who has set
a larger default.

## `#background-pattern`

The layer sits below the pull-to-refresh indicator, outside the content that
indicator's gesture translates.

## `@media (display-mode: standalone)`

These rules remove browser behaviours that read as "web page" rather than
"app" once the chrome around them is gone: the rubber-band bounce past the end
of a page, and the grey flash on tap. They are scoped to the installed app
rather than applied everywhere, so a Safari tab keeps its pull-to-refresh and
its tap feedback.

The nav name editor goes with them, for space rather than for feel: the
installed app has no browser chrome above the nav, so the row is at its
tightest exactly where the brand and the links matter most. The whole
`.name-editor` is hidden, not just its input, because the status readout it
flashes has nothing to report once its field is gone. This is the only way to
rename yourself, so the installed app has no way to rename. That is a
deliberate trade, and renaming is unchanged in a browser tab.

On a phone-width installed app the destinations move to a bottom tab bar
(`shared/_tab_bar`), the layout every native iOS and Android app uses, and the
collapsed menu and its button are hidden, so there is one way to navigate.
The tab bar is limited to 48rem because a desktop install also matches
`display-mode: standalone`, and a tab bar along the bottom of a desktop window
reads as a phone layout. The body is padded by the bar's height so the end of
a page can scroll clear of it, and the save banner moves up above it.
`user-select` and `-webkit-touch-callout` are turned off on the controls only,
so a long press on a button no longer selects its label or opens the link
preview, while answers, code and prose stay selectable.

This media query is the app's one standalone-mode test, and a second mechanism
could disagree with it. The pull-to-refresh script reads its answer from
whether `.pull-refresh` is displayed for the same reason; `body` outranks that
element's hidden base rule further down, as `.nav-links` does here. The name
editor is selected through `.nav-links` to outrank `nav .name-editor`, which
sets a display of its own further down the sheet: a media query adds no
specificity, so the later rule would otherwise win.

## Focus ring for fields and sliders

This is the one focus ring for fields and sliders. It is offset so it sits on
the background around the control rather than on the control's own border. A
slider's ring goes on its thumb, the part the arrow keys move. Each thumb
selector gets a rule of its own because a browser drops a whole selector list
when it does not know one vendor pseudo-element.

## `nav`

The nav is positioned because the collapsed menu hangs off it. It is a query
container so the collapse can measure the nav in its own text size.
Containment makes `nav` a stacking context, and the `z-index` keeps the open
menu above the dashboard's sticky progress bar.

## Palette tokens beyond the base colors

`--surface-raised` is the fill for a hovered or current nav link and for a
plain `.btn`, one step lighter than `--surface`, so the layers read as depth
rather than one flat color. `--nav-bg` is `--surface` made translucent, for the
nav and tab bar, which blur what passes beneath them. `--slot-1` to `--slot-4`
color a section by its position on the page (see `.section`), and
`palette_contrast_spec` holds each at 4.5:1 on the surface, on code and on the
review block, since each one colors text. `--tab-bar-height` is in px, like the nav toggle, so a
larger text size cannot push six tabs past a phone's width.

## `.container` from 1024px

A desktop window gets a wider column and more side padding, so the page reads
as a web app rather than a phone layout centred in a large window. The
`-1.5rem` coupling below applies only under 600px, where this rule never runs. Both widths take the larger of their padding and the side safe-area
insets, because `viewport-fit=cover` lets a landscape phone draw the column
under its notch. A portrait phone reports no side inset, so the `-1.5rem`
coupling still matches.

The padding is built from `--container-pad-left` and `--container-pad-right`,
and this rule sets them again rather than the padding. `phone_cards.css`
subtracts the same properties to put a card page's edge where it wants, so a
change to them moves it too.

## `nav .inner`

It is wider than the page column, so on a desktop the brand sits apart from the
links instead of crowding them inside the same 800px.

## `nav .brand`

The brand refuses to shrink or wrap. Squeezed against the name editor in a
wide browser tab, it otherwise broke into three lines (the bolt, then "Code",
then "Gym"). The name editor absorbs the squeeze instead: a truncated name
still reads and still edits, while a stacked wordmark reads as broken.
`min-width: 0` all the way down is what lets it, since a flex item will not
shrink below its content otherwise.

## `nav .brand:hover`

A tap leaves a touch screen in `:hover`, so the global underline would stay on
the logo after every trip home.

## `nav .brand > picture`

When the light palette wraps the mark in a `picture`, that element would
otherwise sit on a text line, and the line's height added about 10px below the
mark, so the nav grew taller only on pages that link the display stylesheets.

## `nav .nav-links a`

The links are neutral text rather than the accent color, so the accent marks
what can be acted on in the page instead of every word in the bar. The current
page carries `aria-current="page"` (`NavigationHelper#nav_current?`) and gets
the same raised pill as a hovered link.

## `nav .brand-mark`

The image's alt text names the link, which is why the wordmark beside it is
hidden from screen readers.

## `@container (max-width: 40em)`

Below this width the row cannot hold the brand and the five destinations at
once, so the destinations fold behind the button and the brand stays on one
line. The width is in em against the nav's own text, so a larger text size
moves the fold out with it: 40em is 640px at the default size. It was 37.5em
until Settings joined the row, which overflowed it by 22px at the default text
size.

## `nav .nav-toggle`

The button is 44px in px rather than rem: a button that grew with the text size
left no room for the logo beside it on a 320px screen.

## Narrow-phone brand rules

On the narrowest phones the brand and the button no longer fit side by side.
The mark gives up width so the button always stays on screen, and the wordmark
keeps its size. When the light palette wraps the mark in a `picture` element,
that element is the flex item, so it shrinks and the mark follows it through
`max-width`.

## `nav .nav-links` inside the container query

Only `.nav-links` itself ever carries a display in this block, never a child.
The standalone block hides the name editor through
`nav .nav-links .name-editor`, and any rule of higher specificity in this
block would put it back in the installed app.

## `.btn`

A `.btn` with no variant gets the raised fill, so a `button_to` that only
passes `btn btn-sm` no longer falls back to the browser's white button. The
press scale is the tap feedback the installed app loses when the standalone
block removes the grey tap highlight.

## `.btn-loading`

This is the loading state for buttons whose click starts a wait. It has two
consumers: forms that mount the `loading-form` Stimulus controller
(`app/javascript/controllers/loading_form_controller.js`) and the fetch-driven
submit and review handlers, which toggle the class themselves.
`pointer-events` guards the gap before `disabled` lands, since the controller
sets `disabled` a tick after the submit so it does not cancel the submission.

## `.pull-refresh`

This is the installed app's replacement for the pull-to-refresh a Safari tab
has natively. Only the standalone block shows it; `shared/_pull_to_refresh`
slides `[data-pull-content]` down and centres this in the gap it opens.
`z-index: -1` keeps it beneath the nav and the content, so it shows only where
the content has moved out of the way.

## `@media (prefers-reduced-motion: reduce)`

For anyone whose OS asks for less motion, a spinner stops turning rather than
disappearing. Each spinner sits beside text that already says the work is
under way, and a still ring keeps the same meaning. The block stays after
every rule it overrides, since it relies on source order.

## `code, kbd, samp, pre`

A lone generic `monospace` makes browsers drop the default size to 13px, so
inline code would shrink beside 16px prose. Naming it twice is the known way
to opt out; the face is unchanged.

## `pre.snippet, .pseudocode-code pre`

`pre-wrap` keeps each line's leading whitespace intact, so snippets wrap on
phones instead of forcing horizontal scroll. `overflow-wrap` breaks a token too
long for the line. The text-size-adjust rules stop iOS enlarging code text on
its own in landscape.

## `code.highlight .code-line`

`CodeHighlight` renders each line as a `.code-line` and sets `--indent` to its
leading columns. The first line starts at column 0 and keeps its own spaces; a
wrapped continuation starts two columns past that indentation.
`code_lines_controller` marks a block that wraps, and its alignment padding
then shows as one space while the rest stays in the text, so a copy keeps the
original line.

## `.plan-excerpt`

Plan-review excerpts are prose, so they get a left-border quote block instead
of the monospace snippet treatment. Multi-paragraph text then reads as an
excerpt from a doc rather than malformed code.

## Pseudocode-to-code rounds

These styles live here rather than in a per-page block for the same reason as
`.answer-display`: `_answered_sections` renders them on the dashboard's
submitted state and on every history entry.

## Rouge token classes

Rouge's token classes are colored from the palette, so both themes and Match
my device need no second color source.

## `.skip-link`

The skip link sits off screen until focused, so it is the first stop for a
keyboard and invisible to everyone else. It is fixed, so showing it never
shifts the nav.

## `#main-content:focus`

The main region is focused only as the skip link's target, and a ring around
the whole page would read as an error.

## Reviews, questions and scenarios wrap long words

A review often names a file path or a chained method, one unbroken word that
can be wider than a phone's text column. Without `overflow-wrap: anywhere`, a
single path in the newest review made History 517px wide on a 390px phone as
soon as it loaded, since that review opens by default. The dashboard's
submitted state renders the same partial and had the same problem.
A question or a scenario can hold the same kind of word, so `.question` and
`.section-scenario` wrap the same way. `small_screen_layout_spec` holds both
pages at 390px, and History at 320px with the largest text. The why box and the
duck's replies have no rule, because a long path in either did not widen the
page in that spec.

## Shared submission-rendering styles

These are used by `responses/_section` (and the per-kind partials it renders),
`responses/_answered_sections` and `responses/_submission`. All of them render
on both the dashboard and the history page, so these styles cannot live in a
per-page `<style>` block.

## `details.section > summary` target size

The summary is the most-tapped control on the page, so it gets a 44px target.
The negative margins give back exactly what the padding adds, so the label
stays where it was and the target grows into the space around it.

## `.section` slot accents

`data-slot` is the section's position in `responses/_sections`, never its
kind, so a color says "the second section today" and adding a kind needs no
color. The stripe is an inset shadow rather than a top border, so it costs no
space and a folded section's label stays where it was. The stripe sits on
`.section[data-slot]` only: the dashboard's generating, failed and paused
panels and the admin card share `.section` and are not exercise slots. The
accent variable follows any `[data-slot]`, so a review block that carries its
section's slot (`shared/_ai_review`) colors its heading to match; a block with
no slot keeps `--accent-text`.

## `.section` below 600px

The rule is scoped to `.section` rather than zeroing `.container`'s padding,
which would drag the nav and every page heading flush against the screen
edge. The `-1.5rem` tracks `.container`'s padding and must change with it.

## `.daily-kind-trigger`

The swap trigger sits `position: absolute` over the title row, so its `top`
and `right` restate where that row is: `.section`'s padding (1.5rem, and
1.25rem by 1rem in the 600px rule, which repeats the offsets) minus the
summary's 12.5px `padding-block`, which makes the row 44px tall. A change to
either moves the row out from under the button, so the rule's comment names
them. The card is positioned with
`details.section:has(> .daily-kind-swap)` rather than a class, so a card's
own markup is the same with or without a swap control.

## `.daily-kind-sheet::backdrop`

Older iOS doesn't let `::backdrop` inherit custom properties. Two fallbacks
cover the two ways that can go:

- **A browser without `color-mix()`** drops the second declaration while
  parsing and keeps the first, a literal `rgba(15, 15, 26, .7)`, which is
  `--bg` (`#0f0f1a`) at 70%.
- **A browser with `color-mix()` but no inherited `--bg`** keeps the second
  declaration, so the first can't help: an unresolved `var()` makes the
  declaration invalid at computed-value time, and the background becomes
  transparent rather than the earlier value. The `var()` therefore carries
  its own fallback, `var(--bg, #0f0f1a)`.

`pwa_spec` reads `--bg` from the layout and fails if either literal drifts
from it. Both literals are the dark palette's. Where `::backdrop` does see
custom properties, the light palette gets its own `--bg`.

## Swap sheet live regions

The sheet's error line and its "Saving…" line are live regions, so they stay
rendered while empty: a region that appears in the same frame its text is
set may not be announced. An empty one takes a negative top margin equal to
the footer's gap instead of `display: none`.

## `.mermaid-diagram:empty`

This hides only the diagram box while it is still empty, before render fills
it. The enclosing `<details>` summary stays visible and clickable regardless,
since that is the point of the disclosure. A genuine failure (a bad diagram, a
blocked or slow CDN) is handled separately: the module script removes the
whole disclosure it owns, not just this div, so a failed diagram never leaves
an empty box behind.

## `.gloss-term::after` below 600px

Below this breakpoint `.section` breaks out of `.container`
(`margin-inline: -1.5rem`) and sets its own padding, so the panel is measured
against the section rather than the container, to line up with the text it
defines. Every fallback equals the desktop value, so the paths that reveal the
panel without running the script (`:focus-visible`, hover on a hover-capable
pointer, or no script at all) stay capped as before. `max-width` reuses
`--gloss-width` so that it is a no-op once the script has set an explicit
width, which the 16rem cap would otherwise clamp.

## `.learn-entry[hidden]`

`hidden` alone cannot hide a flex item: `.learn-entry`'s own display beats the
user agent's `[hidden]` rule, so the filter needs this rule to work.

## Rung colours

Each standing sets `--rung` once, and the bar segments and held dots read it.
Developing toward a rung is striped in that rung's colour, so the bar reads as
the same ladder with the in-between steps marked.

## `.featured-concept`

`shared/_featured_concept` renders on both the Learn tab and the dashboard, so
like the submission-rendering styles it cannot live in a per-page `<style>`
block. `.featured-compact` is the dashboard's wrapper; it dials the same block
down rather than giving it a second markup.

## `.featured-marker`

`responses/_featured_marker` renders inside the section wrapper, which the
dashboard and every History entry share, so its style lives here beside
`.featured-concept`. `text-transform: none` keeps it readable inside the
uppercase section label; the read-only label is a plain `div`, so only there
does it need its own left margin, while the answer form's summary already
spaces its children with `gap`.

## `.save-status`

The status is fixed rather than inline because the dashboard's autosave fires
while the engineer is typing far down a long page, and a message rendered at
the top would report the failure somewhere they cannot see.

## Display stylesheets

They are linked after the inline styles, so equal-specificity rules in them
win. The light palette's `media` attribute is
`DisplayPreferences#light_palette_media`, the same value the brand logo's
`<source>` and the light `theme-color` carry.

## Settings rules for classes the partials carry

Two rules sit here, beside the `details.kind-about` rules, though only
Settings uses them: `#exercise-mix .kind-about > summary` (a 44px About
summary) and `:where(.phone-page .mix-note) .hint` (the guide text's size,
colour and top margin). Their classes come from partials (`responses/_kind_about`,
`api_keys/_key_guide` and `_trial_note`), and `spec/views/own_styles_spec.rb`
refuses a rule in the Settings page for a class its own markup lacks. The
`:where()` keeps the hint rule at one class of weight, so `.key-guide > * + *`
still wins the guide's spacing.

## Page behavior

Every behavior this layout used to carry as an inline script is now a
Stimulus controller, mounted by a `data-controller` attribute: `nav-menu`,
`name-editor`, `time-zone` and `loading-form`, plus `glossary code-lines
mermaid` on `<body>`. Each controller's reasoning lives in its own note under
`docs/code-notes/app/javascript/controllers/`, so it is not restated here.
The layout has no `yield :page_scripts` slot any more, since no view has a
script to put there.

## The two shared modules

`javascript_importmap_tags` in `<head>` loads `code_gym/request` and
`code_gym/save_status`, and `application.js` also puts both on `window`,
because the system specs drive them from `execute_script`, which cannot import
a module. Module scripts are deferred, so they run after parsing ends. No
inline script reaches either global now, and controllers bind through
Stimulus's own lifecycle, so the gap that remains between a painted page and a
connected controller is an edit made before connect.
`code_gym_bootstrap.js`, a blocking classic asset loaded just before the
importmap tags, publishes both names at parse time and records such an edit;
`docs/code-notes/app/assets/javascripts/code_gym_bootstrap.md` has the
details.

The two sentences those modules show are rendered onto `<body>` as data
attributes, because a module cannot read a translation.

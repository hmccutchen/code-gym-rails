# app/views/layouts/application.html.erb

## Viewport meta tag

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
below the status bar, so nothing here needs `viewport-fit=cover` or safe-area
insets.

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

## `nav .brand-mark`

The image's alt text names the link, which is why the wordmark beside it is
hidden from screen readers.

## `@container (max-width: 37.5em)`

Below this width the row cannot hold the brand and four destinations at once,
so the destinations fold behind the button and the brand stays on one line.
The width is in em against the nav's own text, so a larger text size moves the
fold out with it: 37.5em is 600px at the default size.

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

## `.btn-loading`

This is the loading state for buttons whose click starts a wait. It has two
consumers: forms tagged `data-loading-form` (the shared script at the bottom
of this layout) and the fetch-driven submit and review handlers, which toggle
the class themselves. `pointer-events` guards the gap before `disabled` lands,
since the shared script applies it a tick late.

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
`shared/_code_lines_script` marks a block that wraps, and its alignment padding
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

## Shared submission-rendering styles

These are used by `responses/_section` (and the per-kind partials it renders),
`responses/_answered_sections` and `responses/_submission`. All of them render
on both the dashboard and the history page, so these styles cannot live in a
per-page `<style>` block.

## `details.section > summary` target size

The summary is the most-tapped control on the page, so it gets a 44px target.
The negative margins give back exactly what the padding adds, so the label
stays where it was and the target grows into the space around it.

## `.section` below 600px

The rule is scoped to `.section` rather than zeroing `.container`'s padding,
which would drag the nav and every page heading flush against the screen
edge. The `-1.5rem` tracks `.container`'s padding and must change with it.

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

## `.save-status`

The status is fixed rather than inline because the dashboard's autosave fires
while the engineer is typing far down a long page, and a message rendered at
the top would report the failure somewhere they cannot see.

## Display stylesheets

They are linked after the inline styles, so equal-specificity rules in them
win. The light palette's `media` attribute is
`DisplayPreferences#light_palette_media`, the same value the brand logo's
`<source>` and the light `theme-color` carry.

## Name editor script

The autosave is an inline script because the layout emits no
`javascript_importmap_tags`, so no Stimulus or importmap JS runs; the answer
autosave in `dashboard/_exercise` follows the same convention. Copy still
comes from I18n, and the CSRF token comes from the meta tag.

## Time-zone detection script

It is one-shot: the script renders only while the user's zone is unset, so it
never overwrites a later manual choice. It posts the browser's IANA zone.

## Nav menu toggle script

The panel's collapsed state is CSS, so above the breakpoint the button is
gone and `data-open` means nothing. Nothing in the script has to undo itself
on a resize.

## Loading-form script

This gives loading feedback for plain form POSTs. Turbo JS is not loaded, so
`button_to` forms are full-page submissions and Turbo attributes
(`turbo_confirm`, `turbo_submits_with`) are inert; any feedback or
confirmation must be wired here. A form opts in with `data-loading-form`.
`data-confirm-message` gates submission behind a native confirm, and
`data-loading-label` is the in-flight button label.

`button_to`, with Rails 8's `button_to_generates_button_tag` default, renders a
`<button>` rather than an `<input>`. The two need different properties for
their label, so the script reads and writes whichever is present.

Disabling the button is deferred a tick, because disabling it synchronously
inside the submit handler can cancel the submission in some browsers.

A bfcache Back-restore would bring the page back mid-loading, with the button
dead until a manual reload. The review button handles the same hazard. The
`pageshow` handler resets the button to idle.

## Glossary tooltip script

Hover reveals the definition on desktop through CSS alone, gated to real-hover
pointers. Tap toggles it on touch, since hover has no equivalent there.
Enter and Space toggle it the same way for keyboard users, matching the
`tabindex="0"` the terms render with and the `:focus-visible` reveal rule. One
delegated listener per event type handles every `.gloss-term` on the page,
whichever partial rendered it, matching the loading-form script's delegation.
It is cheap and unconditional: there is no CDN fetch, so it needs no
presence-gated dedup partial the way Mermaid does.

`:focus-visible` and `:hover` reveal the panel through CSS alone, without ever
toggling `.gloss-open`, so those paths have to be measured too. The width cap
bounds the panel but does not keep it on screen.

## Script partials and `:page_scripts`

`:page_scripts` collects per-page scripts that would otherwise be duplicated
once per rendered partial instance (for example `shared/_ai_review` and
`shared/_mermaid_diagram` on /history). Those partials emit into this region
exactly once per request, however many times they render.

`shared/_push_script` defines `window.CodeGymPush` and, for a user who has
reminders on, re-subscribes this browser on launch. It renders ahead of
`:page_scripts` on purpose, because the Account page's enable button binds
against the global defined there.

`shared/_save_status` defines `window.CodeGymSaveStatus`, which the
dashboard's and /setup's autosaves report through. It renders ahead of
`:page_scripts` for the same reason: those pages' own scripts bind against the
global. The one-shot time-zone detection higher up this file stays
fire-and-forget on purpose; see that partial.

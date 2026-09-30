# Display preferences — design

Four settings a user controls on the Setup page: theme, text size, line
spacing and reading font. Status: implemented. OpenDyslexic is deferred to
hmccutchen/code-gym-rails#235.

## Where the controls live

Setup (`GET /setup`, `api_keys/edit`) already holds the preferences: the
Exercise mix is a collapsed `<details class="form-field" id="exercise-mix">`
that autosaves through `CodeGymSaveStatus.save("PATCH", "/profile", …)`. A
second collapsed disclosure, `#display-preferences`, sits directly after it
and saves through the same endpoint. Each control applies to the page on
change (by setting the attribute on `<html>`), then saves.

| Setting | Stored key | Values (default first) |
| --- | --- | --- |
| Theme | `theme` | `dark`, `light`, `device` |
| Text size | `text_size` | `100`, `112`, `125`, `140` |
| Line spacing | `line_spacing` | `default`, `relaxed`, `loose` |
| Reading font | `font` | `default`, `atkinson` |

## Storage

- **Migration (the only one):** `users.display_preferences`, jsonb,
  `default: {}`, `null: false`.
- `DisplayPreferences` (a plain value object, like `KindPreferences`) owns the
  closed lists, the defaults and the `<html>` attributes. It reads an unknown
  stored value as the default, so bad data never reaches the page.
- `User` validates keys and values against those lists. `ProfileController`
  refuses a malformed `display_preferences` (not an object, unknown key,
  unknown value) with a 422 before strong parameters can drop it. This is the
  same guard shape as the weights.
- Sparse: a default value stores no key, so a user who picks Dark again ends
  with `{}`. The client posts the whole object each time.
- Saves are chained, one request in flight at a time, the way the Exercise
  mix chains its own (`inFlight` in `api_keys/edit`). `CodeGymSaveStatus`
  ignores a stale response, but it cannot stop an older request from reaching
  Rails last, and since each request carries the whole object, parallel
  requests could leave an earlier choice stored. With one request at a time,
  the most recent choice is always the last one written. Across tabs the last
  write wins, with no version check.

## First paint

- The layout renders `data-theme`, `data-text-size`, `data-line-spacing` and
  `data-font` on `<html>`, only for keys the user has set.
- Signed-out pages render `data-theme="device"` and follow
  `prefers-color-scheme`, so login's HTML changes by that attribute, the two
  stylesheet links and the logo's `<picture>`.
- Two stylesheets: `display.css` (text size, spacing, the reading font) and
  `display_light.css` (the light palette). The layout links both only when the
  user has a stored preference, on Setup (so a change can apply before it is
  saved), and on signed-out pages. A signed-in user with nothing stored gets
  no new attribute, link or logo markup; a request spec pins this.
- Compared against `main` for such a user, the only difference in the HTML
  is the nav's collapse rule in the layout's inline CSS (see "Text size"
  below). No other byte changed on History, Learn, Progress, Account or the
  dashboard.
- The light palette overrides the layout's hardcoded dark colors by selector
  instead of turning them into variables, which is what keeps the rest of the
  layout's CSS untouched.

## Theme

- `display_light.css` redefines the same `:root` variables, plus
  `color-scheme: light`, with no selector scoping. Its `<link>`'s `media`
  attribute decides where it applies: `all` for Light, `(prefers-color-scheme:
  light)` for Match my device, `not all` otherwise
  (`DisplayPreferences#light_palette_media`). That states the palette once for
  both themes. Dark sets no `color-scheme`, so nothing about it changes.
  Nothing transitions, so a theme change is instant.
- The light palette is checked by `palette_contrast_spec` (extended to read
  the light values) and by axe on the dashboard, History, Learn and Setup.
- **Logo:** wherever the display stylesheets are linked, the logo is a
  `<picture>` whose `logo.png` source carries the same `media` value as the
  palette's link, so the two cannot disagree. Setup's script updates both. A
  user with nothing stored keeps the current `<img>` exactly.
- **Syntax highlighting:** the rules already read the shared variables except
  two literal colors (`#a78bfa`, `#7dd3fc`). The light file overrides those
  two and the variables they read.
- **Mermaid** uses its built-in `default` theme, which is a light theme.
  On a light page it needs nothing. On today's dark background it is the
  existing mismatch (dark connector lines on a near-black box). Fixing that
  would change the dark look, so it is out of scope and reported.

## Text size and line spacing

- `html[data-text-size="125"] { font-size: 125% }`, a percentage of the
  browser's own default, so a user's browser setting still counts. No
  `font-size` declaration uses a `px` literal: each is in `rem`/`em` or reads
  `--input-font-size`. That variable, `max(1rem, 16px)`, is the one `px` size
  and it is intentional. It stays unchanged, so inputs never drop below 16px
  and grow with the text above it.
- The `px` values that remain are borders, radii, 1–4px decorative lines, the
  600px breakpoints and the column `max-width`s (400/480/800/1200px). At
  larger text the columns simply hold fewer words per line, and none of them
  breaks.
- **What did break (measured at 140%):** the nav. The brand is sized in
  `rem` (2rem wordmark, 7rem logo), so at 390px wide the nav needed 482px and
  scrolled the page sideways. Between 600px and 800px the uncollapsed nav
  needed 783px. Fixes:
  - the brand is pinned to its default size in `px` under `data-text-size`,
    in `display.css`;
  - the collapse rule stays one rule. The adjustment sits in the original: the
    layout's `@media (max-width: 600px)` became `@container (max-width:
    37.5em)` on `nav`, which is 600px at the default size and moves out with
    the text (840px at 140%). Two side effects: containment makes `nav` a
    stacking context, so it gets `z-index: 20` to keep the open menu above
    the sticky progress bar; and the width is measured without a desktop
    scrollbar, so the fold can come up to a scrollbar's width earlier in a
    narrow desktop window.
- The sticky progress bar keeps `--progress-sticky-height` (3.25rem), which
  grows with the text. At 140% its content is 72px against a 72px box, so
  nothing clips, and `scroll-padding-top` still reads the same variable.
- Line spacing sets one value on prose: `p`, `li`, `dd` and the named
  containers that hold generated prose outside a `<p>`. `relaxed` is 1.9 and
  `loose` 2.2. Every existing `line-height` is between 1.5 and 1.8, so both are always
  an increase.

## Reading fonts

- Self-hosted `@font-face` in `display.css`, served by Propshaft. A browser
  downloads an `@font-face` file only when an element on the page uses that
  family, so nobody else fetches it. No external request is made.
- The font applies to prose only, the same selector list line spacing
  uses. That covers questions, scenarios, plan excerpts, problem statements,
  teaching notes, reviews, references and Learn content without wrapping any
  page in a new element. Controls, labels and the nav keep the default font.
  `pre`, `code`, `kbd` and `samp` keep a monospace face with an explicit rule.
  The code answer field keeps its Fira Code stack, and the address on Account
  (`.account-id .email`, a `<span>`) is not prose, so it keeps its own
  monospace rule.
- Weights 400 and 700, Latin only. Italic is synthesized, since prose italics
  are rare and code comments stay monospace.

| Font | License | Files (woff2) | Total |
| --- | --- | --- | --- |
| Atkinson Hyperlegible 1.006 | SIL OFL 1.1, no Reserved Font Name | 400: 17.2 KB, 700: 17.5 KB | 34.7 KB |
| OpenDyslexic 0.920 | SIL OFL 1.1, Reserved Font Name "OpenDyslexic" | 400: 115.3 KB, 700: 120.4 KB | 235.6 KB |

**OpenDyslexic is deferred** (hmccutchen/code-gym-rails#235). The OFL lets
you self-host and embed either font. Under the OFL FAQ, a WOFF2 that only compresses the
original is not a modification, but a subset is, and a modified font may not
use a Reserved Font Name. Fontsource's files are processed copies. The
OpenDyslexic one still has 1,927 glyphs and names itself "OpenDyslexic", so it
may well be complete, but that cannot be proven here: opendyslexic.org and
GitHub releases are blocked by this environment's network policy. Atkinson
has no Reserved Font Name, so Fontsource's subset is fine for it.

## iOS status bar

- The current tag is `apple-mobile-web-app-status-bar-style: black`: a solid
  black bar with white text, with the page starting below it. The text never
  sits over the page, so it stays readable on a light page too. It just looks
  like a black strip above a white header.
- The other values: `default` is a white bar with black text, and
  `black-translucent` puts white text over the page. That last one is the only
  unreadable case, and it is not used.
- iOS reads the value when the home-screen app launches and ignores later
  changes in the page. Changing it needs the app to be fully closed and
  reopened, not reinstalled. That is reported behavior; no device was
  available here to confirm it.
- Explicit Light renders `default` and a light `theme-color`. Dark and
  Device keep `black`, which is readable under both themes. The copy under
  the theme control says "In the installed app, the bar at the top of the
  screen changes after you fully close the app and open it again." Bringing
  a running app back to the front does not reread the value, so the copy
  names the action that does.

## Reduced motion

Neither stylesheet adds an animation or transition. `reduced_motion_coverage_spec`
now reads `app/assets/stylesheets/*.css` as well as views, so one added later
needs its reduced-motion rule.

## Tests

- **Request:**
  - unknown key or value, and a non-object → 422;
  - defaults store nothing;
  - partial storage stays sparse;
  - no-preference HTML has no new attributes and no stylesheet link;
  - a stored preference renders its attributes;
  - light renders `logo.png` and `default`;
  - a signed-out page renders `data-theme="device"`.
- **Model:** validations and the value object's defaults.
- **Palette:** the light palette meets AA on every background, as the dark
  one does now, plus the status colors, field borders and the two literal
  highlighting colors.
- **Stylesheet:** every non-default choice in `DisplayPreferences::OPTIONS`
  has a rule in `display.css`, and every `@font-face` file exists.
- **System:**
  - change each setting, reload, still applied;
  - two changes made while the first save is held back: the later one is
    what is stored;
  - the light theme shows the plain logo;
  - a reading font leaves `pre` and code answers monospace;
  - at 140% and 390px wide, no page scrolls sideways and the sticky bar does
    not clip.
- **Manual:** Chrome at phone width, 140%, each theme and font.

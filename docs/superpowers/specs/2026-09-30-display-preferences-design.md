# Display preferences — design

Four settings a user controls on the Setup page: theme, text size, line
spacing and reading font. Status: proposed, not implemented.

## Where the controls live

Setup (`GET /setup`, `api_keys/edit`) already holds the preferences: the
Exercise mix is a collapsed `<details class="form-field" id="exercise-mix">`
that autosaves through `CodeGymSaveStatus.save("PATCH", "/profile", …)`. A
second collapsed disclosure, `#display-preferences`, sits directly after it
and saves the same way. Each control applies to the page on change (by
setting the attribute on `<html>`), then saves.

| Setting | Stored key | Values (default first) |
| --- | --- | --- |
| Theme | `theme` | `dark`, `light`, `device` |
| Text size | `text_size` | `100`, `112`, `125`, `140` |
| Line spacing | `line_spacing` | `default`, `relaxed`, `loose` |
| Reading font | `font` | `default`, `opendyslexic`, `atkinson` |

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
  with `{}`. The client posts the whole object each time. The last write
  wins, with no version check.

## First paint

- The layout renders `data-theme`, `data-text-size`, `data-line-spacing` and
  `data-font` on `<html>`, only for keys the user has set.
- The light theme, text sizes, spacing and fonts live in one stylesheet,
  `app/assets/stylesheets/display.css`. The layout links it only when the user
  has a stored preference, on the Setup page (so a change can apply before it
  is saved), and on signed-out pages (login follows
  `prefers-color-scheme`). A signed-in user with nothing stored gets the same
  HTML as today: no new attribute, no link. A request spec pins this, and a
  one-off check compares the full page against `main` byte for byte, with the
  CSRF token masked.
- Keeping everything in that file is what keeps the layout's inline CSS
  untouched. The cost is that the light theme overrides the layout's
  hardcoded colors by selector (about 30 of them) instead of turning them into
  variables.

## Theme

- `html[data-theme="light"]` redefines the same `:root` variables, plus
  `color-scheme: light`. `data-theme="device"` does the same inside
  `@media (prefers-color-scheme: light)`. Dark sets `color-scheme: dark`.
  Nothing transitions, so a theme change is instant.
- The light palette is checked by `palette_contrast_spec` (extended to read
  the light values) and by axe on the dashboard, History, Learn and Setup.
- **Logo:** light renders `logo.png`. Device renders a `<picture>` whose light
  source is `logo.png`. On Setup, the script swaps the `src` live. Dark keeps
  the current `<img>` exactly.
- **Syntax highlighting:** the rules already read the shared variables except
  two literal colors (`#a78bfa`, `#7dd3fc`). The light file overrides those
  two and the variables they read.
- **Mermaid** uses its built-in `default` theme, which is a light theme.
  On a light page it needs nothing. On today's dark background it is the
  existing mismatch (dark connector lines on a near-black box). Fixing that
  would change the dark look, so it is out of scope and reported.

## Text size and line spacing

- `html[data-text-size="125"] { font-size: 125% }`, a percentage of the
  browser's own default, so a user's browser setting still counts. Every
  `font-size` in the app is already in `rem`/`em`, and none is in `px`.
  `--input-font-size: max(1rem, 16px)` is unchanged, so inputs never drop
  below 16px.
- The `px` values that remain are borders, radii, 1–4px decorative lines, the
  600px breakpoints and the column `max-width`s (400/480/800/1200px). At
  larger text the columns simply hold fewer words per line, and none of them
  breaks.
- **What does break (measured at 140%):** the nav. The brand is sized in
  `rem` (2rem wordmark, 7rem logo), so at 390px wide the nav needs 482px and
  scrolls the page sideways. Between 600px and 800px the uncollapsed nav needs
  783px. Fix: pin the brand's size in `px` under `data-text-size`, and collapse
  the nav up to 800px at 125% and 140%. That repeats the collapse rules inside
  the new file, the one place a rule is stated twice. The alternative is
  moving those rules out of the layout, which changes the HTML for everyone.
- The sticky progress bar keeps `--progress-sticky-height` (3.25rem), which
  grows with the text. At 140% its content is 72px against a 72px box, so
  nothing clips, and `scroll-padding-top` still reads the same variable.
- Line spacing sets one value on prose containers: `relaxed` 1.9, `loose`
  2.2. Every existing `line-height` is between 1.5 and 1.8, so both are always
  an increase.

## Reading fonts

- Self-hosted `@font-face` in `display.css`, served by Propshaft. A browser
  downloads an `@font-face` file only when an element on the page uses that
  family, so nobody else fetches it. No external request is made.
- The font applies to prose only: questions, scenarios, plan excerpts,
  problem statements, teaching notes, reviews, references and Learn content.
  `pre`, `code`, `.hljs`, the code and pseudocode answer fields, and the email
  field on Account stay monospace, with an explicit rule and a system spec.
- Weights 400 and 700, Latin only. Italic is synthesized, since prose italics
  are rare and code comments stay monospace.

| Font | License | Files (woff2) | Total |
| --- | --- | --- | --- |
| Atkinson Hyperlegible 1.006 | SIL OFL 1.1, no Reserved Font Name | 400: 17.2 KB, 700: 17.5 KB | 34.7 KB |
| OpenDyslexic 0.920 | SIL OFL 1.1, Reserved Font Name "OpenDyslexic" | 400: 115.3 KB, 700: 120.4 KB | 235.6 KB |

**Open question: which OpenDyslexic files.** The OFL lets you self-host and
embed either font. Under the OFL FAQ, a WOFF2 that only compresses the
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
- Plan: explicit Light renders `default` and a light `theme-color`. Dark and
  Device keep `black`, which is readable under both themes. The copy under
  the theme control says "In the installed app, the bar at the top of the
  screen changes the next time you open the app."

## Reduced motion

The file adds no animation or transition. `reduced_motion_coverage_spec`
covers it as a view-level stylesheet once it is added to the files it reads.

## Tests

- **Request:**
  - unknown key or value, and a non-object → 422;
  - defaults store nothing;
  - partial storage stays sparse;
  - no-preference HTML has no new attributes and no stylesheet link;
  - a stored preference renders its attributes;
  - light renders `logo.png` and `default`.
- **Model:** validations and the value object's defaults.
- **Palette:** the light palette meets AA on every background, as the dark
  one does now.
- **System:**
  - change each setting, reload, still applied;
  - the light theme shows the plain logo;
  - a reading font leaves `pre` and code answers monospace;
  - at 140% and 390px wide, no page scrolls sideways and the sticky bar does
    not clip.
- **Manual:** Chrome at phone width, 140%, each theme and font.

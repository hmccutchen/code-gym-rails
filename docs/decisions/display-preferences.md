# Display preferences

theme (dark, light, match my device), background
pattern (on/off), text size (100/112/125/140%), line spacing and a reading
font (Atkinson Hyperlegible;
OpenDyslexic is deferred to #235, pending its license's rule on renamed and
converted copies). They live in a Display disclosure on Setup and save
through `PATCH /profile`. `DisplayPreferences` is the one list of choices,
defaults first. `users.display_preferences` is sparse jsonb, since a default
stores no key, and `User` plus `ProfileController` refuse anything outside
the lists. Saves are chained one at a time because each carries the whole
object.

**The background pattern is deliberately on by default**, an exception to
display changes requiring an opt-in. Two white, alpha-channel tiles mask a
fixed layer at a 288px repeat size: `gym-pattern-tile.png` emphasizes
outlines on light, and `gym-pattern-tile-dark.png` emphasizes fills on dark.
The layout sets `--pattern-mask`, tint and opacity for dark; the existing
light stylesheet overrides all three, so its media rule also selects the
artwork for "Match my device" without another theme switch. Light uses
the light accent, `rgb(91, 71, 214)` (`#5b47d6`), at 7%; dark uses
`rgb(190, 205, 240)` at 8%. The layer sits outside `[data-pull-content]` and
below the refresh indicator, so neither scrolling nor the pull gesture
moves it. Off omits the layer from the response; Setup adds or removes it
immediately. High contrast and forced colors hide it, as does missing
mask support. Both standard and `-webkit-` mask declarations are present.
No migration: only an explicit `"background_pattern": "off"` is stored
in the existing sparse jsonb. `palette_contrast_spec` checks a fully
opaque mask pixel, including through tinted backgrounds.

**The other display defaults remain unchanged**: no attribute on
`<html>`, no stylesheet link, the same dark brand mark, the same `black`
status bar. A chosen value renders as a `data-*` attribute on `<html>` for
the first paint. `display.css` holds text size, spacing and the font;
`display_light.css` holds the light palette. The layout links both only for
a user with a stored choice, on Setup, and on signed-out pages, which follow
the device. The light palette is unscoped, and its `<link>`'s `media`
(`DisplayPreferences#light_palette_media`) decides where it applies; the
logo's `<source>` and a light `theme-color` tag carry the same value, so none
of the three can disagree. The dark `theme-color` follows as the fallback.

**The nav's collapse is a container query**, `@container (max-width:
40em)` on `nav`: 640px at the default size, and it moves out as the text
grows. `mobile_nav_menu_spec` checks that the row fits just above it at the
smallest and largest text sizes, so adding a destination that crowds it fails. It stays one rule rather than a copy per text size. Containment makes
`nav` a stacking context, hence its `z-index`. The reading font and line
spacing apply to prose only (`p`, `li`, `dd` and the named prose
containers), never code. iOS reads the status bar style when the installed
app launches, so only an explicit Light asks for the white bar, and the copy
says to fully close and reopen the app. Mermaid already draws with its light
theme, so the light palette needs nothing for it. Code blocks and the other
code-colored panels take `--code-bg`, and highlighting takes the palette
plus `--code-symbol` and `--code-builtin`, so each palette states them once;
code is sized in rem, so text size scales it. `palette_contrast_spec`
holds both palettes to WCAG AA, every highlighting color on code included.

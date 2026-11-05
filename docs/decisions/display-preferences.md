# Display preferences

theme (dark, light, match my device), background
pattern (on/off), text size (100/112/125/140%), line spacing and a reading
font (Atkinson Hyperlegible or OpenDyslexic). They live in a Display disclosure on Setup and save
through `PATCH /profile`. `DisplayPreferences` is the one list of choices,
defaults first. `users.display_preferences` is sparse jsonb, since a default
stores no key, and `User` refuses anything outside the lists, while
`ProfileUpdate` refuses a value that is not an object. `DisplayPreferences.sparse`
drops a default only for a listed setting, so an unknown setting, even one
posted as null, reaches `User`'s check and is refused. Saves are chained one
at a time because each carries the whole object.

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

**The nav's collapse is a container query** on `nav`, in em so it moves
out as the text grows; the layout's code note gives its width and how it
was measured. `mobile_nav_menu_spec` checks that the row fits just above it at the
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

**OpenDyslexic is the author's own WOFF2 files, unchanged** (#235). The
font is under the SIL Open Font License 1.1 with the Reserved Font Name
"OpenDyslexic", and the license counts changing formats as making a
Modified Version, which may not use that name. The OFL FAQ (2.2, shipped in
the font's own repository) allows a WOFF copy to keep the name only when the
font data is unchanged apart from compression. The author now distributes
WOFF2 files in the repository's `compiled` folder
(`forge.hackers.town/antijingoist/opendyslexic`), so the app ships
`OpenDyslexic-Regular.woff2` and `OpenDyslexic-Bold.woff2` byte for byte,
renamed only on disk, with the license beside them. They and `OFL.txt` were
taken at commit `48218028cc8bd9f4f244cd4ce4049e6c879d4d1a` (2025-11-29), the
last change to each file there, so a later check can compare against it. Those files are the
Original Version, so the name stands. Fontsource's processed copies, which
#235 first looked at, are not used. `display_stylesheet_spec` pins each
file's SHA-256, the license included, so a converted or subset copy dropped
in later fails before it ships under the reserved name, and the license text
that condition 2 requires stays whole. The files are 103 KB and 108 KB, and as
with Atkinson a browser fetches one only when the page uses the font.

**Long words.** The key hint on Setup links to each provider's console
(`console.anthropic.com` and the like), and each link is one unbreakable
word. At a 320px width it ran past the screen at the largest text in
OpenDyslexic, and in every font once the browser's own text size was raised
as well. `pages/settings.css` lets those links break (`overflow-wrap:
anywhere`, which breaks a word only when it cannot fit), so the fix holds for
every font. OpenDyslexic's letters are about 1.7 times as wide as Atkinson's,
so its prose rule also breaks long words anywhere in prose, which a
`SectionKindGuide` summary needs on Learn at a raised browser size. Inline
code under it wraps as it does in every other font: it breaks only inside the
elements that already break words for everyone (`pre`, `.question`,
`.section-scenario`, `.plan-excerpt`, `.problem-statement`, `.review-block`,
`.file-summary`, `.answer-display`, `.learn-worked-example`), and
`display_stylesheet_spec` fails unless that list names every layout rule that
breaks words anywhere. It also holds every prose selector list in
`display.css` to the others. The layout specs' page-width
loops run the largest text in two fonts (`LayoutHelpers::LARGEST_TEXTS`):
OpenDyslexic, the widest, and Atkinson, which keeps long words whole and so
catches an overflow OpenDyslexic's breaking would hide. Setup's key hint is
also checked at 320px in all three fonts with a 20px browser
default and the text-spacing override.

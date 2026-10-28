# Home-screen app

`GET /manifest.json` (Rails' own `PwaController`, so it
needs no session) plus the `apple-mobile-web-app-*` meta tags in the layout
make an iOS home-screen launch open standalone instead of inside Safari's
chrome. The `apple-` meta tags are not redundant with the manifest — iOS reads
`display: standalone` only from 17.4. `status-bar-style` is `black`, so
content stays below the status bar. `viewport-fit=cover` lets the page reach
under the home indicator and, in landscape, beside the notches, so the layout
pads by the bottom and side safe-area insets (the nav, `.container` and the
card pages) and never by the top one. On a phone-width installed app the
destinations move from the collapsed menu to a bottom tab bar (`shared/_tab_bar`, built
from `NavigationHelper#nav_destinations`), which pads itself clear of the
home indicator with `env(safe-area-inset-bottom)`. A browser tab and a
desktop install keep the top nav. One brand mark, a violet kettlebell
between braces, is used everywhere. The icons come from two opaque 1024px
masters on the navy `rgb(25, 25, 45)`:
`app/assets/images/app-icon-master.png` (the kettlebell between braces) for
`apple-touch-icon.png`, `icon-192.png`, `icon-512.png` and
`icon-maskable-512.png`, and `favicon-master.png` (the kettlebell alone,
since the braces make it too wide to read at 32px) for `favicon.ico`, which
holds 16, 32 and 48px frames, and `favicon-96.png`. The layout declares
both with their sizes, so a high-density screen picks a large enough one
instead of enlarging 32 pixels, which looked blocky.
`script/generate_icons.py` resizes them with Lanczos and composites
nothing, since an opaque icon has no transparent pixels for iOS to fill
with black. For `apple-touch-icon.png`, `icon-192.png` and `icon-512.png`
it first enlarges the master to 125% about its center on the same navy
(`HOME_SCREEN_MARK_SCALE`), also with Lanczos, because at the master's own
scale the mark filled about 70% of the width and 48% of the height and
looked smaller than other apps' icons; it now fills about 88% and 60%, and
reaches 44.5% of the size from the center. The script fails if the
enlarged mark touches the icon's edge. The maskable icon stays at the
master's scale: the script fails if its mark reaches more than 40% of the
size from the center, the 80% safe circle every platform mask keeps, and
`spec/script/maskable_icon_spec.rb` repeats that check on the committed
file, since CI has no Pillow. The maskable mark reaches 35.6%. The nav shows `brand-mark.png`, the transparent mark, and
under the light palette `brand-mark-light.png`, the mark on a rounded dark
tile, through the `<picture>` source `DisplayPreferencesHelper#brand_mark`
writes; both are sized by height with `width: auto`, so the square tile
keeps its shape. Production
caches `public/` for a year, so the layout, the manifest and the service
worker's notification link every icon
through `PublicFileHelper#versioned_public_path`, which appends a digest of
the file's bytes: regenerated icons get new URLs with nothing to bump.
iOS still keeps the icon it saved when the app was added, so an existing
home-screen install shows new art only after it is removed and added again,
and the same goes for a new mark.
Standalone mode itself still needs no service worker — but one is registered
now, for the daily reminder (see `push-reminders.md`); `GET
/service-worker.js` serves it from the root path, since a worker's scope is
the directory it is served from.

**What the tab bar covers.** Where the tab bar shows, the layout's
standalone rule sets `--tab-bar-clearance` to the tab bar's height plus the
bottom safe area; everywhere else it is 0. The body's bottom padding and the
save banner read it, so the formula is written once.

**Pull-to-refresh in the installed app.** The layout's
`overscroll-behavior-y: none` removes the rubber-band bounce, and with it
the only way to reload a home-screen launch, which has no reload button.
`shared/_pull_to_refresh` adds the gesture back through the
`pull-to-refresh` controller's touch listeners, on top of that rule, which
is unchanged. It follows the iOS pattern: the nav
stays where it is while the layout's `[data-pull-content]` slides down with
UIScrollView's rubber-band resistance, and the spinner, layered beneath both,
shows in the gap that opens. The content's transform is cleared whenever it
comes to rest, since a transformed ancestor would re-anchor any
`position: fixed` element inside the page. It reads standalone mode from whether
its indicator is displayed, and only the layout's `display-mode: standalone`
block displays it, so that media query stays the one standalone test and a
browser tab keeps its native pull. The action is a full reload, and it
waits for `CodeGymSaveStatus.pending()` to clear first: that counts
requests on the wire, saves waiting in `CodeGymSaveStatus.queue`, and the
delayed saves the dashboard and /setup register through `watch()`, since
both hold an edit for a moment before sending it. A dashboard save waiting
to retry after a lost connection counts too, so a pull while offline is
cancelled rather than reloading onto the browser's offline page. `code_gym_bootstrap.js`
defines `window.CodeGymRequest` and `window.CodeGymSaveStatus` before the
importmap's modules load, so anything running at parse time finds them.
A save still pending after ten seconds cancels the pull rather than
reloading over it. The gesture also refuses to start while a text field has
focus, while any form is `inert` (the dashboard's submission and review
handoff), while a modal dialog is open (a daily card's swap sheet, whose
list would otherwise start a refresh behind it when dragged down at the top
of the page), or inside an inner area scrolled away from its top. On release the
content settles to a held gap and the spinner turns for at least half a
second, and a sessionStorage note lets the reloaded page open still held
with the spinner turning, and settle once loaded, since the page it was drawn on is gone by then.
`code_gym_bootstrap.js` owns that note (`CodeGymBootstrap.pullRefresh`): it reads
it and adds `pull-resuming` to `<html>`, whose CSS rule holds the content down by
`--pull-hold` in the first frame. The controller, a module that runs only after
the page has been drawn once, releases the class, holds the content itself and
fades the spinner in. Reading the note in the module alone drew the page at
rest first, then jumped it down. If the controller never connects, the
bootstrap releases the hold after ten seconds rather than leave the page low. Playwright cannot emulate
`display-mode`, so `spec/requests/pwa_spec.rb` pins the stylesheet rule and
`spec/system/pull_to_refresh_spec.rb` forces that rule on to drive the
gesture.

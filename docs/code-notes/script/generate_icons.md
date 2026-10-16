# script/generate_icons.py

## Running it

The script needs Pillow (`pip install pillow`). Nothing in the app runs it,
so the dependency stays out of the Gemfile.

## Masters

Both masters are opaque and carry their own navy fill, so the script only
resizes them. iOS fills transparent icon pixels with black, and an opaque
master has none. The art is smooth, so it scales with Lanczos.

## Home-screen scale

`apple-touch-icon.png`, `icon-192.png` and `icon-512.png` enlarge the master
by `HOME_SCREEN_MARK_SCALE` (125%) about its center before resizing. At the
master's own scale the mark filled about 70% of the width and 48% of the
height, and on a home screen it looked smaller than other apps' icons. The
enlargement uses Lanczos and pastes the result centered on a canvas of the
corner navy, so the master stays the single source. The script prints each
icon's reach and fails if any edge pixel differs from the fill, which would
mean a later master's mark was cut off.

## Maskable icon

The maskable icon is the master at 512px with no enlargement, because a
platform mask can crop to the 80% safe-zone circle, and the enlarged mark
reaches about 44.5% of the size from the center, past it. The script
measures the farthest pixel that differs from the corner color, prints it,
and fails when it is past 40% of the size from the center.

## FILL_TOLERANCE

An earlier master had a panel behind the mark whose navy was 1 to 3 levels
off the corner color in each channel. Nobody could see it, but an exact
comparison counted its corners as the mark and failed the safe-zone check.
The current violet master has no such panel and measures the same at a
tolerance of 0 or 8, but requiring a difference above 8 levels keeps the
check about the visible mark whatever near-navy noise a later master carries,
and still catches the mark's antialiased edges.

## favicon

The favicon is the kettlebell alone, opaque on the same navy, because the
braces make the mark too wide to read at 32px.

The layout offers two files so the browser can pick a size that fits the
screen. `favicon.ico` holds 16, 32 and 48px frames, which Pillow resizes from
the master with Lanczos, and `favicon-96.png` covers screens at 2x and 3x.
When the ICO held only 32px, a high-density tab enlarged it, and the mark
looked blocky.

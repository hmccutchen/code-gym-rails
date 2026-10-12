# script/generate_icons.py

## Running it

The script needs Pillow (`pip install pillow`). Nothing in the app runs it,
so the dependency stays out of the Gemfile.

## Masters

Both masters are opaque and carry their own navy fill, so the script only
resizes them. iOS fills transparent icon pixels with black, and an opaque
master has none. The art is smooth, so it scales with Lanczos.

## Maskable icon

The maskable icon is the plain icon at 512px, because the mark already sits
inside the 80% safe-zone circle every platform mask keeps. The script
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

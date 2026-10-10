# script/generate_icons.py

## Running it

The script needs Pillow (`pip install pillow`). Nothing in the app runs it,
so the dependency stays out of the Gemfile.

## Background

The home-screen icons are composited onto the layout's `--bg` because iOS
fills transparent icon pixels with black.

## PLAIN_ICON_WIDTH

The share of the icon's width the artwork spans. The barbell's ends sit
halfway down the art, clear of the corners iOS rounds off, so the art can run
nearly edge to edge.

## FAVICON_ASPECT

The barbell makes the art about 1.4 times wider than tall, so fitting it
whole into a square tab icon leaves the lifter too short to read at 16px. The
favicon trims the plates' outer halves down to this width-to-height ratio
instead.

## favicon

The favicon is transparent and fills its canvas edge to edge. A browser tab
has its own background, and the logo's outline is what keeps the barbell
visible on a dark one.

#!/usr/bin/env python3
# Rasterizes the favicon and home-screen icons from
# app/assets/images/logo-outlined-square.png. Needs Pillow (pip install pillow);
# nothing in the app runs this, so the dependency stays out of the Gemfile.
#
#   python3 script/generate_icons.py
#
# Nearest-neighbor throughout, so the pixel art keeps hard edges instead of
# blurring. The home-screen icons are composited onto the layout's --bg because
# iOS fills transparent icon pixels with black.
import re
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "app/assets/images/logo-outlined-square.png"
LAYOUT = ROOT / "app/views/layouts/application.html.erb"
PUBLIC = ROOT / "public"

# Share of the icon's width the artwork spans. The barbell's ends sit halfway
# down the art, clear of the corners iOS rounds off, so it can run nearly edge
# to edge. The maskable figure is sized so every opaque pixel sits inside the
# 80% safe-zone circle every platform mask keeps.
PLAIN_ICON_WIDTH = 0.96
MASKABLE_SAFE_DIAMETER = 0.8


def layout_background():
    hex_color = re.search(r"--bg:\s*#([0-9a-fA-F]{6})", LAYOUT.read_text()).group(1)
    return tuple(int(hex_color[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def artwork():
    source = Image.open(SOURCE).convert("RGBA")
    return source.crop(source.getchannel("A").getbbox())


def centered(art, size, art_width, background):
    height = round(art.height * art_width / art.width)
    canvas = Image.new("RGBA", (size, size), background)
    scaled = art.resize((art_width, height), Image.NEAREST)
    canvas.alpha_composite(scaled, ((size - art_width) // 2, (size - height) // 2))
    return canvas


def plain_icon(art, size, background):
    return centered(art, size, round(size * PLAIN_ICON_WIDTH), background)


def farthest_opaque_reach(art):
    alpha = art.getchannel("A").load()
    center_x, center_y = art.width / 2, art.height / 2
    return max(
        ((x + 0.5 - center_x) ** 2 + (y + 0.5 - center_y) ** 2) ** 0.5
        for y in range(art.height) for x in range(art.width) if alpha[x, y]
    )


def maskable_icon(art, size, background):
    scale = size * MASKABLE_SAFE_DIAMETER / 2 / farthest_opaque_reach(art)
    return centered(art, size, int(art.width * scale), background)


def favicon(art):
    # Transparent, and filled edge to edge: a browser tab has its own
    # background, and the outline is what keeps the barbell visible on a dark one.
    return centered(art, 32, 32, (0, 0, 0, 0))


def main():
    art = artwork()
    background = layout_background()

    favicon(art).save(PUBLIC / "favicon.ico", sizes=[(32, 32)])
    plain_icon(art, 180, background).convert("RGB").save(PUBLIC / "apple-touch-icon.png")
    plain_icon(art, 192, background).convert("RGB").save(PUBLIC / "icon-192.png")
    plain_icon(art, 512, background).convert("RGB").save(PUBLIC / "icon-512.png")
    maskable_icon(art, 512, background).convert("RGB").save(PUBLIC / "icon-maskable-512.png")


if __name__ == "__main__":
    main()

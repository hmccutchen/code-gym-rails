#!/usr/bin/env python3
# Run: python3 script/generate_icons.py (needs Pillow). Design notes: docs/code-notes/script/generate_icons.md
import re
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "app/assets/images/logo-outlined-square.png"
LAYOUT = ROOT / "app/views/layouts/application.html.erb"
PUBLIC = ROOT / "public"

PLAIN_ICON_WIDTH = 0.96
# Every opaque pixel of the maskable icon stays inside the 80% safe-zone circle all platform masks keep.
MASKABLE_SAFE_DIAMETER = 0.8

# Width-to-height ratio the favicon trims the plates to, so the lifter stays readable in a square tab icon.
FAVICON_ASPECT = 1.1


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


def trimmed_to_aspect(art, aspect):
    width = min(art.width, round(art.height * aspect))
    left = (art.width - width) // 2
    return art.crop((left, 0, left + width, art.height))


def favicon(art):
    # Transparent: a tab has its own background, and the outline keeps the barbell visible on a dark one.
    return centered(trimmed_to_aspect(art, FAVICON_ASPECT), 32, 32, (0, 0, 0, 0))


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

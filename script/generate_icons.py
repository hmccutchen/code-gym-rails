#!/usr/bin/env python3
# Run: python3 script/generate_icons.py (needs Pillow). Design notes: docs/code-notes/script/generate_icons.md
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP_ICON_SOURCE = ROOT / "app/assets/images/app-icon-master.png"
FAVICON_SOURCE = ROOT / "app/assets/images/favicon-master.png"
PUBLIC = ROOT / "public"

# Every pixel that differs from the fill stays inside the 80% safe-zone circle all platform masks keep.
MASKABLE_SAFE_RADIUS = 0.4
# Near-navy noise a few levels off the corner color is not part of the mark.
FILL_TOLERANCE = 8
FAVICON_ICO_SIZES = [16, 32, 48]
FAVICON_PNG_SIZE = 96


def master(path):
    return Image.open(path).convert("RGB")


def resized(image, size):
    return image.resize((size, size), Image.LANCZOS)


def differs_from(pixel, fill):
    return max(abs(channel - fill_channel) for channel, fill_channel in zip(pixel, fill)) > FILL_TOLERANCE


def farthest_mark_reach(image):
    pixels = image.load()
    fill = pixels[0, 0]
    center_x, center_y = image.width / 2, image.height / 2
    return max(
        ((x + 0.5 - center_x) ** 2 + (y + 0.5 - center_y) ** 2) ** 0.5
        for y in range(image.height) for x in range(image.width) if differs_from(pixels[x, y], fill)
    )


def maskable_icon(image, size):
    icon = resized(image, size)
    reach = farthest_mark_reach(icon)
    print(f"maskable mark reaches {reach:.1f}px from center, limit {MASKABLE_SAFE_RADIUS * size:.1f}px")
    if reach > MASKABLE_SAFE_RADIUS * size:
        raise SystemExit("The mark leaves the maskable safe zone.")
    return icon


def main():
    app_icon = master(APP_ICON_SOURCE)

    favicon = master(FAVICON_SOURCE)
    favicon.convert("RGBA").save(PUBLIC / "favicon.ico", sizes=[(size, size) for size in FAVICON_ICO_SIZES])
    resized(favicon, FAVICON_PNG_SIZE).save(PUBLIC / f"favicon-{FAVICON_PNG_SIZE}.png")
    resized(app_icon, 180).save(PUBLIC / "apple-touch-icon.png")
    resized(app_icon, 192).save(PUBLIC / "icon-192.png")
    resized(app_icon, 512).save(PUBLIC / "icon-512.png")
    maskable_icon(app_icon, 512).save(PUBLIC / "icon-maskable-512.png")


if __name__ == "__main__":
    main()

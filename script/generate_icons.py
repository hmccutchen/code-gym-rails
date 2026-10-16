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
# The home-screen icons enlarge the mark about the center; the maskable one keeps the master's scale for its safe zone.
HOME_SCREEN_MARK_SCALE = 1.25
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


def edge_pixels(image):
    pixels = image.load()
    last_x, last_y = image.width - 1, image.height - 1
    for i in range(image.width):
        yield from (pixels[i, 0], pixels[i, last_y], pixels[0, i], pixels[last_x, i])


def enlarged_mark(image, scale):
    fill = image.getpixel((0, 0))
    enlarged = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGB", image.size, fill)
    canvas.paste(enlarged, ((image.width - enlarged.width) // 2, (image.height - enlarged.height) // 2))
    if any(differs_from(pixel, fill) for pixel in edge_pixels(canvas)):
        raise SystemExit("The enlarged mark is cut off at the icon's edge.")
    return canvas


def report_reach(name, icon):
    reach = farthest_mark_reach(icon)
    print(f"{name}: mark reaches {reach:.1f}px from center, {reach / icon.width:.1%} of the size")


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
    home_screen = enlarged_mark(app_icon, HOME_SCREEN_MARK_SCALE)
    for name, size in [("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512)]:
        icon = resized(home_screen, size)
        report_reach(name, icon)
        icon.save(PUBLIC / name)
    maskable = maskable_icon(app_icon, 512)
    report_reach("icon-maskable-512.png", maskable)
    maskable.save(PUBLIC / "icon-maskable-512.png")


if __name__ == "__main__":
    main()

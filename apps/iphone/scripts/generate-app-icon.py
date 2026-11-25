#!/usr/bin/env python3
"""Generate Personal OS's iPhone AppIcon with Pillow, without external assets.

Run from any directory:
    python apps/iphone/scripts/generate-app-icon.py
    python apps/iphone/scripts/generate-app-icon.py --check

Requires Pillow 12.3.0 for byte-identical PNG regeneration. The 1024px marketing
icon is the RGB master; iPhone sizes are downsampled from that same master.
The full-bleed square background leaves corner masking to iOS.
"""

from __future__ import annotations

import argparse
import io
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


SIZE = 1024
SUPERSAMPLE = 4
CATALOG = Path(__file__).resolve().parents[1] / "Resources" / "Assets.xcassets"
ICONSET = CATALOG / "AppIcon.appiconset"
# Point sizes and display scales required by iPhone, plus the App Store master.
SLOTS = (
    ("iphone", 20, 2),
    ("iphone", 20, 3),
    ("iphone", 29, 2),
    ("iphone", 29, 3),
    ("iphone", 40, 2),
    ("iphone", 40, 3),
    ("iphone", 60, 2),
    ("iphone", 60, 3),
    ("ios-marketing", 1024, 1),
)


def mix(first: tuple[int, int, int], second: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    return tuple(round(a + (b - a) * amount) for a, b in zip(first, second))


def background() -> Image.Image:
    """A restrained indigo wash; the corners remain filled and opaque."""
    pixels = bytearray()
    for y in range(SIZE):
        ny = y / (SIZE - 1)
        for x in range(SIZE):
            nx = x / (SIZE - 1)
            light = math.exp(-(((nx - 0.30) / 0.90) ** 2 + ((ny - 0.13) / 0.82) ** 2) * 1.7)
            pixels.extend(mix((10, 16, 35), (31, 39, 77), light))
    return Image.frombytes("RGB", (SIZE, SIZE), bytes(pixels))


def cubic(
    start: tuple[float, float],
    first: tuple[float, float],
    second: tuple[float, float],
    end: tuple[float, float],
) -> list[tuple[float, float]]:
    points = []
    for index in range(1, 97):
        t = index / 96
        u = 1 - t
        points.append(tuple(u**3 * start[axis] + 3 * u**2 * t * first[axis]
                            + 3 * u * t**2 * second[axis] + t**3 * end[axis]
                            for axis in (0, 1)))
    return points


def mark_mask() -> Image.Image:
    """One open orbital P, drawn as a geometric path rather than a font."""
    mask = Image.new("L", (SIZE * SUPERSAMPLE, SIZE * SUPERSAMPLE))
    draw = ImageDraw.Draw(mask)
    points = [(342, 755), (342, 324)]
    points.extend(cubic(points[-1], (342, 294), (360, 276), (390, 276)))
    points.append((548, 276))
    points.extend(cubic(points[-1], (665, 276), (732, 334), (732, 428)))
    points.extend(cubic(points[-1], (732, 523), (665, 580), (548, 580)))
    points.append((488, 580))
    scaled = [(round(x * SUPERSAMPLE), round(y * SUPERSAMPLE)) for x, y in points]
    stroke = 86 * SUPERSAMPLE
    draw.line(scaled, fill=255, width=stroke, joint="curve")
    # Explicit round caps keep the connected orbit and stem equally soft.
    for x, y in (scaled[0], scaled[-1]):
        radius = stroke / 2
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
    return mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def mark_gradient() -> Image.Image:
    """Mint at the crown flows through cyan into a saturated blue stem."""
    ramp = Image.new("RGB", (1, SIZE))
    colors = []
    for y in range(SIZE):
        position = min(1.0, max(0.0, (y - 235) / 565))
        if position < 0.52:
            color = mix((153, 248, 219), (53, 220, 224), position / 0.52)
        else:
            color = mix((53, 220, 224), (57, 137, 246), (position - 0.52) / 0.48)
        colors.append(color)
    ramp.putdata(colors)
    return ramp.resize((SIZE, SIZE), Image.Resampling.BILINEAR)


def render_icon() -> Image.Image:
    image = background()
    mask = mark_mask()
    # A soft, low-opacity shadow separates the mark without a decorative halo.
    shadow_mask = ImageChops.offset(mask, 0, 15).filter(ImageFilter.GaussianBlur(25))
    shadow_mask = shadow_mask.point(lambda value: round(value * 0.28))
    image.paste((4, 9, 24), mask=shadow_mask)
    image.paste(mark_gradient(), mask=mask)
    return image


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=False, compress_level=9)
    return buffer.getvalue()


def outputs() -> dict[Path, bytes]:
    master = render_icon()
    info = {"author": "xcode", "version": 1}
    files = {CATALOG / "Contents.json": json_bytes({"info": info})}
    images = []
    for idiom, points, scale in SLOTS:
        filename = f"AppIcon-{points}@{scale}x.png"
        pixels = points * scale
        image = master if pixels == SIZE else master.resize((pixels, pixels), Image.Resampling.LANCZOS)
        files[ICONSET / filename] = png_bytes(image)
        images.append({"filename": filename, "idiom": idiom,
                       "scale": f"{scale}x", "size": f"{points}x{points}"})
    files[ICONSET / "Contents.json"] = json_bytes({"images": images, "info": info})
    return files


def validate() -> None:
    """Check actual exported metadata, pixels, color mode and asset coverage."""
    contents = json.loads((ICONSET / "Contents.json").read_text(encoding="utf-8"))
    assert contents["info"] == {"author": "xcode", "version": 1}, "Invalid icon set metadata"
    expected_slots = {(idiom, f"{points}x{points}", f"{scale}x") for idiom, points, scale in SLOTS}
    actual_slots = {(entry["idiom"], entry["size"], entry["scale"]) for entry in contents["images"]}
    assert actual_slots == expected_slots and len(contents["images"]) == len(SLOTS), "Incomplete icon slots"
    filenames = set()
    for entry in contents["images"]:
        filename = entry["filename"]
        assert filename not in filenames and Path(filename).name == filename, "Invalid or repeated filename"
        filenames.add(filename)
        pixels = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
        with Image.open(ICONSET / filename) as image:
            image.load()
            assert image.format == "PNG" and image.mode == "RGB", f"{filename}: expected opaque RGB PNG"
            assert image.size == (pixels, pixels), f"{filename}: unexpected pixel size {image.size}"
            assert "transparency" not in image.info, f"{filename}: transparency is not permitted"
            # Full-bleed dark blue corners prove that an iOS corner mask was not baked in.
            for corner in ((0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)):
                red, green, blue = image.getpixel(corner)
                assert 0 < red < green < blue < 110, f"{filename}: invalid background corner"
    catalog_info = json.loads((CATALOG / "Contents.json").read_text(encoding="utf-8"))
    assert catalog_info == {"info": contents["info"]}, "Invalid asset catalog metadata"
    assert {path.name for path in ICONSET.glob("*.png")} == filenames, "Unreferenced icon PNG"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="Verify exports and byte-identical regeneration without writing files")
    arguments = parser.parse_args()
    files = outputs()
    if arguments.check:
        mismatches = [str(path.relative_to(CATALOG.parent)) for path, content in files.items()
                      if not path.is_file() or path.read_bytes() != content]
        if mismatches:
            parser.exit(1, "AppIcon regeneration differs: " + ", ".join(mismatches) + "\n")
    else:
        ICONSET.mkdir(parents=True, exist_ok=True)
        for path, content in files.items():
            path.write_bytes(content)
    validate()
    action = "Verified byte-identical regeneration of" if arguments.check else "Generated and verified"
    print(f"{action} 9 opaque RGB PNGs: 8 iPhone slots + 1024x1024 ios-marketing.")
    print("Pixel sizes: 40, 60, 58, 87, 80, 120, 120, 180, 1024. Full-bleed square corners preserved.")
    print(ICONSET)


if __name__ == "__main__":
    main()

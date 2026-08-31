#!/usr/bin/env python3
"""Dock icon: black field, Diatype Z1, one live-blue glow.

Matches the popover: black, white type, blue only as the live edge.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
FONT = Path.home() / "Library/Fonts/Diatype/ABCDiatype-Medium-Trial.otf"
LIVE = (74, 130, 250)
INK = (255, 255, 255)


def rounded_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return m


def render(size: int = 1024) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 255))

    # AuraCard: colour gathers at the edge and falls to black in the middle.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse(
        (int(size * -0.05), int(size * 0.48), int(size * 1.05), int(size * 1.35)),
        fill=(*LIVE, 90),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=size * 0.12))
    layer = Image.alpha_composite(layer, glow)

    font = ImageFont.truetype(str(FONT), size=int(size * 0.42))
    text = "Z1"
    dummy = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = dummy.textbbox((0, 0), text, font=font)
    tw, th = x1 - x0, y1 - y0
    # Optical centre: Diatype sits a hair high, so drop it slightly.
    tx = (size - tw) / 2 - x0
    ty = (size - th) / 2 - y0 + size * 0.02

    type_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(type_layer).text((tx, ty), text, font=font, fill=(*INK, 255))
    layer = Image.alpha_composite(layer, type_layer)

    draw = ImageDraw.Draw(layer)
    inset = max(2, size // 256)
    draw.rounded_rectangle(
        (inset, inset, size - 1 - inset, size - 1 - inset),
        radius=int(size * 0.223) - inset,
        outline=(255, 255, 255, 28),
        width=max(1, size // 512),
    )

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(layer, (0, 0))
    out.putalpha(rounded_mask(size, int(size * 0.223)))
    return out


def write_svg(path: Path) -> None:
    path.write_text(
        """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="glow" cx="50%" cy="88%" r="62%">
      <stop offset="0" stop-color="#4A82FA" stop-opacity="0.45"/>
      <stop offset="1" stop-color="#000" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="squircle">
      <rect width="1024" height="1024" rx="228"/>
    </clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect width="1024" height="1024" fill="#000"/>
    <rect width="1024" height="1024" fill="url(#glow)"/>
    <text x="512" y="610" text-anchor="middle"
          font-family="ABC Diatype, Helvetica Neue, sans-serif"
          font-size="430" font-weight="500" fill="#fff">Z1</text>
  </g>
  <rect x="1.5" y="1.5" width="1021" height="1021" rx="226.5"
        fill="none" stroke="rgba(255,255,255,0.11)" stroke-width="2"/>
</svg>
""",
        encoding="utf-8",
    )


def main() -> None:
    master = render(1024)
    master.save(ROOT / "AppIcon-1024.png")
    write_svg(ROOT / "AppIcon.svg")

    iconset = ROOT / "AppIcon.iconset"
    if iconset.exists():
        for p in iconset.iterdir():
            p.unlink()
    else:
        iconset.mkdir()

    mapping = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, px in mapping.items():
        # Render each size from scratch so the type stays sharp.
        render(max(px, 256)).resize((px, px), Image.Resampling.LANCZOS).save(
            iconset / name
        )
    # True small sizes: render at target so the hairline doesn't vanish.
    for name, px in (("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32)):
        render(px * 8).resize((px, px), Image.Resampling.LANCZOS).save(iconset / name)

    icns = ROOT / "AppIcon.icns"
    subprocess.check_call(["iconutil", "-c", "icns", "-o", str(icns), str(iconset)])
    print(f"wrote {icns}")


if __name__ == "__main__":
    main()

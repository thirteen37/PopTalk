#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["resvg-py>=0.2", "pillow>=10.1"]
# ///
"""Render icon concept SVGs to PNG previews and a contact sheet.

Usage: assets/icon/render.py         (renders every assets/icon/concepts/<n>-<slug>/)
       assets/icon/render.py build   (AppIcon.icns + MenuBar*.png from the promoted SVGs, for install.zsh)
"""
import io
import subprocess
import sys
import tempfile
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw, ImageFont

ICON = Path(__file__).parent
ROOT = ICON / "concepts"
LIGHT, DARK = "#ECECEC", "#1E1E1E"


def render(svg: Path, size: int) -> Image.Image:
    png = resvg_py.svg_to_bytes(svg_path=str(svg), width=size, height=size)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def tint(glyph: Image.Image, color: str) -> Image.Image:
    """Mimic a template image: keep alpha, replace colour."""
    out = Image.new("RGBA", glyph.size, color)
    out.putalpha(glyph.getchannel("A"))
    return out


def strip(d: Path, bg: str) -> Image.Image:
    """300x44 menu-bar strip: normal + attention at 18pt@2x, then both at 1x."""
    fg = "#000000" if bg == LIGHT else "#FFFFFF"
    im = Image.new("RGBA", (300, 44), bg)
    x = 24
    for name in ("menubar.svg", "menubar-attention.svg"):
        im.alpha_composite(tint(render(d / name, 36), fg), (x, 4))
        x += 60
    x += 20
    for name in ("menubar.svg", "menubar-attention.svg"):
        im.alpha_composite(tint(render(d / name, 18), fg), (x, 13))
        x += 34
    return im


def main() -> None:
    concepts = sorted(p for p in ROOT.iterdir() if p.is_dir())
    cells = []
    for d in concepts:
        render(d / "app.svg", 1024).save(d / "app-1024.png")
        render(d / "app.svg", 128).save(d / "app-128.png")
        light, dark = strip(d, LIGHT), strip(d, DARK)
        light.save(d / "menubar-light.png")
        dark.save(d / "menubar-dark.png")
        cells.append((d.name, render(d / "app.svg", 256), render(d / "app.svg", 64), light, dark))

    col, pad = 340, 20
    sheet = Image.new("RGBA", (col * len(cells) + pad, 520), "#FFFFFF")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=20)
    for i, (name, big, small, light, dark) in enumerate(cells):
        x = pad + i * col
        draw.text((x, 14), name, fill="#333", font=font)
        sheet.alpha_composite(big, (x + 22, 44))
        sheet.alpha_composite(small, (x + 118, 304))
        sheet.alpha_composite(light, (x, 384))
        sheet.alpha_composite(dark, (x, 436))
    sheet.save(ROOT / "contact-sheet.png")
    print(f"rendered {len(cells)} concepts -> {ROOT / 'contact-sheet.png'}")


def build() -> None:
    """AppIcon.icns via iconutil, plus 18pt template PNGs (@1x/@2x) for the status item."""
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            render(ICON / "AppIcon.svg", pt).save(iconset / f"icon_{pt}x{pt}.png")
            render(ICON / "AppIcon.svg", pt * 2).save(iconset / f"icon_{pt}x{pt}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICON / "AppIcon.icns")], check=True)
    for name in ("MenuBar", "MenuBarAttention"):
        render(ICON / f"{name}.svg", 18).save(ICON / f"{name}.png")
        render(ICON / f"{name}.svg", 36).save(ICON / f"{name}@2x.png")
    print(f"built AppIcon.icns and MenuBar PNGs in {ICON}")


if __name__ == "__main__":
    build() if sys.argv[1:] == ["build"] else main()

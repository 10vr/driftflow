"""Draws the installer window's background: a light card in the brand colours with an arrow from
where Driftflow's icon sits to the Applications folder, and a line on opening it the first time.

    python3 Resources/DMG/make_background.py <folder with Inter's .ttf files>

Inter (SIL Open Font License): https://github.com/rsms/inter/releases. Writes background.tiff
(1x and 2x in one file) next to this script; dmg_settings.py places the icons to match.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
FONTS = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("fonts")
W, H = 640, 400  # the window's content size, in points
APP, APPS = (170, 205), (470, 205)  # icon centres, as in dmg_settings.py
PINK, VIOLET, CYAN = (255, 93, 177), (155, 92, 255), (79, 231, 255)
INK, SOFT = (29, 29, 31), (110, 110, 118)


def render(scale: int) -> Image.Image:
    s = scale
    img = Image.new("RGBA", (W * s, H * s), (250, 250, 252, 255))
    for (x, y), r, color, alpha in [((40, 20), 230, PINK, 34), ((600, 60), 220, VIOLET, 26), ((330, 440), 260, CYAN, 34)]:
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse(((x - r) * s, (y - r) * s, (x + r) * s, (y + r) * s), fill=(*color, alpha))
        img = Image.alpha_composite(img, layer.filter(ImageFilter.GaussianBlur(r * s * 0.5)))

    draw = ImageDraw.Draw(img)

    def centered(text, y, font, fill):
        left, top, right, _ = draw.textbbox((0, 0), text, font=font)
        draw.text(((W * s - (right - left)) / 2 - left, y * s - top), text, font=font, fill=fill)

    centered("Drag Driftflow to Applications", 44, ImageFont.truetype(str(FONTS / "InterDisplay-SemiBold.ttf"), 22 * s), INK)

    # A gradient arrow between the two icons.
    x0, x1, y = APP[0] + 62, APPS[0] - 62, APP[1] - 6
    arrow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    mask = Image.new("L", img.size, 0)
    m = ImageDraw.Draw(mask)
    m.rounded_rectangle((x0 * s, (y - 2.5) * s, (x1 - 10) * s, (y + 2.5) * s), radius=2.5 * s, fill=255)
    m.polygon([((x1 - 18) * s, (y - 11) * s), (x1 * s, y * s), ((x1 - 18) * s, (y + 11) * s)], fill=255)
    gradient = Image.new("RGBA", img.size)
    px = gradient.load()
    for gx in range(int(x0 * s), int(x1 * s) + 1):
        t = (gx - x0 * s) / ((x1 - x0) * s)
        a, b, u = (PINK, VIOLET, t * 2) if t < 0.5 else (VIOLET, CYAN, (t - 0.5) * 2)
        c = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3))
        for gy in range(int((y - 12) * s), int((y + 12) * s) + 1):
            px[gx, gy] = (*c, 255)
    arrow.paste(gradient, (0, 0), mask)
    img = Image.alpha_composite(img, arrow)

    draw = ImageDraw.Draw(img)
    note = ImageFont.truetype(str(FONTS / "Inter-Medium.ttf"), 12 * s)
    centered("Then open Driftflow from Applications. The first time, right-click it and choose Open.", 338, note, SOFT)
    return img.convert("RGB")


with tempfile.TemporaryDirectory() as tmp:
    one, two = Path(tmp) / "bg.png", Path(tmp) / "bg@2x.png"
    render(1).save(one, dpi=(72, 72))
    render(2).save(two, dpi=(144, 144))
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")], check=True)
    render(2).save(Path(tmp) / "preview.png")
    if len(sys.argv) > 2:
        render(2).save(sys.argv[2])
print(f"Wrote {HERE / 'background.tiff'}")

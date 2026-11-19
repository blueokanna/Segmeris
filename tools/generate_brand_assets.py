"""Rebuild Segmeris raster branding from the two original JPEGs.

Python 3.10+, Pillow (python -m pip install Pillow). No large tracing toolchain.
Run from any directory: python tools/generate_brand_assets.py

Launcher PNG/ICO pixels are LANCZOS resizes of the original photographs, never
rasterized approximations. Vector artwork uses separately measured cubic paths;
preview.png and fit_report.json compare those paths to each original silhouette.
Dart/XML source is maintained separately; geometry.json exposes the shared data.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/brand"
# 1000-unit viewBox. Circular arcs use kappa = 0.55228475. Positions were
# measured on each JPEG separately; the dark symbol is NOT the light inverse.
LIGHT = [
    "M674,211.5 L479,211.5 C388.15,211.5 314.5,285.15 314.5,376 C314.5,466.85 388.15,540.5 479,540.5 L520,540.5 C565.56,540.5 602.5,577.44 602.5,623 C602.5,668.56 565.56,705.5 520,705.5 L408.5,705.5",
    "M633,252.7 L479,252.7 C410.91,252.7 355.7,307.91 355.7,376 C355.7,444.09 410.91,499.3 479,499.3 L520,499.3 C588.32,499.3 643.7,554.68 643.7,623 C643.7,691.32 588.32,746.7 520,746.7 L367.3,746.7",
    "M591.8,293.9 L479,293.9 C433.66,293.9 396.9,330.66 396.9,376 C396.9,421.34 433.66,458.1 479,458.1 L520,458.1 C611.07,458.1 684.9,531.93 684.9,623 C684.9,714.07 611.07,787.9 520,787.9 L326.1,787.9",
    "M550.6,335.1 L479,335.1 C456.41,335.1 438.1,353.41 438.1,376 C438.1,394.27 450.08,409.74 466.6,414.99",
    "M449.4,664.1 L520,664.1 C542.7,664.1 561.1,645.7 561.1,623 C561.1,604.72 549.17,589.23 532.7,583.86",
    "M490.9,376 L509.1,376",
    "M490.9,623 L509.1,623",
]
LIGHT_WIDTH = 23.2
DARK = [
    "M661,282 L472,282 C407.11,282 354.5,334.39 354.5,399 C354.5,463.61 407.11,516 472,516 L528,516 C574.94,516 613,554.06 613,601 C613,647.94 574.94,686 528,686 L338,686 L338,718 L528,718 C592.62,718 645,665.62 645,601 C645,536.38 592.62,484 528,484 L472,484 C424.78,484 386.5,445.94 386.5,399 C386.5,352.06 424.78,314 472,314 L661,314 Z",
    "M661,330.5 L472,330.5 C434.17,330.5 403.5,361.17 403.5,399 C403.5,436.83 434.17,467.5 472,467.5 L526,467.5 C594,467.5 650,520 661,589 C665,508 604,435.5 526,435.5 L472,435.5 C451.84,435.5 435.5,419.16 435.5,399 C435.5,378.84 451.84,362.5 472,362.5 L661,362.5 Z",
    "M338,669.5 L528,669.5 C565.83,669.5 596.5,638.83 596.5,601 C596.5,563.17 565.83,532.5 528,532.5 L474,532.5 C406,532.5 350,480 338,411 C334,492 396,564.5 474,564.5 L528,564.5 C548.16,564.5 564.5,580.84 564.5,601 C564.5,621.16 548.16,637.5 528,637.5 L338,637.5 Z",
]


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def png(source: Image.Image, size: int, path: Path) -> None:
    save(source.resize((size, size), Image.Resampling.LANCZOS), path)


def points(path: str) -> list[tuple[float, float]]:
    """Sample the same measured cubic data used by Flutter and Android."""
    import re
    tokens = re.findall(r"[MLCZ]|-?\d+(?:\.\d+)?", path)
    result: list[tuple[float, float]] = []
    i = 0
    while i < len(tokens):
        op = tokens[i]
        i += 1
        if op in ("M", "L"):
            result.append((float(tokens[i]), float(tokens[i + 1])))
            i += 2
        elif op == "C":
            start = result[-1]
            a, b, end = [tuple(map(float, tokens[i + j:i + j + 2])) for j in (0, 2, 4)]
            i += 6
            for step in range(1, 101):
                t = step / 100
                u = 1 - t
                result.append(tuple(u**3 * start[d] + 3*u*u*t*a[d] + 3*u*t*t*b[d] + t**3*end[d] for d in (0, 1)))
        elif op == "Z":
            result.append(result[0])
    return result


def vector_mask(dark: bool, size: int = 2048) -> Image.Image:
    mask = Image.new("L", (size, size))
    draw = ImageDraw.Draw(mask)
    scale = size / 1000
    for path in DARK if dark else LIGHT:
        coords = [(x * scale, y * scale) for x, y in points(path)]
        if dark:
            draw.polygon(coords, fill=255)
        else:
            width = round(LIGHT_WIDTH * scale)
            draw.line(coords, fill=255, width=width, joint="curve")
            radius = LIGHT_WIDTH * scale / 2
            # Pillow's wide-line joins can leave subpixel cracks along dense
            # samples; stamp the circular pen at each point as Canvas does.
            for x, y in coords:
                draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=255)
    return mask


def foreground(source: Image.Image, dark: bool) -> Image.Image:
    # Preserve the source edge coverage while removing its flat background.
    alpha = source.convert("L")
    if not dark:
        alpha = ImageOps.invert(alpha)
    # The dark photograph has a one-pixel grey border. It is background,
    # not logo geometry: exclude it (and JPEG background noise) only in
    # transparent derivatives. Opaque launcher icons retain the full source.
    alpha = alpha.point(lambda p: 0 if p <= 8 else p)
    cleaned = Image.new("L", source.size)
    bounds = (0.28, 0.18, 0.72, 0.82) if not dark else (0.32, 0.26, 0.68, 0.74)
    box = tuple(round(value * source.width) for value in bounds)
    cleaned.paste(alpha.crop(box), box)
    result = Image.new("RGBA", source.size, "white" if dark else "black")
    result.putalpha(cleaned)
    return result


def svg(dark: bool) -> str:
    if dark:
        paths = "\n".join(f'  <path d="{path}" fill="white"/>' for path in DARK)
    else:
        paths = "\n".join(f'  <path d="{path}" fill="none" stroke="black" stroke-width="{LIGHT_WIDTH}" stroke-linecap="round"/>' for path in LIGHT)
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">\n{paths}\n</svg>\n'


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sources = {name: Image.open(ROOT / f"assets/Segmeris{name.title()}.jpg").convert("RGB") for name in ("light", "dark")}
    report = {}
    preview = Image.new("RGB", (1200, 840), "#eceef2")
    draw = ImageDraw.Draw(preview)
    for row, (name, source) in enumerate(sources.items()):
        dark = name == "dark"
        mask = vector_mask(dark)
        original = source.convert("L").point(lambda p: 255 if (p > 127 if dark else p < 128) else 0)
        vector = mask.point(lambda p: 255 if p > 127 else 0)
        intersection = sum(ImageChops.multiply(original, vector).histogram()[128:])
        union = sum(ImageChops.lighter(original, vector).histogram()[128:])
        report[name] = {"source_sha256": hashlib.sha256((ROOT / f"assets/Segmeris{name.title()}.jpg").read_bytes()).hexdigest(), "silhouette_iou": round(intersection / union, 6), "view_box": [0, 0, 1000, 1000]}
        rendered = Image.new("RGB", source.size, "black" if dark else "white")
        rendered.paste("white" if dark else "black", mask=mask)
        difference = Image.new("RGB", source.size, "#e5e7eb")
        difference.paste("#16a34a", mask=ImageChops.multiply(original, vector))
        difference.paste("#dc2626", mask=ImageChops.subtract(original, vector))
        difference.paste("#2563eb", mask=ImageChops.subtract(vector, original))
        for col, image in enumerate((source, rendered, difference)):
            preview.paste(image.resize((390, 390), Image.Resampling.LANCZOS), (5 + col * 400, 25 + row * 420))
            draw.text((12 + col * 400, 6 + row * 420), f'{name} / {("original", "fitted vector", "green=match red=source blue=vector")[col]}', fill="black")
        png(source, 1024, OUT / f"logo-{name}.png")
        save(rendered.resize((1000, 1000), Image.Resampling.LANCZOS), OUT / f"vector-preview-{name}.png")
        (OUT / f"logo-{name}.svg").write_text(svg(dark), encoding="utf-8")

        # Android launcher, adaptive foreground and pre-12 launch resources.
        res = ROOT / "android/app/src/main/res"
        for density, size, factor in (("mdpi",48,1), ("hdpi",72,1.5), ("xhdpi",96,2), ("xxhdpi",144,3), ("xxxhdpi",192,4)):
            suffix = f"night-{density}" if dark else density
            png(source, size, res / f"mipmap-{suffix}/ic_launcher.png")
            # Original art occupies a ~0.6-diameter box; fit it within the
            # adaptive icon's 66/108 circular safe zone, keeping all margins.
            fg = foreground(source, dark).resize((round(108 * factor * .85),) * 2, Image.Resampling.LANCZOS)
            canvas = Image.new("RGBA", (round(108 * factor),) * 2)
            canvas.alpha_composite(fg, ((canvas.width-fg.width)//2,) * 2)
            save(canvas, res / f"drawable-{suffix}/ic_launcher_foreground.png")
            png(source, round(192 * factor), res / f"drawable-{suffix}/brand_launch.png")

        # Web: direct source downscales, including safe-zone maskable images.
        for size in (192, 512):
            infix = "-dark" if dark else ""
            png(source, size, ROOT / f"web/icons/Icon{infix}-{size}.png")
            png(source, size, ROOT / f"web/icons/Icon-maskable{infix}-{size}.png")
        png(source, 48, ROOT / ("web/favicon-dark.png" if dark else "web/favicon.png"))
        png(source, 180, ROOT / f"web/icons/apple-touch-icon{'-dark' if dark else ''}.png")

        # Linux resources for the distribution packager. The desktop entry
        # uses the standard icon-theme name; the runner is not modified here.
        png(source, 512, ROOT / f"linux/resources/segmeris{'-dark' if dark else ''}.png")

        # iOS launch appearance follows UIKit traits; 192pt logical canvas.
        launch = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
        for scale in (1, 2, 3):
            filename = f"LaunchImage{'-dark' if dark else ''}{'@'+str(scale)+'x' if scale > 1 else ''}.png"
            png(source, 192 * scale, launch / filename)

    # iOS 18 Single Size appearance slots. Dark art is source-derived alpha,
    # per Apple's guidance; the OS supplies the dark icon background.
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    png(sources["light"], 1024, ios / "Icon-App-1024x1024@1x.png")
    png(foreground(sources["dark"], True), 1024, ios / "Icon-App-1024x1024-dark.png")
    # Also update existing legacy raster sizes without restoring deleted paths.
    for path in ios.glob("Icon-App-*.png"):
        if "dark" not in path.name and "1024" not in path.name:
            with Image.open(path) as old:
                size = old.width
            png(sources["light"], size, path)
    mac = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        png(sources["light"], size, mac / f"app_icon_{size}.png")
    png(sources["dark"], 1024, mac.parent / "DockDark.imageset/dark.png")
    icon = ROOT / "windows/runner/resources/app_icon.ico"
    icon.parent.mkdir(parents=True, exist_ok=True)
    sources["light"].resize((256, 256), Image.Resampling.LANCZOS).save(icon, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    # The Windows runner selects this resource for dark windows.
    sources["dark"].resize((256, 256), Image.Resampling.LANCZOS).save(icon.with_name("app_icon_dark.ico"), sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    save(preview, OUT / "preview.png")
    (OUT / "geometry.json").write_text(json.dumps({"viewBox": 1000, "lightStrokeWidth": LIGHT_WIDTH, "light": LIGHT, "dark": DARK}, indent=2) + "\n", encoding="utf-8")
    (OUT / "fit_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

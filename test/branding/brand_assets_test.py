"""Focused generated-resource checks; run with Python 3.10+ and Pillow."""
import json
import math
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "android/app/src/main/res"
NS = "{http://schemas.android.com/apk/res/android}"


class BrandAssetsTest(unittest.TestCase):
    def test_launcher_images_are_actual_original_resizes(self):
        pairs = [
            ("light", "web/icons/Icon-512.png", 512),
            ("dark", "web/icons/Icon-dark-512.png", 512),
            ("light", "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", 192),
            ("dark", "android/app/src/main/res/mipmap-night-xxxhdpi/ic_launcher.png", 192),
            ("light", "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png", 1024),
            ("light", "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png", 256),
            ("light", "linux/resources/segmeris.png", 512),
            ("dark", "linux/resources/segmeris-dark.png", 512),
        ]
        for appearance, relative, size in pairs:
            with self.subTest(path=relative):
                original = Image.open(ROOT / f"assets/Segmeris{appearance.title()}.jpg").convert("RGB")
                actual = Image.open(ROOT / relative).convert("RGB")
                expected = original.resize((size, size), Image.Resampling.LANCZOS)
                self.assertIsNone(ImageChops.difference(expected, actual).getbbox())

    def test_vector_geometry_is_shared_and_not_inverted(self):
        geometry = json.loads((ROOT / "assets/brand/geometry.json").read_text())
        dart = (ROOT / "lib/src/app/brand_logo.dart").read_text(encoding="utf-8")
        self.assertEqual(len(geometry["light"]), 7)
        self.assertEqual(len(geometry["dark"]), 3)
        for mode, qualifier in (("light", "drawable"), ("dark", "drawable-night")):
            xml = ET.parse(ANDROID / qualifier / "brand_splash_vector.xml").getroot()
            paths = {node.attrib[NS + "name"]: node.attrib[NS + "pathData"] for node in xml.iter("path")}
            for i, path in enumerate(geometry[mode]):
                self.assertIn("'" + path + "'", dart)
                name = ("ribbon" if mode == "light" else "silhouette") + str(i)
                self.assertEqual(paths[name], path)
            animation = ET.parse(ANDROID / qualifier / "brand_splash_motion.xml").getroot()
            for target in animation:
                self.assertIn(target.attrib[NS + "name"], paths)
                animator = target.attrib[NS + "animation"].split("/")[-1]
                ET.parse(ANDROID / "animator" / (animator + ".xml"))
        report = json.loads((ROOT / "assets/brand/fit_report.json").read_text())
        self.assertGreater(report["light"]["silhouette_iou"], .95)
        self.assertGreater(report["dark"]["silhouette_iou"], .95)

    def test_adaptive_foreground_fits_safe_zone_without_photo_border(self):
        for qualifier in ("drawable-xxxhdpi", "drawable-night-xxxhdpi"):
            image = Image.open(ANDROID / qualifier / "ic_launcher_foreground.png")
            self.assertEqual(image.size, (432, 432))
            alpha = image.getchannel("A")
            self.assertEqual(alpha.getpixel((0, 0)), 0)
            # 66dp safe circle within a 108dp layer; ignore barely visible
            # interpolation/JPEG noise when checking the source silhouette.
            for y in range(image.height):
                for x in range(image.width):
                    if alpha.getpixel((x, y)) > 127:
                        self.assertLess(math.hypot(x - 216, y - 216), 132)

    def test_ios_dark_appearance_and_launch_assets_resolve(self):
        assets = ROOT / "ios/Runner/Assets.xcassets"
        for name in ("AppIcon.appiconset", "LaunchImage.imageset"):
            folder = assets / name
            content = json.loads((folder / "Contents.json").read_text())
            dark = []
            for entry in content["images"]:
                self.assertTrue((folder / entry["filename"]).is_file())
                if entry.get("appearances") == [{"appearance": "luminosity", "value": "dark"}]:
                    dark.append(entry)
            self.assertTrue(dark)
        icon = Image.open(assets / "AppIcon.appiconset/Icon-App-1024x1024-dark.png")
        self.assertEqual(icon.mode, "RGBA")
        self.assertEqual(icon.getpixel((0, 0))[3], 0)
        ET.parse(ROOT / "ios/Runner/Base.lproj/LaunchScreen.storyboard")

    def test_manifests_use_supported_icon_fields_and_same_install_identity(self):
        light = json.loads((ROOT / "web/manifest.json").read_text())
        dark = json.loads((ROOT / "web/manifest-dark.json").read_text())
        self.assertEqual(light["id"], dark["id"])
        self.assertEqual(light["start_url"], dark["start_url"])
        for manifest in (light, dark):
            for icon in manifest["icons"]:
                self.assertNotIn("media", icon)
                file = ROOT / "web" / icon["src"]
                self.assertTrue(file.is_file())
                with Image.open(file) as image:
                    self.assertEqual(icon["sizes"], f"{image.width}x{image.height}")

    def test_windows_ico_contains_real_multiple_resolutions(self):
        for filename in ("app_icon.ico", "app_icon_dark.ico"):
            with Image.open(ROOT / "windows/runner/resources" / filename) as image:
                self.assertEqual(image.ico.sizes(), {(s, s) for s in (16, 24, 32, 48, 64, 128, 256)})


if __name__ == "__main__":
    unittest.main()

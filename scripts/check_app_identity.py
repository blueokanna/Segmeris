"""Validate application identifiers and the Android JNI class contract."""

from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.blue.segmeris"


def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    gradle = read("android/app/build.gradle.kts")
    for key in ("namespace", "applicationId"):
        require(re.search(rf'{key}\s*=\s*"{re.escape(APP_ID)}"', gradle), key)
    for source in ("main", "test", "androidTest"):
        base = ROOT / "android/app/src" / source / "kotlin"
        for path in base.rglob("*.kt"):
            require(
                re.search(rf"^package {re.escape(APP_ID)}$", path.read_text(encoding="utf-8"), re.M),
                f"Unexpected Kotlin package: {path}",
            )
            require(path.parent.relative_to(base).as_posix() == APP_ID.replace(".", "/"),
                    f"Kotlin source path does not match package: {path}")
    manifest = ET.fromstring(read("android/app/src/main/AndroidManifest.xml"))
    android_name = "{http://schemas.android.com/apk/res/android}name"
    for element in manifest.findall("./application/*"):
        name = element.get(android_name, "")
        if element.tag in ("activity", "service"):
            require(name.startswith(APP_ID + "."), f"Unexpected component: {name}")
    bridge_class = APP_ID + ".MediaTranscoder"
    require(f'"{bridge_class}"' in read("rust/src/api/downloader.rs"), "JNI class mismatch")
    require(f"-keep class {bridge_class}" in read("android/app/proguard-rules.pro"),
            "Missing JNI keep rule")
    for platform in ("ios", "macos"):
        project = read(f"{platform}/Runner.xcodeproj/project.pbxproj")
        identifiers = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", project)
        require(bool(identifiers), f"Missing {platform} bundle identifiers")
        require(all(value in (APP_ID, APP_ID + ".RunnerTests") for value in identifiers),
                f"Unexpected {platform} bundle identifiers: {identifiers}")
    require(f"PRODUCT_BUNDLE_IDENTIFIER = {APP_ID}" in read("macos/Runner/Configs/AppInfo.xcconfig"),
            "macOS app identifier mismatch")
    require(f'set(APPLICATION_ID "{APP_ID}")' in read("linux/CMakeLists.txt"),
            "Linux app identifier mismatch")
    resource = read("windows/runner/Runner.rc")
    require(f'VALUE "CompanyName", "{APP_ID}"' in resource, "Windows publisher mismatch")
    require("com.example" not in resource, "Windows template metadata remains")
    print(f"Application identifiers and Android JNI agree: {APP_ID}")


if __name__ == "__main__":
    main()

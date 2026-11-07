"""Check first-party release versions and reject mismatched release tags."""

import os
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


def match(path, pattern):
    result = re.search(pattern, read(path), re.MULTILINE)
    if result is None:
        raise SystemExit(f"Missing version in {path}")
    return result.group(1)


def main():
    expected = match("pubspec.yaml", r"^version: (\d+\.\d+\.\d+)\+\d+$")
    versions = {}
    for path in ("rust/Cargo.toml", "rust/core/Cargo.toml", "rust/fuzz/Cargo.toml"):
        versions[path] = tomllib.loads(read(path))["package"]["version"]
    versions["rust_builder/pubspec.yaml"] = match(
        "rust_builder/pubspec.yaml", r"^version: (\S+)$"
    )
    versions["Android bridge"] = match(
        "rust_builder/android/build.gradle", r"^version '([^']+)'$"
    )
    for platform in ("ios", "macos"):
        path = f"{platform}/Runner.xcodeproj/project.pbxproj"
        for index, version in enumerate(re.findall(r"MARKETING_VERSION = ([^;]+);", read(path))):
            versions[f"{platform} target {index}"] = version
    for platform in ("ios", "macos"):
        path = f"rust_builder/{platform}/rust_lib_segmeris.podspec"
        versions[path] = match(path, r"s\.version\s*=\s*'([^']+)'")
    versions["Windows fallback"] = match(
        "windows/runner/Runner.rc", r'^#define VERSION_AS_STRING "([^"]+)"$'
    )
    runtime = tomllib.loads(read("rust/Cargo.toml"))
    versions["core dependency"] = runtime["dependencies"]["segmeris-core"]["version"].lstrip("=")
    lock = tomllib.loads(read("rust/Cargo.lock"))
    for package in lock["package"]:
        if package["name"] in ("rust_lib_segmeris", "segmeris-core"):
            versions[f"Cargo.lock: {package['name']}"] = package["version"]
    fuzz = tomllib.loads(read("rust/fuzz/Cargo.lock"))
    versions["fuzz lock"] = next(
        p["version"] for p in fuzz["package"] if p["name"] == "segmeris-parser-fuzz"
    )
    versions["pubspec.lock: bridge"] = match(
        "pubspec.lock", r'(?s)\n  rust_lib_segmeris:\n.*?\n    version: "([^"]+)"'
    )
    for label, version in versions.items():
        if version != expected:
            raise SystemExit(f"{label}: expected {expected}, found {version}")
    tags = [os.environ.get("RELEASE_TAG", "")]
    ref = os.environ.get("GITHUB_REF", "")
    if ref.startswith("refs/tags/"):
        tags.append(ref.removeprefix("refs/tags/"))
    for tag in tags:
        if tag and tag != f"v{expected}":
            raise SystemExit(f"Release tag must be v{expected}, found {tag!r}")
    print(f"First-party packages and release tags agree: {expected}")


if __name__ == "__main__":
    main()

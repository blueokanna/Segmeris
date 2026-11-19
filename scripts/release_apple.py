"""Verify Apple app runtimes and package macOS zip or an unsigned Payload IPA."""

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

from release import versions

MACHO_MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def macho(path):
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGICS


def verify_app(app, platform, arch):
    contents = app / "Contents" if platform == "macos" else app
    with (contents / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version, build_number = versions()
    if (info.get("CFBundleIdentifier") != "com.blue.segmeris"
            or info.get("CFBundleShortVersionString") != version
            or str(info.get("CFBundleVersion")) != build_number):
        raise ValueError("Apple app identifier/version does not match the release")
    executable = contents / "MacOS" / info["CFBundleExecutable"] if platform == "macos" else app / info["CFBundleExecutable"]
    framework_name = "FlutterMacOS" if platform == "macos" else "Flutter"
    frameworks = contents / "Frameworks"
    if not (frameworks / f"{framework_name}.framework" / framework_name).is_file():
        raise ValueError("Flutter framework is missing from the app")
    binaries = [path for path in app.rglob("*") if macho(path)]
    if executable not in binaries:
        raise ValueError("Apple app executable is missing or is not Mach-O")
    rust_present = False
    seen = set()
    for binary in binaries:
        if binary.resolve() in seen:
            continue
        seen.add(binary.resolve())
        slices = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        if arch not in slices:
            raise ValueError(f"{binary} does not contain the required {arch} slice")
        symbols = subprocess.check_output(["nm", "-arch", arch, "-gU", str(binary)], text=True)
        rust_present |= any(line.endswith(" _frb_get_rust_content_hash") for line in symbols.splitlines())
        dependencies = subprocess.check_output(["otool", "-arch", arch, "-L", str(binary)], text=True)
        for line in dependencies.splitlines()[1:]:
            name = line.strip().split(" (", 1)[0]
            if name.startswith("/") and not name.startswith(("/System/Library/", "/usr/lib/")):
                raise ValueError(f"Non-system dependency is not relocatable: {binary}: {name}")
            if name.startswith("@rpath/"):
                suffix = name.removeprefix("@rpath/")
                if not (frameworks / suffix).exists() and not suffix.startswith("libswift"):
                    raise ValueError(f"Framework dependency is missing: {binary}: {name}")
    if not rust_present:
        raise ValueError("No linked Rust FFI entry point exists in the packaged app")
    if not any(path.is_dir() and path.name == "flutter_assets" for path in app.rglob("flutter_assets")):
        raise ValueError("Flutter application assets are missing")


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if not any(name.startswith("Payload/") and ".app/Info.plist" in name for name in names):
            raise ValueError("Unsigned IPA must contain Payload/<application>.app/Info.plist")
        if "UNSIGNED-README.txt" not in names:
            raise ValueError("Unsigned IPA is missing the installation limitation")


def package(app, platform, arch, destination):
    verify_app(app, platform, arch)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if platform == "macos":
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination)], check=True)
    else:
        with tempfile.TemporaryDirectory(prefix="segmeris-ipa-") as temporary:
            staging = Path(temporary)
            payload = staging / "Payload"
            payload.mkdir()
            shutil.copytree(app, payload / app.name, symlinks=True)
            (staging / "UNSIGNED-README.txt").write_text(
                "This IPA is UNSIGNED and cannot be installed directly.\n"
                "Sign the application and embedded frameworks with an Apple signing identity "
                "and a matching provisioning profile, then repackage before installation.\n"
                "No distribution certificate or provisioning profile is included.\n", encoding="utf-8")
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", str(staging), str(destination.resolve())], check=True)
        verify_ipa(destination)
    print(f"Verified and packaged Apple app: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "ios"))
    parser.add_argument("--arch", choices=("x86_64", "arm64"), required=True)
    args = parser.parse_args()
    base = Path("build/macos/Build/Products/Release" if args.platform == "macos" else "build/ios/iphoneos")
    apps = list(base.glob("*.app"))
    if len(apps) != 1:
        raise ValueError(f"Expected exactly one application in {base}")
    suffix = "x64" if args.arch == "x86_64" else "arm64"
    name = f"Segmeris-macos-{suffix}.zip" if args.platform == "macos" else "Segmeris-ios-arm64-unsigned.ipa"
    package(apps[0], args.platform, args.arch, Path("dist") / args.platform / name)


if __name__ == "__main__":
    main()

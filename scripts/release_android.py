"""Fail-closed Android signing setup and independent verification of release APKs."""

import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess

from release import versions

SECRET_NAMES = ("ANDROID_KEYSTORE_BASE64", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD", "ANDROID_STORE_PASSWORD")


def java_property(value):
    """Escape for java.util.Properties.load(InputStream), which reads ISO-8859-1."""
    result = []
    for char in value:
        if char in "\\ :=#!":
            result.append("\\" + char)
        elif char in "\t\n\r\f":
            result.append({"\t": r"\t", "\n": r"\n", "\r": r"\r", "\f": r"\f"}[char])
        elif ord(char) < 32 or ord(char) > 126:
            units = char.encode("utf-16-be")
            result.extend(f"\\u{int.from_bytes(units[i:i+2], 'big'):04x}" for i in range(0, len(units), 2))
        else:
            result.append(char)
    return "".join(result)


def configure(root, env):
    missing = [name for name in SECRET_NAMES if not env.get(name, "").strip()]
    if missing:
        raise ValueError("All Android signing secrets are required; missing: " + ", ".join(missing))
    try:
        keystore = base64.b64decode("".join(env["ANDROID_KEYSTORE_BASE64"].split()), validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("ANDROID_KEYSTORE_BASE64 is not valid base64") from error
    if not keystore:
        raise ValueError("Decoded Android keystore is empty")
    android = root / "android"
    properties = {
        "storeFile": "app/release.jks",
        "storePassword": env["ANDROID_STORE_PASSWORD"],
        "keyAlias": env["ANDROID_KEY_ALIAS"],
        "keyPassword": env["ANDROID_KEY_PASSWORD"],
    }
    path = android / "app/release.jks"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(keystore)
    path.chmod(0o600)
    path = android / "key.properties"
    path.write_text("".join(f"{key}={java_property(value)}\n" for key, value in properties.items()),
                    encoding="ascii", newline="\n")
    path.chmod(0o600)


def build_tools(sdk):
    candidates = [p for p in (sdk / "build-tools").iterdir()
                  if re.fullmatch(r"\d+(\.\d+)*", p.name)]
    for path in sorted(candidates, key=lambda p: tuple(map(int, p.name.split("."))), reverse=True):
        if all((path / name).is_file() for name in ("aapt", "apksigner", "zipalign")):
            return path
    raise ValueError("No complete Android SDK build-tools installation found")


def verify_metadata(badging, version, build_number):
    package = next((line for line in badging.splitlines() if line.startswith("package:")), "")
    values = dict(re.findall(r"(\w+)='([^']*)'", package))
    for key, expected in {"name": "com.blue.segmeris", "versionName": version, "versionCode": build_number}.items():
        if values.get(key) != expected:
            raise ValueError(f"APK {key} must be {expected}, found {values.get(key)}")
    if "application-debuggable" in badging:
        raise ValueError("Release APK is debuggable")


def verify_signer(output, expected):
    fingerprints = re.findall(r"Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)", output)
    normalized = {value.replace(":", "").lower() for value in fingerprints}
    if normalized != {expected.lower()}:
        raise ValueError("APK signer does not match the configured release keystore certificate")
    if re.search(r"CN\s*=\s*Android Debug(?:,|$)", output, re.I | re.M):
        raise ValueError("Android debug certificates are forbidden in release artifacts")


def verify(apk, abi, root):
    tools = build_tools(Path(os.environ["ANDROID_HOME"]))
    version, build_number = versions(root)
    badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)], text=True)
    verify_metadata(badging, version, build_number)
    certificate = subprocess.check_output([
        "keytool", "-exportcert", "-keystore", str(root / "android/app/release.jks"),
        "-alias", os.environ["ANDROID_KEY_ALIAS"], "-storepass:env", "ANDROID_STORE_PASSWORD",
    ])
    signed = subprocess.check_output([
        str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)
    ], text=True)
    verify_signer(signed, hashlib.sha256(certificate).hexdigest())
    subprocess.run([str(tools / "zipalign"), "-c", "-P", "16", "4", str(apk)], check=True)
    import sys
    subprocess.run([sys.executable, str(root / "scripts/check_android_apk.py"), str(apk), abi], check=True)
    print(f"Verified package/version, release certificate, native libraries and alignment: {apk.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure", "verify", "clean"))
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--abi", choices=("arm64-v8a", "armeabi-v7a", "x86_64"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.command == "configure":
        configure(root, os.environ)
    elif args.command == "clean":
        for name in ("android/key.properties", "android/app/release.jks"):
            (root / name).unlink(missing_ok=True)
    else:
        if not args.apk or not args.abi:
            parser.error("verify requires --apk and --abi")
        verify(args.apk, args.abi, root)


if __name__ == "__main__":
    main()

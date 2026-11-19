"""Release planning, strict job gating, asset manifests and draft-first publication.

Only Python's standard library is required. Publication requires GH_TOKEN and an
existing immutable vMAJOR.MINOR.PATCH tag; local validation never publishes.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tomllib
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TAG_RE = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
BASE_ASSETS = (
    "Segmeris-windows-x64.zip",
    "Segmeris-windows-x64-setup.exe",
    "Segmeris-linux-x64.tar.gz",
    "Segmeris-macos-x64.zip",
    "Segmeris-macos-arm64.zip",
    "Segmeris-android-arm64-v8a.apk",
    "Segmeris-android-armeabi-v7a.apk",
    "Segmeris-android-x86_64.apk",
    "Segmeris-web-js.zip",
    "Segmeris-web-wasm.zip",
)
IOS_ASSET = "Segmeris-ios-arm64-unsigned.ipa"
REQUIRED_JOBS = (
    "prepare", "validate", "security-scan", "build-android", "build-windows",
    "build-linux", "build-macos", "build-web", "docker-validate",
)


def versions(root=ROOT):
    text = (root / "pubspec.yaml").read_text(encoding="utf-8-sig")
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+([1-9]\d*)\s*$", text, re.M)
    if not match or not TAG_RE.fullmatch("v" + match[1]):
        raise ValueError("pubspec.yaml must contain a stable SemVer and positive build number")
    cargo = tomllib.loads((root / "rust/Cargo.toml").read_text(encoding="utf-8-sig"))
    if cargo["package"]["version"] != match[1]:
        raise ValueError("Cargo and pubspec versions differ")
    return match[1], match[2]


def make_plan(event, ref, manual_tag, skip_ios, skip_docker, root=ROOT):
    version, build_number = versions(root)
    tag = manual_tag if event == "workflow_dispatch" else ""
    if event == "push" and ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
    if tag and (not TAG_RE.fullmatch(tag) or tag != "v" + version):
        raise ValueError(f"Release tag must be v{version}; received {tag!r}")
    apps = bool(tag) or event == "workflow_dispatch" or ref == "refs/heads/testchain"
    return {
        "tag": tag, "version": version, "build_number": build_number,
        "publish": bool(tag), "build_apps": apps,
        "build_windows": apps or event == "pull_request",
        "ios_enabled": apps and not (event == "workflow_dispatch" and skip_ios),
        "docker_enabled": not (event == "workflow_dispatch" and skip_docker),
    }


def verify_tag(tag, commit, remote="https://github.com/blueokanna/Segmeris.git", *, allow_missing=False):
    if not TAG_RE.fullmatch(tag) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid release tag or commit")
    ref = f"refs/tags/{tag}"
    try:
        output = subprocess.check_output(
            ["git", "ls-remote", "--exit-code", remote, ref, ref + "^{}"], text=True
        )
    except subprocess.CalledProcessError as error:
        if error.returncode != 2:
            raise
        if allow_missing:
            return False
        raise ValueError(f"Remote tag {tag} does not exist on {remote}") from None
    refs = dict(line.split()[::-1] for line in output.splitlines())
    actual = refs.get(ref + "^{}", refs.get(ref))
    if actual != commit:
        raise ValueError(f"Remote tag {tag} points to {actual}, expected {commit}; refusing publication")
    return True


def check_gate(needs, ios_enabled, docker_enabled=None):
    expected = {job: "success" for job in REQUIRED_JOBS}
    expected["build-ios"] = "success" if ios_enabled else "skipped"
    if docker_enabled is not None:
        expected["docker-api"] = "success" if docker_enabled else "skipped"
    bad = {job: f"{needs.get(job, {}).get('result', 'missing')} (expected {result})"
           for job, result in expected.items() if needs.get(job, {}).get("result") != result}
    if bad:
        raise ValueError("Release gate rejected jobs: " + json.dumps(bad, sort_keys=True))


def asset_names(ios_enabled):
    return sorted((*BASE_ASSETS, *((IOS_ASSET,) if ios_enabled else ())))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stage_assets(source, destination, ios_enabled, tag, docker_enabled, repository):
    version, build_number = versions()
    if tag != f"v{version}":
        raise ValueError("Release assets must match the checked-out application version")
    expected = asset_names(ios_enabled)
    found = {}
    for path in source.rglob("*"):
        if not path.is_file():
            continue
        if path.is_symlink() or path.name not in expected or path.name in found:
            raise ValueError(f"Unexpected, symbolic, or duplicate release asset: {path}")
        if not path.stat().st_size:
            raise ValueError(f"Empty release asset: {path}")
        found[path.name] = path
    if set(found) != set(expected):
        raise ValueError(f"Missing release assets: {sorted(set(expected) - set(found))}")
    destination.mkdir(parents=True, exist_ok=True)
    if list(destination.iterdir()):
        raise ValueError("Release staging directory must be empty")
    for name in expected:
        shutil.copy2(found[name], destination / name)
    manifest = {
        "schema_version": 1,
        "tag": tag,
        "version": version,
        "build_number": int(build_number),
        "repository": repository,
        "assets": [{"name": name, "size": (destination / name).stat().st_size,
                    "sha256": digest(destination / name)} for name in expected],
        "android_release_signed": True,
        "apple_distribution_signed": False,
    }
    (destination / "release-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    checksummed = sorted([*expected, "release-manifest.json"])
    sums = "".join(f"{digest(destination / name)}  {name}\n" for name in checksummed)
    (destination / "SHA256SUMS").write_text(sums, encoding="utf-8", newline="\n")
    image = f"ghcr.io/{repository.split('/')[0].lower()}/segmeris-api:{tag}"
    notes = [
        '<!-- segmeris-release ' + json.dumps({"version": version, "build_number": int(build_number)}, separators=(",", ":")) + ' -->',
        "Windows x64 includes the Flutter/Rust libraries and app-local Visual C++ runtime.",
        "The Windows runtime/ folder includes Microsoft's signed WebView2 Evergreen bootstrapper; "
        "run it if WebView2 is absent (internet access required). See README-runtime.txt in the zip.",
        "Linux x64 targets Ubuntu 22.04 or newer compatible distributions (glibc >= 2.35). "
        "Flutter/Rust and non-system shared libraries are bundled; see README-runtime.txt and "
        "SYSTEM-DEPENDENCIES.txt in the tarball for required system packages.",
        "macOS applications are not Developer ID signed or notarized.",
        "Web builds are published as Segmeris-web-js.zip and Segmeris-web-wasm.zip. Serve their "
        "contents over HTTP(S); the browser application uses the configured API backend, not native Rust FFI.",
        "Windows and Linux include FFmpeg and ffprobe in tools/. macOS uses an external FFmpeg installation. "
        "Desktop features using yt-dlp require it separately. The Docker API image includes FFmpeg.",
        (f"iOS: {IOS_ASSET} is an unsigned Payload/*.app archive. It cannot be installed directly; "
         "Apple signing and a matching provisioning profile are required before installation."
         if ios_enabled else "iOS was explicitly skipped in this manual run."),
        (f"Docker API image: `{image}` (publication must succeed before this release is made public)."
         if docker_enabled and tag else "Docker image publication was explicitly disabled or this is a build-only run."),
        "SHA256SUMS covers every published application archive/APK and release-manifest.json. "
        "The manifest records their actual sizes, hashes, version and build number.",
    ]
    (destination / "RELEASE_NOTES.md").write_text("\n\n".join(notes) + "\n", encoding="utf-8")
    return expected


def validate_staged(directory, ios_enabled):
    names = asset_names(ios_enabled)
    actual = {path.name for path in directory.iterdir()}
    if actual != set(names) | {"SHA256SUMS", "RELEASE_NOTES.md", "release-manifest.json"}:
        raise ValueError("Staged release contains missing or unexpected files")
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError("Staged artifacts must be non-empty regular files")
    checksummed = sorted([*names, "release-manifest.json"])
    expected = "".join(f"{digest(directory / name)}  {name}\n" for name in checksummed)
    if (directory / "SHA256SUMS").read_text(encoding="utf-8") != expected:
        raise ValueError("Staged release checksums do not match actual assets")
    manifest = json.loads((directory / "release-manifest.json").read_text(encoding="utf-8"))
    version, build_number = versions()
    expected_assets = [{"name": name, "size": (directory / name).stat().st_size,
                        "sha256": digest(directory / name)} for name in names]
    if (manifest.get("schema_version") != 1 or manifest.get("version") != version
            or manifest.get("tag") != f"v{version}" or manifest.get("build_number") != int(build_number)
            or manifest.get("assets") != expected_assets):
        raise ValueError("Release manifest does not match the checked-out version and actual files")
    return checksummed + ["SHA256SUMS"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise ValueError("GitHub publication endpoints must not redirect authenticated requests")


def api(method, url, token, body=None, content_type="application/json", content_length=None):
    target = urllib.parse.urlsplit(url)
    if (target.scheme != "https" or target.hostname not in ("api.github.com", "uploads.github.com")
            or target.username is not None or target.password is not None
            or target.port not in (None, 443) or target.fragment):
        raise ValueError("Publication requests must use the official GitHub API hosts")
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    headers = {
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "Content-Type": content_type,
        "User-Agent": "Segmeris-release",
    }
    if content_length is not None:
        headers["Content-Length"] = str(content_length)
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(request, timeout=300) as response:
        payload = response.read(4 * 1024 * 1024 + 1)
        if len(payload) > 4 * 1024 * 1024:
            raise ValueError("GitHub publication response is unexpectedly large")
        return json.loads(payload)


def publish(directory, tag, commit, repository, ios_enabled):
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise ValueError("GH_TOKEN is required; no publication was attempted")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    names = validate_staged(directory, ios_enabled)
    verify_tag(tag, commit, f"https://github.com/{repository}.git")
    base = f"https://api.github.com/repos/{repository}/releases"
    try:
        api("GET", base + "/tags/" + tag, token)
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        if status != 404:
            raise
    else:
        raise ValueError("A release already exists for this tag; refusing to overwrite assets")
    # A failed upload leaves a draft for inspection, never a partly uploaded public release.
    release = api("POST", base, token, {
        "tag_name": tag, "target_commitish": commit, "name": "Segmeris " + tag,
        "draft": True, "prerelease": False, "generate_release_notes": True,
        "body": (directory / "RELEASE_NOTES.md").read_text(encoding="utf-8"),
    })
    upload_url = release["upload_url"].split("{", 1)[0]
    for name in names:
        path = directory / name
        # urllib/http.client streams file objects in bounded chunks when length is supplied.
        with path.open("rb") as source:
            uploaded = api("POST", upload_url + "?name=" + urllib.parse.quote(name), token,
                           source, "application/octet-stream", path.stat().st_size)
        if uploaded.get("state") != "uploaded" or uploaded.get("size") != path.stat().st_size:
            raise ValueError(f"GitHub upload verification failed for {name}; release remains a draft")
        if uploaded.get("digest") and uploaded["digest"] != "sha256:" + digest(path):
            raise ValueError(f"GitHub checksum mismatch for {name}; release remains a draft")
    # Detect moved/deleted tags again immediately before making the release public.
    verify_tag(tag, commit, f"https://github.com/{repository}.git")
    result = api("PATCH", base + "/" + str(release["id"]), token, {"draft": False})
    if result.get("draft") is not False:
        raise ValueError("GitHub did not confirm publication")
    print(result["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan")
    sub.add_parser("gate")
    verify = sub.add_parser("verify-tag")
    verify.add_argument("--tag", required=True)
    verify.add_argument("--commit", required=True)
    for command in ("stage", "publish"):
        cmd = sub.add_parser(command)
        cmd.add_argument("--directory", type=Path, required=True)
        if command == "stage":
            cmd.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    ios = os.environ.get("IOS_ENABLED", "true") == "true"
    docker = os.environ.get("DOCKER_ENABLED", "true") == "true"
    tag = os.environ.get("RELEASE_TAG", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "blueokanna/Segmeris")
    if args.command == "plan":
        plan = make_plan(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                         os.environ.get("MANUAL_TAG", ""),
                         os.environ.get("SKIP_IOS", "false") == "true",
                         os.environ.get("SKIP_DOCKER", "false") == "true")
        plan["commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        plan["create_tag"] = False
        if plan["tag"]:
            plan["create_tag"] = not verify_tag(
                plan["tag"], plan["commit"], f"https://github.com/{repository}.git",
                allow_missing=os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            )
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for key, value in plan.items():
                output.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
        print(json.dumps(plan, indent=2))
    elif args.command == "gate":
        check_gate(json.loads(os.environ["NEEDS_JSON"]), ios)
        print("All required builds/checks succeeded; optional skips match the plan")
    elif args.command == "verify-tag":
        verify_tag(args.tag, args.commit, f"https://github.com/{repository}.git")
    elif args.command == "stage":
        stage_assets(args.source, args.directory, ios, tag, docker, repository)
    elif args.command == "publish":
        publish(args.directory, tag, os.environ["RELEASE_COMMIT"], repository, ios)


if __name__ == "__main__":
    main()

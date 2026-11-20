"""Build pinned GPL FFmpeg/x264 tools, run real media smoke tests, and stage them.

Python standard library only. Builds are native POSIX or MSYS2 UCRT64 on Windows.
No installer/package manager runs here. See docs/releasing.md.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "scripts/media-tools.lock.json"
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
MAX_EXTRACTED_BYTES = 1024 * 1024 * 1024
FFMPEG_FLAGS = (
    "--disable-autodetect", "--disable-shared", "--enable-static",
    "--enable-gpl", "--enable-libx264", "--disable-doc", "--disable-debug",
    "--disable-ffplay", "--disable-network", "--enable-avdevice",
    "--enable-indev=lavfi", "--disable-outdevs", "--pkg-config-flags=--static",
)
X264_FLAGS = ("--enable-static", "--enable-pic", "--disable-cli", "--disable-opencl")


class MediaToolsError(RuntimeError):
    """A failed prerequisite, security check, build, or real media operation."""


def sha256(path):
    # Ubuntu 22.04 supplies Python 3.10.
    with Path(path).open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def verify_hash(path, expected):
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or sha256(path) != expected:
        raise MediaToolsError(f"SHA-256 mismatch: {path}")


def trusted_source_url(value, project):
    uri = urlparse(value)
    expected_host = "ffmpeg.org" if project == "ffmpeg" else "codeload.github.com"
    if project == "x264" and not re.fullmatch(r"/mirror/x264/tar\.gz/[a-f0-9]{40}", uri.path):
        raise MediaToolsError("Expected a commit archive from mirror/x264")
    if (uri.scheme != "https" or uri.hostname != expected_host or uri.port not in (None, 443)
            or uri.username or uri.password or uri.query or uri.fragment
            or "\\" in value or not uri.path.startswith("/")):
        raise MediaToolsError(f"Source URL is outside the pinned official {project} host")
    return value


def load_lock(path):
    lock = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if lock.get("schema_version") != 1 or set(lock.get("sources", {})) != {"ffmpeg", "x264"}:
        raise MediaToolsError("Unsupported media source lock schema")
    for name, source in lock["sources"].items():
        if not re.fullmatch(r"[0-9a-f]{64}", source.get("sha256", "")):
            raise MediaToolsError(f"Missing pinned {name} SHA-256")
        trusted_source_url(source["url"], name)
        if not re.fullmatch(r"[A-Za-z0-9._-]+", source.get("version", "")):
            raise MediaToolsError(f"Invalid {name} version")
    ffmpeg = lock["sources"]["ffmpeg"]
    trusted_source_url(ffmpeg["signature_url"], "ffmpeg")
    trusted_source_url(ffmpeg["signing_key_url"], "ffmpeg")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", ffmpeg.get("signing_key_fingerprint", "")):
        raise MediaToolsError("Missing pinned FFmpeg signing key fingerprint")
    return lock


class OfficialRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        project = "ffmpeg" if urlparse(request.full_url).hostname == "ffmpeg.org" else "x264"
        trusted_source_url(newurl, project)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download(url, directory, project, expected_hash=None):
    trusted_source_url(url, project)
    name = PurePosixPath(urlparse(url).path).name
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name in (".", ".."):
        raise MediaToolsError("Invalid upstream archive filename")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    if destination.is_symlink() or (hasattr(destination, "is_junction") and destination.is_junction()):
        raise MediaToolsError("Refusing a linked download destination")
    if destination.exists():
        if not destination.is_file() or destination.stat().st_size > MAX_ARCHIVE_BYTES:
            raise MediaToolsError("Invalid existing download")
        if expected_hash:
            verify_hash(destination, expected_hash)
        return destination
    opener = urllib.request.build_opener(OfficialRedirectHandler())
    request = urllib.request.Request(url, headers={"User-Agent": "Segmeris-media-build"})
    partial = directory / (name + ".part")
    # Exclusive creation prevents clobbering a previous/in-progress download.
    with partial.open("xb") as output:
        try:
            with opener.open(request, timeout=45) as response:
                size = 0
                while chunk := response.read(1024 * 128):
                    size += len(chunk)
                    if size > MAX_ARCHIVE_BYTES:
                        raise MediaToolsError("Source download exceeds the size limit")
                    output.write(chunk)
        except BaseException:
            output.close()
            partial.unlink(missing_ok=True)
            raise
    try:
        if expected_hash:
            verify_hash(partial, expected_hash)
        partial.rename(destination)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    return destination


def safe_extract(archive_path, destination):
    """Extract only ordinary files/directories; reject every link/special entry."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise MediaToolsError("Extraction destination must not already exist")
    entries = []
    seen = set()
    roots = set()
    total = 0
    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive.getmembers():
            raw = member.name
            path = PurePosixPath(raw)
            if (not raw or raw.startswith("/") or "\\" in raw or ":" in raw
                    or "\x00" in raw or ".." in path.parts or not path.parts
                    or any(part in ("", ".") for part in raw.rstrip("/").split("/"))):
                raise MediaToolsError(f"Unsafe archive path: {raw!r}")
            if not member.isdir() and not member.isfile():
                raise MediaToolsError(f"Archive links and special files are forbidden: {raw}")
            # Also reject case aliases, which otherwise collide on Windows/macOS.
            canonical = str(path).casefold()
            if canonical in seen:
                raise MediaToolsError(f"Duplicate/aliased archive entry: {raw}")
            seen.add(canonical)
            roots.add(path.parts[0])
            total += member.size
            if total > MAX_EXTRACTED_BYTES or len(entries) >= 100000:
                raise MediaToolsError("Source archive exceeds extraction limits")
            entries.append((member, path))
        if len(roots) != 1:
            raise MediaToolsError("Expected exactly one source root directory")
        destination.mkdir(parents=True)
        for member, path in entries:
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise MediaToolsError(f"Cannot read archive member: {member.name}")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                # Preserve only normal permission bits; never setuid/setgid.
                target.chmod(member.mode & 0o777)
    root = destination / next(iter(roots))
    if not (root / "configure").is_file():
        raise MediaToolsError("Source archive is missing its configure script")
    return root


def run(args, *, cwd=None, env=None, capture=False, timeout=None):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env,
                            capture_output=capture, text=True, timeout=timeout, check=False)
    if result.returncode:
        detail = (result.stderr or "")[-5000:] if capture else "See compiler output above."
        raise MediaToolsError(f"Command failed ({result.returncode}): {shlex.join(map(str, args))}\n{detail}")
    return result.stdout if capture else ""


def verify_signature(archive, signature, public_key, fingerprint, work):
    gpg = shutil.which("gpg")
    if not gpg:
        raise MediaToolsError("gpg is required to verify the official FFmpeg signature")
    fingerprint = fingerprint.upper()
    with tempfile.TemporaryDirectory(prefix="segmeris-gpg-", dir=work) as keyring:
        Path(keyring).chmod(0o700)
        windows = os.name == "nt"
        common = [gpg, "--batch", "--no-tty", "--homedir", shell_path(keyring, windows),
                  "--no-auto-key-retrieve", "--no-auto-key-import"]
        run([*common, "--import", shell_path(public_key, windows)], capture=True, timeout=30)
        status = run([*common, "--status-fd", "1", "--verify", shell_path(signature, windows),
                      shell_path(archive, windows)], capture=True, timeout=30)
        signatures = [line.split()[2:] for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
        if not any(fields and (fields[0].upper() == fingerprint or fields[-1].upper() == fingerprint)
                   for fields in signatures):
            raise MediaToolsError("FFmpeg signature did not validate against the pinned primary signing key")
    return fingerprint


def separate_paths(left, right):
    left, right = Path(left).resolve(), Path(right).resolve()
    if left == right or left in right.parents or right in left.parents:
        raise MediaToolsError("Source/work/destination paths must be disjoint, not aliases or nested paths")
    return left, right


def require_fresh(path):
    path = Path(path)
    if path.exists() or path.is_symlink():
        raise MediaToolsError(f"Refusing to overwrite existing output: {path}")


def build_environment():
    windows = os.name == "nt"
    if windows and os.environ.get("MSYSTEM") != "UCRT64":
        raise MediaToolsError("Windows source builds require the MSYS2 UCRT64 shell (not WSL/Git Bash)")
    required = ["bash", "make", "nasm", "pkg-config", "gpg"]
    compiler = "gcc" if windows else "cc"
    required.append(compiler)
    if windows:
        required.extend(["cygpath", "objdump"])
    missing = [program for program in required if shutil.which(program) is None]
    if missing:
        raise MediaToolsError("Missing source build prerequisites: " + ", ".join(missing))
    return windows, compiler, shutil.which("bash")


def shell_path(path, windows):
    if windows:
        return run(["cygpath", "-u", str(Path(path).resolve())], capture=True, timeout=10).strip()
    return str(Path(path).resolve())


def configure_commands(x264_prefix, ffmpeg_prefix, windows, compiler):
    x264 = ["./configure", "--prefix=" + x264_prefix, *X264_FLAGS]
    ffmpeg = ["./configure", "--prefix=" + ffmpeg_prefix, "--cc=" + compiler, *FFMPEG_FLAGS]
    if windows:
        ffmpeg.extend(["--target-os=mingw32", "--extra-ldflags=-static -static-libgcc -static-libstdc++"])
    return x264, ffmpeg


def verify_cpu_configuration(configuration):
    flags = set(shlex.split(configuration.replace("configuration:", "", 1)))
    if "--enable-libx264" not in flags or "--enable-gpl" not in flags:
        raise MediaToolsError("The FFmpeg build must include the GPL CPU libx264 encoder")
    if "--disable-encoder=libx264" in flags:
        raise MediaToolsError("FFmpeg's required libx264 encoder was disabled")


def tool_paths(tools):
    tools = Path(tools).resolve()
    suffix = ".exe" if os.name == "nt" else ""
    result = tuple(tools / (name + suffix) for name in ("ffmpeg", "ffprobe"))
    if any(not path.is_file() for path in result):
        raise MediaToolsError(f"Both ffmpeg{suffix} and ffprobe{suffix} are required in {tools}")
    return result


def probe_media(ffprobe, path):
    data = json.loads(run([ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name:format=duration",
                           "-of", "json", path], capture=True, timeout=30))
    streams = {(item.get("codec_type"), item.get("codec_name")) for item in data.get("streams", [])}
    duration = float(data.get("format", {}).get("duration", 0))
    if not {("video", "h264"), ("audio", "aac")}.issubset(streams) or not 0.9 <= duration <= 2.0:
        raise MediaToolsError(f"Smoke output is missing H.264/AAC streams or has invalid duration: {data}")
    return data


def verify_tools(tools):
    """Actually encode, mux, probe and decode; never substitute capability strings."""
    ffmpeg, ffprobe = tool_paths(tools)
    ffmpeg_version = run([ffmpeg, "-version"], capture=True, timeout=30)
    ffprobe_version = run([ffprobe, "-version"], capture=True, timeout=30)
    configuration = next((line for line in ffmpeg_version.splitlines() if line.startswith("configuration:")), "")
    verify_cpu_configuration(configuration)
    report = {"ffmpeg_version": ffmpeg_version.splitlines()[0],
              "ffprobe_version": ffprobe_version.splitlines()[0], "configuration": configuration}
    with tempfile.TemporaryDirectory(prefix="segmeris-media-smoke-") as temporary:
        work = Path(temporary)
        common = [ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-xerror"]
        run([*common, "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=24", "-t", "1.25", "-an",
             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "12",
             "-keyint_min", "12", "-sc_threshold", "0", "-threads", "1", "video.mp4"], cwd=work, timeout=60)
        run([*common, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1.25",
             "-vn", "-c:a", "aac", "-b:a", "96k", "audio.m4a"], cwd=work, timeout=60)
        # Bilibili-style separate video and audio tracks: merge without re-encoding.
        run([*common, "-i", "video.mp4", "-i", "audio.m4a", "-map", "0:v:0", "-map", "1:a:0",
             "-c", "copy", "-movflags", "+faststart", "-shortest", "merged.mp4"], cwd=work, timeout=60)
        report["dash_merge"] = probe_media(ffprobe, work / "merged.mp4")
        run([*common, "-err_detect", "explode", "-i", "merged.mp4", "-map", "0:v:0", "-map", "0:a:0",
             "-f", "null", "-"], cwd=work, timeout=60)
        run([*common, "-i", "merged.mp4", "-map", "0:v:0", "-map", "0:a:0", "-c", "copy",
             "-hls_time", "0.4", "-hls_playlist_type", "vod", "-hls_segment_filename", "segment-%03d.ts",
             "playlist.m3u8"], cwd=work, timeout=60)
        segments = list(work.glob("segment-*.ts"))
        if len(segments) < 2 or any(path.stat().st_size == 0 for path in segments):
            raise MediaToolsError("HLS smoke test did not create multiple non-empty media segments")
        run([*common, "-protocol_whitelist", "file,crypto,data", "-i", "playlist.m3u8", "-map", "0:v:0",
             "-map", "0:a:0", "-c", "copy", "-movflags", "+faststart", "roundtrip.mp4"], cwd=work, timeout=60)
        report["hls_roundtrip"] = probe_media(ffprobe, work / "roundtrip.mp4")
        report["hls_segment_count"] = len(segments)
        run([*common, "-err_detect", "explode", "-i", "roundtrip.mp4", "-map", "0:v:0", "-map", "0:a:0",
             "-f", "null", "-"], cwd=work, timeout=60)
    report["executable_sha256"] = {path.name: sha256(path) for path in (ffmpeg, ffprobe)}
    return report


def verify_native_dependencies(tools):
    binaries = tool_paths(tools)
    report = {}
    for binary in binaries:
        if os.name == "nt":
            output = run(["objdump", "-p", binary], capture=True, timeout=30)
            dlls = re.findall(r"DLL Name:\s*(\S+)", output, re.I)
            system = {"kernel32.dll", "msvcrt.dll", "ucrtbase.dll", "advapi32.dll", "user32.dll", "ole32.dll",
                      "oleaut32.dll", "shell32.dll", "gdi32.dll", "ws2_32.dll", "bcrypt.dll", "crypt32.dll",
                      "secur32.dll", "ntdll.dll", "imm32.dll", "comdlg32.dll", "version.dll", "winmm.dll",
                      "mfplat.dll", "evr.dll", "dxva2.dll", "d3d11.dll", "d3d9.dll", "opengl32.dll",
                      "winspool.drv", "wldap32.dll", "powrprof.dll", "avicap32.dll", "avrt.dll", "rpcrt4.dll",
                      "psapi.dll", "shlwapi.dll", "ksuser.dll", "vfw32.dll"}
            unexpected = [name for name in dlls if name.lower() not in system and not name.lower().startswith(("api-ms-win-", "ext-ms-win-"))]
            if not dlls or unexpected:
                raise MediaToolsError(f"Windows tool has unbundled/non-system DLL imports: {unexpected or 'no import table'}")
            report[binary.name] = dlls
        elif platform.system() == "Darwin":
            output = run(["otool", "-L", binary], capture=True, timeout=30)
            dependencies = [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]]
            if any(not dependency.startswith(("/usr/lib/", "/System/Library/")) for dependency in dependencies):
                raise MediaToolsError(f"macOS tool has non-system shared-library imports: {dependencies}")
            report[binary.name] = dependencies
        else:
            output = run(["ldd", binary], capture=True, timeout=30)
            if "not found" in output or re.search(r"lib(?:x264|avcodec|avformat|avutil|swscale|swresample|avfilter|avdevice)\S*\.so", output):
                raise MediaToolsError("Linux tools must include x264/FFmpeg libraries statically and resolve system libraries")
            report[binary.name] = output.splitlines()
    return report


def file_inventory(directory):
    entries = {}
    for path in sorted(Path(directory).rglob("*")):
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise MediaToolsError(f"Linked files cannot be distributed: {path}")
        if path.is_file() and path.name != "media-tools-manifest.json":
            relative = path.relative_to(directory).as_posix()
            entries[relative] = {"sha256": sha256(path), "size": path.stat().st_size}
    return entries


def validate_bundle(prefix):
    prefix = Path(prefix)
    manifest_path = prefix / "media-tools-manifest.json"
    if not manifest_path.is_file():
        raise MediaToolsError("Source-built media-tools-manifest.json is required for staging")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or manifest.get("files") != file_inventory(prefix):
        raise MediaToolsError("Media bundle file set or SHA-256 inventory differs from its build manifest")
    required = {"sources/media-tools.lock.json", "build-recipe.json", "licenses/FFmpeg-COPYING.GPLv2", "licenses/x264-COPYING"}
    if not required.issubset(manifest["files"]):
        raise MediaToolsError("Source bundle/license/build recipe is incomplete")
    lock = load_lock(prefix / "sources/media-tools.lock.json")
    for source in lock["sources"].values():
        archive = prefix / "sources" / PurePosixPath(urlparse(source["url"]).path).name
        if not archive.is_file():
            raise MediaToolsError("Complete corresponding source archives must accompany the tools")
        verify_hash(archive, source["sha256"])
    verify_cpu_configuration(manifest.get("verification", {}).get("configuration", ""))
    tool_paths(prefix)
    return manifest


def build(prefix, work, lock_path=DEFAULT_LOCK, jobs=None):
    prefix, work = separate_paths(prefix, work)
    require_fresh(prefix)
    lock_path = Path(lock_path).resolve()
    lock = load_lock(lock_path)
    windows, compiler, bash = build_environment()
    work.mkdir(parents=True, exist_ok=True)
    # Reusing pinned download bytes is safe; source/build/install trees are never overwritten.
    for name in ("x264-source", "ffmpeg-source", "x264-install", "ffmpeg-install"):
        require_fresh(work / name)
    archives = {}
    for name, source in lock["sources"].items():
        archives[name] = download(source["url"], work / "downloads", name, source["sha256"])
    ffmpeg_lock = lock["sources"]["ffmpeg"]
    signature = download(ffmpeg_lock["signature_url"], work / "downloads", "ffmpeg")
    public_key = download(ffmpeg_lock["signing_key_url"], work / "downloads", "ffmpeg")
    fingerprint = verify_signature(archives["ffmpeg"], signature, public_key, ffmpeg_lock["signing_key_fingerprint"], work)
    sources = {name: safe_extract(path, work / (name + "-source")) for name, path in archives.items()}
    x264_prefix = work / "x264-install"
    ffmpeg_prefix = work / "ffmpeg-install"
    x264_command, ffmpeg_command = configure_commands(shell_path(x264_prefix, windows), shell_path(ffmpeg_prefix, windows), windows, compiler)
    environment = os.environ.copy()
    # Prevent ambient flags from changing the source/build recipe silently.
    for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR"):
        environment.pop(key, None)
    environment["CC"] = compiler
    environment["PKG_CONFIG_PATH"] = shell_path(x264_prefix / "lib/pkgconfig", windows)
    if windows:
        environment["LDFLAGS"] = "-static -static-libgcc -static-libstdc++"
    parallelism = jobs or min(os.cpu_count() or 2, 8)
    if parallelism < 1:
        raise MediaToolsError("Build job count must be positive")
    recipe = {"schema_version": 1, "sources": lock["sources"], "host": platform.platform(),
              "machine": platform.machine(), "compiler": run([compiler, "--version"], capture=True, timeout=30),
              "compiler_target": run([compiler, "-dumpmachine"], capture=True, timeout=30).strip(),
              "source_signature_primary_fingerprint": fingerprint, "commands": [],
              "environment": {"CC": compiler, "PKG_CONFIG_PATH": environment["PKG_CONFIG_PATH"], "LDFLAGS": environment.get("LDFLAGS", "")}}
    for project, configure in (("x264", x264_command), ("ffmpeg", ffmpeg_command)):
        for command in (configure, ["make", f"-j{parallelism}"], ["make", "install"]):
            recipe["commands"].append({"project": project, "cwd": str(sources[project]), "argv": command})
            # Pass every value as an argv entry; never interpolate paths into shell code.
            run([bash, "--noprofile", "--norc", "-c", 'exec "$@"', "segmeris-build", *command], cwd=sources[project], env=environment)
    installed = ffmpeg_prefix / "bin"
    dependencies = verify_native_dependencies(installed)
    smoke = verify_tools(installed)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".segmeris-media-build-", dir=prefix.parent) as temporary:
        bundle = Path(temporary) / "bundle"
        bundle.mkdir()
        for executable in tool_paths(installed):
            shutil.copy2(executable, bundle / executable.name)
        (bundle / "sources").mkdir()
        (bundle / "licenses").mkdir()
        for archive in archives.values():
            shutil.copy2(archive, bundle / "sources" / archive.name)
        for artifact in (signature, public_key):
            shutil.copy2(artifact, bundle / "sources" / artifact.name)
        shutil.copy2(lock_path, bundle / "sources/media-tools.lock.json")
        shutil.copy2(Path(__file__), bundle / "sources/bundle_ffmpeg.py")
        shutil.copy2(sources["ffmpeg"] / "COPYING.GPLv2", bundle / "licenses/FFmpeg-COPYING.GPLv2")
        shutil.copy2(sources["x264"] / "COPYING", bundle / "licenses/x264-COPYING")
        license_text = next((sources["ffmpeg"] / name for name in ("LICENSE.md", "LICENSE") if (sources["ffmpeg"] / name).is_file()), None)
        if license_text is None:
            raise MediaToolsError("FFmpeg source license notice is missing")
        shutil.copy2(license_text, bundle / "licenses" / ("FFmpeg-" + license_text.name))
        (bundle / "build-recipe.json").write_text(json.dumps(recipe, indent=2) + "\n", encoding="utf-8")
        manifest = {"schema_version": 1, "built_at": datetime.now(timezone.utc).isoformat(), "platform": platform.system(),
                    "architecture": recipe["compiler_target"], "sources": lock["sources"],
                    "verification": smoke, "native_dependencies": dependencies, "files": file_inventory(bundle)}
        (bundle / "media-tools-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        validate_bundle(bundle)
        require_fresh(prefix)
        bundle.rename(prefix)
    print(f"Built and smoke-tested FFmpeg/ffprobe with pinned x264: {prefix}")
    return manifest


def stage(prefix, destination):
    prefix, destination = separate_paths(prefix, destination)
    require_fresh(destination)
    validate_bundle(prefix)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".segmeris-media-stage-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "tools"
        shutil.copytree(prefix, staged, symlinks=False)
        validate_bundle(staged)
        smoke = verify_tools(staged)
        require_fresh(destination)
        staged.rename(destination)
    print(f"Staged complete source/license bundle and verified DASH/HLS media operations: {destination}")
    return smoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("--prefix", type=Path, required=True)
    builder.add_argument("--work", type=Path, required=True)
    builder.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    builder.add_argument("--jobs", type=int)
    verifier = commands.add_parser("verify")
    verifier.add_argument("--tools", type=Path, required=True)
    stager = commands.add_parser("stage")
    stager.add_argument("--prefix", type=Path, required=True)
    stager.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(args.prefix, args.work, args.lock, args.jobs)
        elif args.command == "verify":
            if (args.tools / "media-tools-manifest.json").exists():
                validate_bundle(args.tools)
            print(json.dumps(verify_tools(args.tools), indent=2))
        else:
            stage(args.prefix, args.destination)
    except (MediaToolsError, OSError, ValueError, tarfile.TarError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Media tools verification/build failed: {error}\n")


if __name__ == "__main__":
    main()

"""Check a Linux bundle, collect non-system dependencies, and package a tarball."""

import argparse
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile

SYSTEM_ROOTS = ("/lib/", "/lib64/", "/usr/lib/", "/usr/lib64/")


def elf_x64(path):
    with path.open("rb") as source:
        header = source.read(64)
    if (len(header) < 64 or header[:6] != b"\x7fELF\x02\x01"
            or struct.unpack_from("<H", header, 18)[0] != 62):
        raise ValueError(f"Expected an x86_64 ELF binary: {path}")


def parse_ldd(output):
    if "not found" in output:
        raise ValueError("Unresolved ELF dependency: " + output)
    dependencies = []
    for line in output.splitlines():
        match = re.match(r"\s*(\S+)\s+=>\s+(/\S+)\s+\(", line)
        if match:
            dependencies.append((match[1], Path(match[2])))
        else:
            match = re.match(r"\s*(/\S+)\s+\(", line)
            if match:
                dependencies.append((Path(match[1]).name, Path(match[1])))
    return dependencies


def package(bundle, destination):
    bundle = bundle.resolve()
    required = ("segmeris", "lib/libflutter_linux_gtk.so", "lib/librust_lib_segmeris.so",
                "lib/libapp.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin")
    for name in required:
        if not (bundle / name).is_file():
            raise ValueError(f"Missing bundled runtime: {name}")
    env = dict(os.environ, LD_LIBRARY_PATH=str(bundle / "lib"))
    pending = [bundle / "segmeris", *bundle.rglob("*.so"), *bundle.rglob("*.so.*")]
    inspected = set()
    systems = set()
    while pending:
        binary = pending.pop()
        if binary.resolve() in inspected:
            continue
        inspected.add(binary.resolve())
        elf_x64(binary)
        output = subprocess.check_output(["ldd", str(binary)], env=env, text=True)
        for soname, path in parse_ldd(output):
            resolved = path.resolve()
            if resolved.is_relative_to(bundle):
                continue
            if str(resolved).startswith(SYSTEM_ROOTS):
                systems.add(path)
                continue
            target = bundle / "lib" / soname
            if target.exists() and target.read_bytes() != resolved.read_bytes():
                raise ValueError(f"Conflicting shared libraries: {target}, {resolved}")
            if not target.exists():
                shutil.copy2(resolved, target)
            pending.append(target)
    # Every ELF in the final archive must resolve with only the bundled lib/ and system libraries.
    for binary in [bundle / "segmeris", *bundle.rglob("*.so"), *bundle.rglob("*.so.*")]:
        output = subprocess.check_output(["ldd", str(binary)], env=env, text=True)
        for _, path in parse_ldd(output):
            if not path.resolve().is_relative_to(bundle) and not str(path.resolve()).startswith(SYSTEM_ROOTS):
                raise ValueError(f"Dependency still points outside the bundle/system: {path}")
    lines = ["System ELF dependencies observed on Ubuntu 22.04 x64 (not included):"]
    packages = {"ca-certificates", "xdg-utils", "libgtk-3-0", "libsecret-1-0", "libjsoncpp25"}
    for path in sorted(systems):
        owner = subprocess.run(["dpkg-query", "-S", str(path)], text=True, capture_output=True)
        description = owner.stdout.strip() if owner.returncode == 0 else str(path)
        lines.append(description)
        if owner.returncode == 0:
            packages.update(line.rsplit(": ", 1)[0] for line in owner.stdout.splitlines())
    lines.extend(["", "Ubuntu 22.04 package installation:", "sudo apt-get install " + " ".join(sorted(packages))])
    (bundle / "SYSTEM-DEPENDENCIES.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (bundle / "README-runtime.txt").write_text(
        "Segmeris Linux x64\n\n"
        "Built on Ubuntu 22.04; requires x86_64, glibc >= 2.35, a graphical GTK3 session, "
        "system graphics drivers and a Secret Service provider (for example gnome-keyring).\n"
        "Extract the entire tarball and run ./segmeris. Keep lib/ and data/ together.\n"
        "Flutter, the Rust bridge, plugins and other non-system shared libraries are included.\n"
        "System ELF dependencies and their Ubuntu packages are in SYSTEM-DEPENDENCIES.txt.\n"
        "This is a relocatable application bundle, not a .deb or a fully static executable.\n"
        "GitHub release builds include FFmpeg and ffprobe in tools/. Install yt-dlp separately for sites that use it.\n",
        encoding="utf-8",
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(destination, "w:gz") as archive:
        for path in sorted(bundle.iterdir()):
            archive.add(path, arcname=path.name)
    print(f"Packaged Linux runtime: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("build/linux/x64/release/bundle"))
    parser.add_argument("--destination", type=Path, default=Path("dist/linux/Segmeris-linux-x64.tar.gz"))
    args = parser.parse_args()
    package(args.bundle, args.destination)


if __name__ == "__main__":
    main()

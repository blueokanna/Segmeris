"""Check ABI completeness and native ELF alignment in an architecture-specific APK."""

import argparse
import struct
from zipfile import ZipFile

MACHINES = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183), "x86_64": (2, 62)}
REQUIRED = {"libapp.so", "libflutter.so", "librust_lib_segmeris.so"}


def check_elf(name, data, abi):
    elf_class, machine = MACHINES[abi]
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4:6] != bytes((elf_class, 1)):
        raise ValueError(f"{name}: invalid ELF class or byte order")
    if struct.unpack_from("<H", data, 18)[0] != machine:
        raise ValueError(f"{name}: ELF machine does not match {abi}")
    if elf_class == 2:
        table = struct.unpack_from("<Q", data, 32)[0]
        entry_size, count = struct.unpack_from("<HH", data, 54)
        minimum_size, page_size = 56, 16384
    else:
        table = struct.unpack_from("<I", data, 28)[0]
        entry_size, count = struct.unpack_from("<HH", data, 42)
        minimum_size, page_size = 32, 4096
    if entry_size < minimum_size or table + entry_size * count > len(data):
        raise ValueError(f"{name}: invalid program header table")
    loads = 0
    for index in range(count):
        offset = table + index * entry_size
        if struct.unpack_from("<I", data, offset)[0] != 1:
            continue
        loads += 1
        if elf_class == 2:
            file_offset, address = struct.unpack_from("<QQ", data, offset + 8)
            alignment = struct.unpack_from("<Q", data, offset + 48)[0]
        else:
            file_offset, address = struct.unpack_from("<II", data, offset + 4)
            alignment = struct.unpack_from("<I", data, offset + 28)[0]
        if alignment < page_size or (address - file_offset) % page_size:
            raise ValueError(f"{name}: LOAD segment is not {page_size}-byte aligned")
    if not loads:
        raise ValueError(f"{name}: no loadable ELF segments")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk")
    parser.add_argument("abi", choices=MACHINES)
    args = parser.parse_args()
    with ZipFile(args.apk) as archive:
        libraries = [n for n in archive.namelist() if n.startswith("lib/") and n.endswith(".so")]
        abis = {name.split("/")[1] for name in libraries}
        if abis != {args.abi}:
            raise ValueError(f"Expected only {args.abi}, found {sorted(abis)}")
        missing = REQUIRED - {name.rsplit("/", 1)[1] for name in libraries}
        if missing:
            raise ValueError(f"Missing runtime libraries: {sorted(missing)}")
        for name in libraries:
            check_elf(name, archive.read(name), args.abi)
    print(f"APK native runtime verified: {args.abi}, {len(libraries)} libraries")


if __name__ == "__main__":
    main()

"""Inspect PE headers without executing any packaged binary."""
import argparse
from pathlib import Path
import struct

MACHINES = {"x64": 0x8664, "arm64": 0xAA64}


def inspect(data):
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("Not a PE image")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset > len(data) - 24 or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Invalid PE header")
    machine, sections = struct.unpack_from("<HH", data, offset + 4)
    optional_size = struct.unpack_from("<H", data, offset + 20)[0]
    optional = offset + 24
    if optional_size < 2 or optional + optional_size > len(data):
        raise ValueError("Invalid optional header")
    magic = struct.unpack_from("<H", data, optional)[0]
    directory = optional + (96 if magic == 0x10B else 112 if magic == 0x20B else optional_size)
    neutral = False
    if directory + 15 * 8 <= optional + optional_size:
        clr, size = struct.unpack_from("<II", data, directory + 14 * 8)
        table = optional + optional_size
        if table + sections * 40 > len(data):
            raise ValueError("Invalid section table")
        if machine == 0x14C and clr and size >= 20:
            for index in range(sections):
                virtual_size, address, raw_size, raw = struct.unpack_from("<IIII", data, table + index * 40 + 8)
                if address <= clr and clr - address + 20 <= raw_size:
                    location = raw + clr - address
                    if location + 20 > len(data):
                        raise ValueError("Invalid CLR header")
                    flags = struct.unpack_from("<I", data, location + 16)[0]
                    neutral = bool(flags & 1) and not bool(flags & (2 | 0x10))
                    break
    return machine, neutral


def verify(path, architecture, required_native=False):
    with path.open("rb") as stream:
        # All headers, including the CLR header, must fit this bounded read.
        machine, neutral = inspect(stream.read(4 * 1024 * 1024))
    if machine != MACHINES[architecture] and not (neutral and not required_native):
        raise ValueError("Wrong native architecture: " + path.name)


def check(root, architecture):
    native = ["CodexPacer.exe", "PacerCompositionBackdrop.dll", "Engine/PacerEngine.exe",
              "Engine/PacerWindowsBridge.dll", "Engine/PacerInstallerHooks.exe", "Maintenance/PacerMaintenance.exe",
              "Engine/Python/python.exe", "Engine/Python/python3.dll", "Engine/Python/python314.dll"]
    for name in native:
        verify(root / name, architecture, required_native=True)
    count = 0
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in (".exe", ".dll"):
            verify(path, architecture)
            count += 1
    print(f"PASS {architecture} PE headers: {count} images; no product execution")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=MACHINES)
    args = parser.parse_args()
    check(args.root, args.architecture)

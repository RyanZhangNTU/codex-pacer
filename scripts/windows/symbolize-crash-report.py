"""Names the functions in an engine crash report.

    python scripts/windows/symbolize-crash-report.py REPORT [--binaries DIR] [--cache DIR] [--offline]

A report lists its stack as module file names with offsets, and each module with
the identity of its symbol file. Microsoft's symbols are fetched from its symbol
server by that identity and kept under --cache (output/symbols by default).
Modules without usable symbols there, such as the engine and the Swift runtime,
are read from --binaries when a file of the same name, link time and size is
there: the Engine folder of the installed version, or a build of the same commit.

The LLVM tools come from the pinned Swift toolchain under output/toolchains, or
from PATH.
"""
import argparse
import bisect
import functools
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER = "https://msdl.microsoft.com/download/symbols"
FRAME = re.compile(r"^(  (?:\d+) |address: )([A-Za-z0-9._-]+)\+0x([0-9A-F]+)$")
MODULE = re.compile(r"^  ([A-Za-z0-9._-]+) time: ([0-9A-F]{8}) size: ([0-9A-F]+)(?: symbols: ([A-Za-z0-9._-]+) ([0-9A-F]{33,40}))?$")


def tool(name):
    for folder in sorted((ROOT / "output/toolchains/swift/Toolchains").glob("*/usr/bin"), reverse=True):
        if (folder / (name + ".exe")).exists():
            return str(folder / (name + ".exe"))
    found = shutil.which(name)
    if not found:
        sys.exit(name + " was not found; run scripts/windows/setup-swift.ps1 or add LLVM to PATH.")
    return found


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, errors="replace", check=False).stdout


def symbol_file(cache, name, identity, offline):
    """The local copy of a symbol file, fetched once by its identity."""
    path = cache / name / identity / name
    if path.exists() or offline:
        return path if path.exists() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    url = "/".join([SERVER, name, identity, name])
    print("fetching " + url, file=sys.stderr)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Microsoft-Symbol-Server/10.0"}), timeout=120) as reply:
            data = reply.read()
    except OSError as error:
        print("  not available: " + str(error), file=sys.stderr)
        return None
    path.write_bytes(data)
    return path


def public_symbols(path):
    """Sorted (offset in the image, name) pairs from a symbol file's public symbols."""
    text = run([tool("llvm-pdbutil"), "dump", "--section-headers", "--publics", str(path)])
    sections = [int(value, 16) for value in re.findall(r"^\s*([0-9A-Fa-f]+) virtual address$", text, re.MULTILINE)]
    symbols = []
    for name, segment, offset in re.findall(r"S_PUB32 \[size = \d+\] `([^`]*)`\s*\n\s*flags = [^,]*, addr = (\d+):(\d+)", text):
        if 1 <= int(segment) <= len(sections):
            symbols.append((sections[int(segment) - 1] + int(offset), name))
    return sorted(symbols)


@functools.lru_cache(maxsize=None)
def exported_symbols(path):
    """Sorted (offset in the image, name) pairs from a binary's own export table."""
    text = run([tool("llvm-readobj"), "--coff-exports", str(path)])
    return sorted((int(offset, 16), name) for name, offset in re.findall(r"Name: (\S+)\s*\n\s*RVA: 0x([0-9A-Fa-f]+)", text))


def nearest(symbols, lookup, offset):
    """The last symbol at or before an address, with the distance from it."""
    index = bisect.bisect_right(symbols, (lookup, "￿")) - 1 if symbols else -1
    return "%s+0x%X" % (symbols[index][1], offset - symbols[index][0]) if index >= 0 else ""


def debug_name(path, lookup):
    """The function and source line from a binary's own debug information."""
    found = run([tool("llvm-symbolizer"), "--obj=" + str(path), "--relative-address", "--demangle", hex(lookup)]).split("\n")
    if not found or not found[0] or found[0] == "??":
        return ""
    readable = run([tool("swift-demangle"), "--simplified", found[0]]).strip().split("---> ")[-1] if found[0].startswith("$s") else ""
    return (readable or found[0]) + ("  " + found[1] if len(found) > 1 and not found[1].startswith("??") else "")


def identity_of(path):
    """A loaded image's link time and size, as a report prints them."""
    data = path.read_bytes()[:4096]
    start = struct.unpack_from("<I", data, 0x3C)[0]
    return "%08X" % struct.unpack_from("<I", data, start + 8)[0], "%X" % struct.unpack_from("<I", data, start + 24 + 56)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--binaries", type=pathlib.Path, help="a folder with the engine's own files for this version")
    parser.add_argument("--cache", type=pathlib.Path, default=ROOT / "output/symbols")
    parser.add_argument("--offline", action="store_true", help="use only symbol files already in the cache")
    options = parser.parse_args()
    lines = options.report.read_text(encoding="utf-8", errors="replace").splitlines()
    modules = {match.group(1).lower(): match.groups() for match in map(MODULE.match, lines) if match}
    tables, binaries = {}, {}
    for key, (name, time, size, symbols, identity) in modules.items():
        path = symbol_file(options.cache, symbols, identity, options.offline) if symbols else None
        if path:
            tables[key] = public_symbols(path)
        # A module can name a symbol file that is not available: offline, or one no server has.
        if not tables.get(key) and options.binaries and (options.binaries / name).exists():
            if identity_of(options.binaries / name) == (time, size):
                binaries[key] = options.binaries / name
            else:
                print(name + " in --binaries is a different build than the report's.", file=sys.stderr)
    for line in lines:
        match = FRAME.match(line)
        if not match:
            print(line)
            continue
        key, offset = match.group(2).lower(), int(match.group(3), 16)
        # A caller's address is the instruction after its call; look up the call itself.
        lookup = offset if match.group(1) in ("address: ", "  0 ") else offset - 1
        named = nearest(tables.get(key), lookup, offset)
        if not named and key in binaries:
            # Without its symbol file a binary still names its exported functions.
            named = debug_name(binaries[key], lookup) or nearest(exported_symbols(binaries[key]), lookup, offset)
        print(line + ("  " + named if named else ""))


if __name__ == "__main__":
    main()

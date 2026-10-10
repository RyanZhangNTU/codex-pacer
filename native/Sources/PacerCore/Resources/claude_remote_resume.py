"""Resolve a known Claude Code installation and replace this owned launcher.

Claude Desktop 2.31226.0's bundled deployment code installs the Linux/macOS
CLI at ~/.claude/remote/ccd-cli/<version>-<12-hex manifest hash>. Its server
under remote/srv is a different binary and is never a CLI candidate here.
The single-file ccd-cli layout is retained for older Desktop installations.
All operations before exec are read-only and compatible with Python 3.6.
"""

import itertools
import os
import re
import stat
import sys
import uuid


DESKTOP_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.+_-]+)?-[0-9a-f]{12}$")
NATIVE_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.+_-]+)?$")
MAXIMUM_ENTRIES = 256
MAXIMUM_VERSIONS = 16


def executable(path):
    try:
        return stat.S_ISREG(os.stat(path).st_mode) and os.access(path, os.X_OK)
    except (OSError, ValueError):
        return False


def versioned_executables(directory, pattern):
    candidates = []
    try:
        with os.scandir(directory) as entries:
            for entry in itertools.islice(entries, MAXIMUM_ENTRIES):
                match = pattern.fullmatch(entry.name)
                if match is None or not executable(entry.path):
                    continue
                try:
                    modified = entry.stat().st_mtime
                except OSError:
                    continue
                candidates.append((tuple(int(part) for part in match.groups()), modified, entry.name, entry.path))
    except (OSError, ValueError):
        return []
    candidates.sort(reverse=True)
    return [entry[3] for entry in candidates[:MAXIMUM_VERSIONS]]


def resolve_cli(user_home=None, path=None, system_bin_directories=None):
    home = os.path.expanduser("~") if user_home is None else user_home
    # This is the exact cache used by Desktop's own SSH deployment. Probe only
    # executable versions, never daemon tokens, compressed uploads or servers.
    desktop = os.path.join(home, ".claude", "remote", "ccd-cli")
    candidates = versioned_executables(desktop, DESKTOP_VERSION)
    candidates.append(desktop)
    candidates.extend(versioned_executables(os.path.join(home, ".local", "share", "claude", "versions"), NATIVE_VERSION))
    candidates.extend(os.path.join(home, relative) for relative in (
        ".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".npm/bin/claude",
        ".volta/bin/claude", ".asdf/shims/claude", ".local/share/mise/shims/claude", ".bun/bin/claude"
    ))
    system = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin") if system_bin_directories is None else system_bin_directories
    candidates.extend(os.path.join(directory, "claude") for directory in system)
    inherited = os.environ.get("PATH", "") if path is None else path
    candidates.extend(os.path.join(directory, "claude") for directory in inherited.split(os.pathsep)[:64]
                      if os.path.isabs(directory))
    seen = set()
    for candidate in candidates:
        absolute = os.path.abspath(candidate)
        if absolute in seen:
            continue
        seen.add(absolute)
        if executable(absolute):
            return absolute
    return None


def main(arguments=None):
    values = sys.argv[1:] if arguments is None else arguments
    if len(values) != 1 or not isinstance(values[0], str) or len(values[0]) != 36:
        sys.stderr.write("Invalid Claude Code session.\n")
        return 2
    try:
        session = str(uuid.UUID(values[0]))
    except (ValueError, AttributeError):
        sys.stderr.write("Invalid Claude Code session.\n")
        return 2
    cli = resolve_cli()
    if cli is None:
        sys.stderr.write("Claude Code executable not found on this host.\n")
        return 127
    try:
        # The caller's SSH PTY remains attached. --resume opens saved context
        # and the launcher supplies no query or model instruction.
        os.execv(cli, [cli, "--resume", session])
    except OSError:
        sys.stderr.write("Could not open the Claude Code session.\n")
        return 126


if __name__ == "__main__":
    sys.exit(main())

route, home, root = checked_route(sys.argv[1])


def exact(n):
    result = b""
    while len(result) < n:
        part = os.read(0, n - len(result))
        if not part:
            raise SystemExit(2)
        result += part
    return result


digits = b""
while True:
    byte = exact(1)
    if byte == b"\n":
        break
    if not b"0" <= byte <= b"9" or len(digits) >= 7:
        raise SystemExit(2)
    digits += byte
size = int(digits)
if not 0 < size <= 1048576:
    raise SystemExit(2)
command = exact(size).decode("utf-8", errors="strict")
os.environ["HOME"] = str(home)
os.environ["CODEX_HOME"] = str(root) if route["provider"] == "codex" else str(home / ".codex")
os.environ["CLAUDE_CONFIG_DIR"] = str(root) if route["provider"] == "claude" else str(home / ".claude")
os.execv("/bin/sh", ["sh", "-c", command])

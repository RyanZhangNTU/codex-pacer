import stat
route, home, root = checked_route(sys.argv[1])
result = {}
names = ["auth.json"] if route["provider"] == "codex" else [".credentials.json", ".claude.json"]
for name in names:
    path = home / name if name == ".claude.json" and root == home / ".claude" else root / name
    try:
        # A credential snapshot is selected by exact name and never follows a
        # link or opens another application's credential store.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb", buffering=0) as stream:
            before = os.fstat(stream.fileno())
            limit = 32768 if name == ".credentials.json" else 2097152
            if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > limit:
                raise ValueError("file")
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            stamp = lambda v: [v.st_dev, v.st_ino, v.st_size, v.st_mtime_ns, v.st_ctime_ns]
            if len(data) > limit or stamp(before) != stamp(after) or stamp(after) != stamp(os.stat(path, follow_symlinks=False)):
                raise ValueError("changed")
            if name == "auth.json":
                # The read-only Codex RPC owns authentication in Linux. Only
                # its stamp crosses into the Windows quota client.
                data = b""
            elif name == ".claude.json":
                data = json.dumps({"oauthAccount": json.loads(data).get("oauthAccount")}, separators=(",", ":")).encode("utf-8")
            result[name] = dict(data=base64.b64encode(data).decode("ascii"), stamp=stamp(after))
    except FileNotFoundError:
        pass
print(json.dumps(result, separators=(",", ":")))

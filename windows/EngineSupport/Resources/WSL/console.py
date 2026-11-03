import uuid
route, home, root = checked_route(sys.argv[1])
session = sys.argv[2]
if str(uuid.UUID(session)) != session or len(session) != 36:
    raise SystemExit(2)
os.environ["HOME"] = str(home)
os.chdir(root)
if route["provider"] == "codex":
    os.environ["CODEX_HOME"] = str(root)
    os.execvp("codex", ["codex", "resume", session])
else:
    os.environ["CLAUDE_CONFIG_DIR"] = str(root)
    # The engine supplies the shared ClaudeRemoteResume resource, not a command
    # from the wire token. It resolves the source's current session mapping.
    command = base64.b64decode(sys.argv[3], validate=True).decode("utf-8")
    os.execv("/bin/sh", ["sh", "-c", command])

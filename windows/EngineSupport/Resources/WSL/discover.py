import json
import os
import pathlib
import pwd


def directory(path):
    value = pathlib.Path(path).expanduser().resolve(strict=True)
    info = value.stat()
    if not value.is_dir():
        raise ValueError("directory")
    return str(value), str(info.st_dev) + ":" + str(info.st_ino)


account = pwd.getpwuid(os.getuid())
home, identity = directory(account.pw_dir)
result = dict(distro="", user=account.pw_name, uid=os.getuid(), home=home, identity=identity)
for provider, variable in (("codex", "CODEX_HOME"), ("claude", "CLAUDE_CONFIG_DIR")):
    candidate = os.environ.get(variable) or str(pathlib.Path(home) / ("." + provider))
    try:
        path, stamp = directory(candidate)
        result[provider + "Home"] = path
        result[provider + "Identity"] = stamp
    except (OSError, ValueError):
        result[provider + "Home"] = str(pathlib.Path(home) / ("." + provider))
print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))

import base64
import json
import os
import pathlib
import pwd
import sys


def checked_route(encoded):
    route = json.loads(base64.b64decode(encoded, validate=True))
    account = pwd.getpwuid(os.getuid())
    home = pathlib.Path(account.pw_dir).resolve(strict=True)
    root = pathlib.Path(route["root"]).resolve(strict=True)
    stamp = root.stat()
    home_stamp = home.stat()
    if (route["provider"] not in ("codex", "claude") or
            os.getuid() != route["uid"] or account.pw_name != route["user"] or
            str(home) != route["home"] or
            str(home_stamp.st_dev) + ":" + str(home_stamp.st_ino) != route["identity"] or
            str(stamp.st_dev) + ":" + str(stamp.st_ino) != route["rootIdentity"]):
        raise SystemExit(2)
    return route, home, root

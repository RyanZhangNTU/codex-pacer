#!/usr/bin/env python3
"""Submit with a Keychain profile or credentials kept only in process memory."""
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    artifact = Path(sys.argv[1]).resolve(strict=True)
    args = ["xcrun", "notarytool", "submit", str(artifact), "--wait", "--output-format", "json"]
    profile = os.environ.get("APPLE_NOTARY_PROFILE")
    if profile:
        args += ["--keychain-profile", profile]
    else:
        apple_id = os.environ.get("APPLE_ID") or input("Apple ID: ").strip()
        team = os.environ.get("APPLE_TEAM_ID") or input("Apple team ID: ").strip()
        password = os.environ.get("APPLE_PASSWORD") or getpass.getpass("App-specific password (hidden): ")
        args += ["--apple-id", apple_id, "--team-id", team, "--password", password]
    # Do not print args or raise CalledProcessError: either would expose credentials.
    result = subprocess.run(args, capture_output=True, text=True)
    try:
        receipt = json.loads(result.stdout)
    except json.JSONDecodeError:
        print("Notarization failed before a receipt was returned. Check credentials/connectivity.", file=sys.stderr)
        return 1
    status = receipt.get("status", "Unknown")
    request_id = receipt.get("id", "unavailable")
    print(f"Notarization: {status}; submission ID: {request_id}")
    Path(str(artifact) + ".notary.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if result.returncode == 0 and status == "Accepted" else 1


if __name__ == "__main__":
    raise SystemExit(main())

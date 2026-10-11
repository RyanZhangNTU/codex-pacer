#!/usr/bin/env python3
"""Submit with a notarytool Keychain profile; passwords never reach this process."""
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    artifact = Path(sys.argv[1]).resolve(strict=True)
    profile = os.environ.get("APPLE_NOTARY_PROFILE")
    if not profile:
        print("Set APPLE_NOTARY_PROFILE to a profile created with `xcrun notarytool store-credentials`.", file=sys.stderr)
        return 2
    args = ["xcrun", "notarytool", "submit", str(artifact), "--wait", "--output-format", "json",
            "--keychain-profile", profile]
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
    if result.returncode == 0 and status == "Accepted":
        return 0
    if "id" in receipt:
        # Apple's log names each rejected file and the signing rule it failed.
        log = Path(str(artifact) + ".notary-log.json")
        subprocess.run(["xcrun", "notarytool", "log", request_id, "--keychain-profile", profile, str(log)],
                       capture_output=True, text=True)
        if log.exists():
            print(f"Notarization log: {log}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

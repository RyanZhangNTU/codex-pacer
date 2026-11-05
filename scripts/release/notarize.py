#!/usr/bin/env python3
"""Submit for notarization; passwords never reach this process.

A release Mac uses a notarytool Keychain profile. The Release workflow uses an App
Store Connect API key file it writes for the job and deletes afterwards.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def credentials():
    key = os.environ.get("APPLE_NOTARY_KEY_PATH")
    if key:
        return ["--key", key, "--key-id", os.environ["APPLE_NOTARY_KEY_ID"], "--issuer", os.environ["APPLE_NOTARY_ISSUER_ID"]]
    profile = os.environ.get("APPLE_NOTARY_PROFILE")
    return ["--keychain-profile", profile] if profile else None


def main():
    artifact = Path(sys.argv[1]).resolve(strict=True)
    credential = credentials()
    if not credential:
        print("Set APPLE_NOTARY_PROFILE to a profile created with `xcrun notarytool store-credentials`.", file=sys.stderr)
        return 2
    args = ["xcrun", "notarytool", "submit", str(artifact), "--wait", "--output-format", "json", *credential]
    result = subprocess.run(args, capture_output=True, text=True)
    try:
        receipt = json.loads(result.stdout)
    except json.JSONDecodeError:
        # notarytool explains credential and network failures only on stderr; it never prints the key.
        print("Notarization failed before a receipt was returned:", file=sys.stderr)
        print((result.stderr or result.stdout or "notarytool gave no reason").strip(), file=sys.stderr)
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
        subprocess.run(["xcrun", "notarytool", "log", request_id, *credential, str(log)],
                       capture_output=True, text=True)
        if log.exists():
            print(f"Notarization log: {log}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

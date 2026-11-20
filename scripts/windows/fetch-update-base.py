"""Fetch the verified manifest of the previous Windows release."""
import argparse
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from hashlib import sha256
from http.client import IncompleteRead
import json
from pathlib import Path
import socket
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen
from xml.etree import ElementTree

RELEASES = "https://github.com/RyanZhangNTU/codex-pacer/releases"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PACER = "{urn:codex-pacer:windows-update}"


def retry_after(value):
    if not value:
        return 0
    if value.isdigit():
        return int(value)
    try:
        return max(0, (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds())
    except (ValueError, TypeError, OverflowError):
        return 0


def download(url, *, optional=False, open_url=urlopen, sleep=time.sleep):
    deadline = time.monotonic() + 90
    for attempt in range(3):
        delay = 2 ** attempt
        try:
            # Each attempt starts with a fresh buffer, including after a partial response.
            with open_url(url, timeout=max(1, min(25, deadline - time.monotonic()))) as response:
                chunks = []
                while chunk := response.read(65536):
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Download deadline elapsed")
                    chunks.append(chunk)
                payload = b"".join(chunks)
                length = response.headers.get("Content-Length")
                if length is not None and len(payload) != int(length):
                    raise ConnectionResetError("Incomplete download")
                return payload
        except HTTPError as error:
            status = error.code
            retry_delay = retry_after(error.headers.get("Retry-After") if error.headers else None)
            error.close()
            if optional and status == 404:
                return None
            if status not in (408, 429, 500, 502, 503, 504):
                raise RuntimeError(f"Windows update download returned HTTP {status}") from None
            reason = f"HTTP {status}"
            delay = max(delay, retry_delay)
        except (TimeoutError, ConnectionResetError, IncompleteRead, URLError) as error:
            cause = error.reason if isinstance(error, URLError) else error
            if not isinstance(cause, (socket.timeout, TimeoutError, ConnectionResetError, IncompleteRead)):
                raise RuntimeError("Windows update download failed: " + type(cause).__name__) from None
            reason = type(cause).__name__
        if attempt == 2 or time.monotonic() + delay >= deadline:
            raise RuntimeError(f"Windows update download failed after {attempt + 1} attempts ({reason})")
        print(f"Windows update download: {reason}, retrying in {delay:g}s", file=sys.stderr)
        sleep(delay)


def version_tuple(value):
    fields = value.split(".")
    if len(fields) not in (2, 3, 4) or not all(part.isascii() and part.isdigit() for part in fields):
        raise ValueError("The latest Windows feed names an invalid version")
    return tuple(map(int, fields))


def fetch(output, architecture, current, get=download):
    feed = get(RELEASES + "/latest/download/appcast-windows.xml", optional=True)
    if feed is None:
        return "No patch base: the latest Windows feed has not been published."
    signature, newline, xml = feed.partition(b"\n")
    if not newline or len(signature) > 256:
        raise ValueError("The latest Windows feed has no signature line")
    for item in ElementTree.fromstring(xml).findall("channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None or enclosure.get(SPARKLE + "os") != "windows-" + architecture:
            continue
        version = item.findtext(SPARKLE + "shortVersionString", "")
        build = item.findtext(SPARKLE + "version", "")
        version_tuple(version)
        if version_tuple(build) >= version_tuple(current):
            return "No patch base: the published build is not older than the candidate."
        digest = enclosure.get(PACER + "manifestSHA256")
        if digest is None:
            return "No patch base: this release publishes no Windows manifest."
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest.lower()):
            raise ValueError("The latest Windows feed contains an invalid manifest digest")
        name = f"Codex-Pacer-{version}-windows-{architecture}-manifest.json"
        data = get(f"{RELEASES}/download/v{version}/{name}")
        if sha256(data).hexdigest() != digest.lower():
            raise ValueError("The published manifest differs from the latest feed")
        info = json.loads(data)
        if info.get("architecture") != architecture or f"{info.get('version')}.{info.get('build')}" != build:
            raise ValueError("The published manifest is for another architecture or build")
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
            verified = Path(tmp) / name
            verified.write_bytes(data)
            verified.replace(output)
        return str(output.resolve())
    return f"No patch base: the latest feed has no {architecture} build."


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("architecture", choices=("x64", "arm64"))
    parser.add_argument("current")
    args = parser.parse_args()
    try:
        print(fetch(args.output, args.architecture, args.current))
    except (ValueError, OSError, RuntimeError, ElementTree.ParseError) as error:
        sys.exit(str(error))

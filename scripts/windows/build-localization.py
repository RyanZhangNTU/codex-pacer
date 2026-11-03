"""Derive host catalogs from the original shared strings and Windows-only text."""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("en", "zh-Hans")
SKIP = re.compile(r"(?:\s+|//[^\n]*(?:\n|$)|/\*.*?\*/)*", re.DOTALL)


def shared_strings(source):
    """Parse the catalogs' quoted UTF-8 strings, rejecting unconsumed input."""
    decoder, values, position = json.JSONDecoder(), {}, 0
    while True:
        position = SKIP.match(source, position).end()
        if position == len(source):
            return values
        key, position = decoder.raw_decode(source, position)
        if not isinstance(key, str) or not key or key in values:
            raise ValueError("Shared localization keys must be nonempty, unique strings")
        position = SKIP.match(source, position).end()
        if source[position:position + 1] != "=":
            raise ValueError("Expected '=' after a shared localization key")
        position = SKIP.match(source, position + 1).end()
        value, position = decoder.raw_decode(source, position)
        if not isinstance(value, str):
            raise ValueError("Shared localization values must be quoted strings")
        position = SKIP.match(source, position).end()
        if source[position:position + 1] != ";":
            raise ValueError("Expected ';' after a shared localization value")
        position += 1
        values[key] = value


def catalogs():
    result = {}
    for language in LANGUAGES:
        sources = {}
        shared = f"native/Sources/PacerCore/Resources/{language}.lproj/Localizable.strings"
        platform = f"windows/EngineSupport/Resources/Localization/{language}.json"
        texts = {}
        for path in (shared, platform):
            text = (ROOT / path).read_text(encoding="utf-8")
            texts[path] = text
            # Normalize checkout line endings, as Foundation does for strings.
            sources[path] = sha256(text.encode("utf-8")).hexdigest()
        strings = shared_strings(texts[shared])
        additions = json.loads(texts[platform], object_pairs_hook=unique_pairs)
        if not isinstance(additions, dict):
            raise ValueError("Windows-only localization must be a JSON object")
        if any(not key.startswith("windows.") or not isinstance(value, str) or not value for key, value in additions.items()):
            raise ValueError("Platform-only strings must use nonempty windows.* keys and values")
        if set(strings) & set(additions):
            raise ValueError("Windows-only text cannot override a shared string")
        strings.update(additions)
        result[language] = {"schemaVersion": 1, "language": language, "sources": sources, "strings": strings}
    if set(result["en"]["strings"]) != set(result["zh-Hans"]["strings"]):
        raise ValueError("English and Chinese localization keys must match")
    return result


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate Windows localization key: " + key)
        result[key] = value
    return result


def build(check=False):
    for language, document in catalogs().items():
        target = ROOT / f"windows/EngineSupport/Resources/Localization/Catalogs/{language}.json"
        expected = json.dumps(document, ensure_ascii=True, sort_keys=True, indent=2) + "\n"
        if check:
            if not target.is_file() or target.read_text(encoding="utf-8") != expected:
                raise ValueError("Regenerate the Windows catalog with python scripts/windows/build-localization.py: " + language)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(expected.encode("utf-8"))
    print("Windows catalogs match the shared English/Chinese sources.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    try:
        build(arguments.check)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

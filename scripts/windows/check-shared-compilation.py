"""Typecheck shared Core without the temporary EngineSupport module members."""
import argparse
import json
from pathlib import Path
import subprocess


def check(scratch):
    description = scratch / "x86_64-unknown-windows-msvc/debug/description.json"
    commands = json.loads(description.read_text(encoding="utf-8"))["swiftCommands"]
    command = next(value for value in commands.values() if value.get("moduleName") == "PacerCore")
    sources = [name for name in command["sources"] if "/windows/EngineSupport/" not in name.replace("\\", "/")]
    arguments, skip = [], False
    destinations = {"-index-store-path", "-emit-objc-header-path", "-emit-module-path", "-output-file-map", "-o"}
    emission = {"-incremental", "-enable-batch-mode", "-serialize-diagnostics", "-parseable-output",
                "-emit-objc-header", "-static", "-emit-module", "-emit-object"}
    for argument in command["otherArguments"]:
        if skip:
            skip = False
        elif argument in destinations:
            skip = True
        elif argument not in emission:
            arguments.append(argument)
    subprocess.run([command["executable"], "-typecheck", "-module-name", "PacerCore", "-I", command["importPath"],
                    *arguments, *sources], check=True)
    count = sum("/native/Sources/PacerCore/" in name.replace("\\", "/") for name in sources)
    print(f"Shared Core compiles without EngineSupport: {count} source files", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path, required=True)
    check(parser.parse_args().scratch_path)

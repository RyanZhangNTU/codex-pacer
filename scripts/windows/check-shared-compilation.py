"""Verify the full Core target and compile a forbidden host-type reference."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def compiler_arguments(command):
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
    return arguments


def response_file(arguments):
    # Swift expands @file arguments before parsing options. Quote every item
    # so a source path with spaces or backslashes remains one argument.
    return "".join('"' + argument.replace("\\", "\\\\").replace('"', '\\"') + '"\n' for argument in arguments)


def check(scratch):
    description = scratch / "x86_64-unknown-windows-msvc/debug/description.json"
    commands = json.loads(description.read_text(encoding="utf-8"))["swiftCommands"]
    command = next(value for value in commands.values() if value.get("moduleName") == "PacerCore")
    support = next(value for value in commands.values() if value.get("moduleName") == "PacerEngineSupport")
    sources = [Path(name) for name in command["sources"]]
    directory = next(path.parent for path in sources if path.parent.name == "PacerCore")
    expected = {path.resolve() for path in directory.rglob("*.swift")}
    compiled = {path.resolve() for path in sources if path.resolve().is_relative_to(directory.resolve())}
    generated = [path for path in sources if path.resolve() not in expected]
    if compiled != expected or any(path.name != "resource_bundle_accessor.swift" for path in generated):
        raise RuntimeError("Core must compile the complete directory without any host sources")
    if not support["sources"] or any("/windows/EngineSupport/" not in name.replace("\\", "/") and not name.endswith("resource_bundle_accessor.swift") for name in support["sources"]):
        raise RuntimeError("EngineSupport is not compiled as an independent host target")
    # Use exactly the Core command, not a manually filtered list. With the old
    # combined target, WindowsFileSystem would be visible and this probe would pass.
    with tempfile.TemporaryDirectory(prefix="core-boundary-", dir=scratch) as temporary:
        probe = Path(temporary) / "probe.swift"
        probe.write_text("let forbiddenHostReference = WindowsFileSystem()\n", encoding="utf-8")
        args = Path(temporary) / "arguments.rsp"
        args.write_text(response_file(["-typecheck", "-module-name", "PacerCore", "-I", command["importPath"],
                                      *compiler_arguments(command), *map(str, sources), str(probe)]), encoding="utf-8")
        result = subprocess.run([command["executable"], "@" + str(args)], capture_output=True, text=True, encoding="utf-8")
        if result.returncode == 0 or "cannot find 'WindowsFileSystem' in scope" not in result.stderr:
            raise RuntimeError("Core/host boundary probe did not reject the Windows type: " + result.stderr[-4000:])
    print(f"Whole Core target compiled: {len(expected)} source files; separate EngineSupport target; forbidden Windows type rejected", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path, required=True)
    check(parser.parse_args().scratch_path)

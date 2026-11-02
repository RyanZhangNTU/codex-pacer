# Windows engine development

C1 builds `PacerEngine` and its platform adapters. The C2 WPF host and its unsigned CI package are described in [windows-shell.md](windows-shell.md). The shipping Mac app still uses `native/Package.swift`; its CI jobs continue to run the full native tests and app build.

Use Windows x64, Visual Studio C++ build tools and a Windows SDK. `windows/toolchain-lock.json` pins Swift 6.4.2 and .NET SDK 10.0.403. The .NET SDK builds synthetic process/pipe fixtures, without a desktop shell. `setup-swift.ps1` installs the pinned, verified Swift toolchain under ignored `output/toolchains` when needed.

```powershell
./scripts/windows/setup-swift.ps1
python scripts/windows/check-contract.py
python scripts/windows/test_contract.py
./scripts/windows/test-engine.ps1
./scripts/windows/build-engine.ps1 -Configuration release
```

Builds stage immutable source snapshots outside OneDrive and reuse an isolated SwiftPM cache under the temporary directory. `output/windows/engine-location.json` records the source snapshot, cache and configuration. The executable is under `<scratch>/x86_64-unknown-windows-msvc/<configuration>/PacerEngine.exe`. The pinned toolchain uses SwiftPM's native build system; its deprecation and optional `debug` symlink notices are build-tool notices, separate from compiler warnings. Windows CI checks compiler diagnostics in both test and build logs.

Parallel worktrees can set `PACER_WINDOWS_SCRATCH_PATH` to separate temporary cache directories before running the build/test scripts. This prevents one build from replacing another worktree's test executable or resources.

The engine speaks bounded newline-delimited JSON on stdin/stdout. Requests carry `protocolVersion: 1`, an `id` and a `method`. An `initialize` request supplies enabled providers and source roots; `shutdown` closes owned work. Do not save live protocol bodies: they can contain task display metadata. Diagnostics and acceptance records must exclude credentials, account identity and private task content.

For an idle check with empty provider homes, run:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --output output/windows/engine-idle.json
```

This runs for at least two minutes, discards protocol bodies, reports CPU time and both single-core and host percentages, changes the Codex source, then measures shutdown. It does not validate populated sources, browser login or the WPF UI.

For a five-minute check against actual provider homes:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --seconds 300 --real-data --output output/windows/engine-real-idle.json
```

This uses `--read-only-diagnostics`: local logs and Desktop observations remain enabled, while quota clients, browser sessions and completion persistence are disabled. It does not install hooks or change provider files. Source paths and protocol bodies are discarded; only numeric CPU/protocol counters are recorded.

Windows adapters implement the B2 file, process, executable, installation, credential and localization ports. File identities use volume plus the full file ID; metadata can describe a reparse point or its target. Win32 calls live under `windows/Native`. Claude clients, account/session metadata parsing, numeric validation and DeepSeek scripts compile from the authoritative Core files. There is no generated Claude Swift copy or generator invocation.

The contract protects the current develop versions of shipping metadata, native resources and release/native scripts. It checks shipping package identity, dependency pins and explicit target wiring, while leaving presentation sources available for refactoring. `coreTransitions` records the remaining system imports and excluded files; new imports or conditional branches fail unless reviewed. Conditional-import exceptions (`FoundationNetworking` and `CoreGraphics`) may contain only their guarded import.

The source selection and combined Windows Core/engine-support target are temporary. B4a shares the watcher, Claude/DeepSeek monitors, hook configuration and telemetry; B4b will share Realtime/Codex collectors and helper probes. B5a will unify activity merge, inbox and task projection; B5b will replace Codex/Claude quota, Cloud source and DeepSeek balance/history schedulers; B5c will unify lifecycle, navigation acknowledgment and host tracking. At the end of C after B5c, both platforms must compile the whole Core, and the root Package selection, `shared-core.json` and coverage's `remainingCoreSources`/`remainingCoreTests` must be removed. P2 wires SSH/Remote features; it does not own shared compilation cleanup.

F1 (#137) is included in the develop baseline. Windows uses that authoritative reader and runs its shared new-file/append and cold-history regressions. `windows/platform-contract.json` lists remaining files and owners. Coverage keeps all 47 features and distinguishes preview evidence from formal acceptance; a successful engine build does not establish UI or release parity.

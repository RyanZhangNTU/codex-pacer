# Windows engine development

The root package builds `PacerEngine` and its platform adapters. The WPF host and its CI packages are described in [windows-shell.md](windows-shell.md). The Mac app builds from `native/Package.swift`; its CI jobs run the full native tests and app build.

Use Windows x64, Visual Studio C++ build tools and a Windows SDK. `windows/toolchain-lock.json` pins Swift 6.4.2 and .NET SDK 10.0.403. The .NET SDK builds the shell and synthetic process/pipe fixtures. `setup-swift.ps1` installs the pinned, verified Swift toolchain under ignored `output/toolchains` when needed.

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

DeepSeek browser requests follow the snapshot that publishes their connection context. While configuration suspends task projection, the engine holds at most four requests. Cancellation and a replacement binding remove old requests; sleep and shutdown clear the queue. The browser host still validates every source context, and the existing read and cleanup deadlines remain in force.

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

Windows adapters implement the Core file, process, executable, installation, credential and localization ports. File identities use volume plus the full file ID; metadata can describe a reparse point or its target. Win32 calls live under `windows/Native`. Claude clients, account/session metadata parsing, numeric validation and DeepSeek scripts compile from the authoritative Core files. There is no generated Claude Swift copy or generator invocation.

## Log paths longer than MAX_PATH

`PacerEngine.exe` embeds an `asInvoker`, `longPathAware` manifest; the desktop already declares `longPathAware`. Windows file ports and directory watches convert absolute drive and UNC paths to extended Win32 paths only at the IO boundary. Canonical URLs, provider source identities and saved paths keep their existing form. FileHandle reads through the file port also use the extended path.

`WindowsFileSystemTests` covers Unicode/UNC conversion and metadata, bounded reads and watches beyond 260 characters. `LongPathChecks` starts the actual engine with isolated Codex, Claude and DeepSeek homes, including Claude's encoded project directory, and checks discovery, initial reads and appended completions without a refresh command. A native PE-resource inspection confirmed the manifest in both executables. Local runs had `LongPathsEnabled=1`; the complete application has not been verified with that system policy disabled.

## Shared Core and platform boundaries

`PacerCore` owns provider parsing, state, projections and lifecycle policy. `PacerMacSupport` supplies Mac IO. The separate `PacerEngineSupport` target depends on Core and supplies Windows IO and engine protocol assembly; native Windows calls stay in host code. Core cannot depend on either host target. Both packages compile the entire `native/Sources/PacerCore` directory, so new Core files enter both builds automatically; there is no Windows source or test inventory.

Both hosts share watcher scheduling, activity monitors, Realtime reconciliation and helper protocols; activity projections and quota, Cloud and balance coordination; and captured navigation acknowledgments, error expiry, host tracking and lifecycle plans. The flock singleton implementation lives in MacSupport; Windows retains its mutex and activation channel. Windows keeps named-pipe authentication and selected-home writer proofs; Mac keeps Unix socket, kevent and process/application IO.

Core owns source versions, work slots, the two-second host-scan cadence, sleep/wake order and the 650 ms cleanup budget. Hosts execute platform IO and connect native timers and power events. A successful conversation open acknowledges only the captured ending and still-matching descendant chains. Failed opens preserve unread cards. Navigation errors expire through a display-only publication. Protocol 1 includes optional navigation-error and busy-row fields plus sleep/wake commands; existing DTO fields remain compatible.

Both platforms run the complete `PacerCoreTests` target. Mac application discovery, Keychain, POSIX permissions, Unix sockets and actual Unix helper-process tests live in `PacerMacSupportTests`; mixed suites keep their portable cases in Core tests. Synthetic Python programs and arguments use temporary files so Windows command-line limits do not remove test coverage. Claude's initialization backlog and bounded cold-history reads use the shared reader, and Windows runs its new-file/append and cold-history regressions.

The platform contract recursively scans every Core source. Host imports and platform/business conditionals are rejected without exceptions; the conditional-import exceptions (`FoundationNetworking` and `CoreGraphics`) may contain only their guarded import. It also checks shipping package identity, dependency pins, native resources, release/native scripts and full-directory target wiring, while leaving presentation sources available for refactoring. Mac and Windows CI run the same contract tests. Windows also compiles a forbidden Windows-type reference with the actual Core compiler command and verifies that it fails. A successful engine build does not establish UI or installed-app behavior; see [windows-shell.md](windows-shell.md) and [Windows installation](windows-installation.md).

# Windows engine development

The root `Package.swift` builds `PacerEngine` and its Windows adapters. The WPF host is described in [Windows shell development](windows-shell.md), the installer in [Windows installation](windows-installation.md). The Mac app builds from `native/Package.swift`; see [development](development.md#continuous-integration) for its tests and CI.

## Build and test

Use Windows x64 with the Visual Studio C++ build tools and a Windows SDK. `windows/toolchain-lock.json` pins Swift, the .NET SDK, Windows App SDK, WebView2 and the minimum Windows build (19041). `setup-swift.ps1` installs the pinned, verified Swift toolchain under the ignored `output/toolchains` when needed.

```powershell
./scripts/windows/setup-swift.ps1
python scripts/windows/check-contract.py
python scripts/windows/test_contract.py
./scripts/windows/test-engine.ps1            # -Filter <suite> runs one suite
./scripts/windows/build-engine.ps1 -Configuration release
```

- Builds stage an immutable source snapshot outside OneDrive and reuse an isolated SwiftPM cache under the temporary directory. `output/windows/engine-location.json` records the snapshot, cache and configuration; the executable is `<scratch>/x86_64-unknown-windows-msvc/<configuration>/PacerEngine.exe`.
- Parallel worktrees should set `PACER_WINDOWS_SCRATCH_PATH` so one build cannot replace another worktree's test executable or resources.
- Toolchains outside the worktree are named with `PACER_SWIFT_ROOT`, `PACER_WINDOWS_SDK_ROOT` and `PACER_DOTNET_ROOT`.
- SwiftPM's native build system prints deprecation and `debug` symlink notices; those are build-tool notices, not compiler warnings. CI fails on compiler warnings in both the test and build logs.

## Protocol

The engine speaks bounded newline-delimited JSON on stdin and stdout. Requests carry `protocolVersion: 1`, an `id` and a `method`. `initialize` supplies the enabled providers and source roots; `shutdown` closes owned work. New fields must be optional so existing DTOs stay compatible.

- Never save live protocol bodies: they carry task display metadata. Diagnostics and acceptance records exclude credentials, account identity and private task content.
- The optional `hello.harnessModules` lists extra module IDs supported by the engine. A host that understands them sets `supportsHarnessModules` on `initialize`. Without that exchange, both sides keep the original three modules on protocol 1.
- While configuration suspends task projection, the engine holds at most four DeepSeek browser requests. Cancellation, a new binding, sleep and shutdown clear them.

## Shared Core and platform boundaries

- `PacerCore` owns provider parsing, state, projections and lifecycle policy: source versions, work slots, the two-second host-scan cadence, sleep and wake order, and the 650 ms cleanup budget. Hosts run platform IO and connect native timers and power events.
- `PacerMacSupport` supplies Mac IO. `PacerEngineSupport` (`windows/EngineSupport`) supplies Windows IO and protocol assembly; Win32 calls live under `windows/Native`. Core cannot depend on either host target.
- Both packages compile the whole `native/Sources/PacerCore` directory, so a new Core file enters both builds; there is no Windows source list. Claude clients, metadata parsing and DeepSeek scripts compile from the Core files; there is no generated Swift copy.
- Windows adapters implement Core's file, process, executable, installation, credential and localization ports. A file's identity is its volume plus its full file ID.
- Windows keeps its named mutex and activation channel, named-pipe authentication and writer proofs; the Mac keeps Unix sockets, kevent and the flock singleton.
- Both platforms run the full `PacerCoreTests` target. Mac-only IO tests live in `PacerMacSupportTests`. Synthetic Python programs take their arguments from temporary files so the Windows command-line limit cannot drop coverage.

The platform contract (`windows/platform-contract.json`, checked by `check-contract.py` in CI) scans every Core source and rejects host imports and platform or business conditionals. Only `FoundationNetworking` and `CoreGraphics` may appear in a conditional import, and only as the import. It also checks package identity, dependency pins, native resources and target wiring, and pins the digests of the Mac shipping files and release scripts (`protectedFiles`), so changing one of those needs a contract update in the same change. Windows CI also compiles a forbidden Windows-type reference with the real Core compiler command and expects it to fail.

## WorkBuddy

WorkBuddy (the China build, data in `%USERPROFILE%\.workbuddy`) and WorkBuddy AI (the international build, `%USERPROFILE%\.workbuddy-ai`) are separate modules. Like the other services, each is automatic: it turns on when Pacer finds its app or its data folder, and its own Settings page or the Module Library turns it off. The app is found in `%ProgramFiles%` or `%LOCALAPPDATA%\Programs`, or in a folder the user chose while installing it, through the `workbuddy://` or `workbuddy-ai://` handler it registers (HKCU, then HKLM). Pacer opens it only from a local drive, by its own executable name, with Tencent's signature. Pacer opens `workbuddy.db` read-only when the WAL and SHM are present. Set `WORKBUDDY_CONFIG_DIR` or `WORKBUDDY_AI_CONFIG_DIR` to an absolute path in Pacer’s environment, or choose a folder in the module's Settings page, to use a different directory. The account snapshot limits reads to the signed-in user. The query checks the 512 most recently inserted session rows and follows observed sessions by primary key. Pacer can miss an older session resumed outside those rows.

WorkBuddy AI 5.9.4 wrote both a reply and a manual stop as `completed`. Pacer checks the same turn in the local transcript to distinguish completion, cancellation and a pending question. It keeps task metadata, not the text of prompts, replies or answers. A completed or interrupted turn can remain in the inbox; a baseline read does not send an alert. The default profile can open an exact conversation through the signed WorkBuddy app.

A running task shows its stage like the other modules (starting, thinking or a tool), never the cloud icon that cloud polls use. The transcript holds a model response only once it ends. WorkBuddy's HY models think for 2.5 to 3 minutes before their first step, so `WorkBuddyRunLog` reads the stage live from WorkBuddy's process logs, `logs/<date>/<name>__<32 hex digits>.log`. A task's process is named after the task's folder, and WorkBuddy's own new-task folders are named by date and time; `__workbuddy_cli_host` also runs tasks, so every such log is read. It reads only the `[SessionRunStateMachine] transition` lines: session, event, state, whether a tool is named, and the local time at the start of the line. That time follows the system region's format: `[2026年11月15日 下午10:05:20.514]` on a Chinese Windows, `[11/15/2026, 1:54:39 PM.902]` on a Mac with US formats. The reader takes the numbers in order, with the four-digit year first or third. It uses a 12-hour clock when the text says AM or PM, and when day and month could swap it picks the reading nearer the file's last write. The time is read in `Calendar.current`'s zone, which follows the offset the host passes at startup; Foundation's `TimeZone.current` is GMT on Windows. Without a readable time, a line takes the file's last write. It follows the eight newest logs written in the last 15 minutes, today's and yesterday's, lists them again at most every 5 seconds, and reads what they appended during the monitor's 1-second check. A new stage triggers a refresh; other log lines don't. A state from before the turn started is ignored. Without the log, an open tool call means a tool and anything else means thinking.

A tool call that writes a file holds the whole file, and WorkBuddy appended 342 KB in three seconds while writing a web page. The transcript reader catches up on up to 32 MB of new lines and parses lines up to 8 MB. A first read, or a larger gap, starts at the latest request: it searches back for `"startsNewUserRequest":true` in raw bytes, up to 32 MB. Before 11/15 a burst over 256 KB restarted the reader at the last 256 KB, past the request that opened the turn. The row then lost its turn: no ring, model or speed, and "Awaiting usage".

WorkBuddy settings and Overview can show context and credits for the latest session. Account credits come from the WorkBuddy site after the user signs in through Pacer’s own WebView2 profile. The host reads the account independently of the local task monitor. The task progress ring is on by default (a module listed in `disabledHarnessProgress` has it off): it adds the local MCP tool and its reporting rule, and the user trusts the tool once in WorkBuddy, guided by the card on the module's Settings page. A percentage appears after WorkBuddy calls the tool and records a successful reply for that turn.

## Log paths longer than MAX_PATH

`PacerEngine.exe` embeds an `asInvoker`, `longPathAware` manifest, as does the desktop. File ports and directory watches convert absolute drive and UNC paths to extended Win32 paths only at the IO boundary; canonical URLs, source identities and saved paths keep their normal form. A folder watch reports only entries created, removed or renamed in that folder, like the Mac's vnode watches; appends to a log are seen by that file's own watch, so activity elsewhere under `~/.claude` or `~/.codex` wakes nothing.

`WindowsFileSystemTests` and the desktop's `LongPathChecks` cover paths beyond 260 characters. Known limitation: the whole app has only been run with `LongPathsEnabled=1`.

## HTTP through WinHTTP

On Windows, FoundationNetworking's URLSession keeps one worker thread busy for as long as a response stays open: libdispatch re-signals a libcurl socket write source each time it is armed, and `_SocketSources` cancels it only when libcurl removes the socket. Claude's cloud message streams stay open (up to four project and six thread streams) and cloud polling sends up to 16 requests every 30 seconds, so the engine uses WinHTTP's asynchronous API instead, through `WindowsHTTPStream`. Claude's quota reads go through the host's private browser when it offers them ([web sign-in](windows-shell.md#web-sign-in)); WinHTTP remains their fallback.

| Client | Used for | Limits |
| --- | --- | --- |
| `WindowsClaudeCloudStream` | `GET` on `https://claude.ai` message-stream paths only | 4 MiB line limit, eight-line buffer, 60 s idle, 24 h total |
| `WindowsHTTPClient` | Claude web usage, Claude cloud polling, Remote Control catalogs, Claude OAuth usage | Claude web usage: 30 s request, 33 s total, 32 MiB body; cloud polling: 12 s and 15 s. Remote Control: 8 s and 10 s, 512 KiB. Claude OAuth usage: 30 s and 33 s, 2 MiB |

Rules both clients keep:

- No redirects are followed; a redirect is returned as the response. Cookies, stored or default credentials and caches are off. Headers that could start another line are rejected.
- Each request has a dedicated thread waiting on WinHTTP events, started through `WindowsThread`, which closes the thread handle at once. Foundation's `Thread` never closes the handle `_beginthreadex` returns, which leaked one handle per request.
- EOF is confirmed by a read. Fixed-length bodies are checked against the encoded byte count, so an early disconnect fails even when the prefix is valid JSON. The memory bound applies to decoded bytes.
- Proxies come from `https_proxy` or `all_proxy`, honoring `no_proxy`. Direct connections and plain HTTP proxies use WinHTTP directly. SOCKS4, SOCKS4a, SOCKS5, SOCKS5h and HTTP proxies with credentials go through `WindowsProxyRelay`, a loopback proxy started for one request that accepts only that request's host and port. TLS stays end to end. A failed proxy request is never retried directly.
- Only HTTPS proxies and proxy values WinHTTP cannot express keep the URLSession path and its CPU cost. DeepSeek balance reads still use URLSession; they run only with a DeepSeek key and finish within seconds.

`WindowsClaudeCloudStreamTests`, `WindowsHTTPClientTests`, `WindowsRemoteControlHTTPTests` and `WindowsProxyRelayTests` run loopback requests through the real WinHTTP path and assert that an idle open stream, a pending request and an idle relayed stream each use less than 10% of one core. `WindowsURLSessionCompatibilityTests` covers the remaining URLSession path.

## Child processes

Helper commands run through swift-subprocess 1.0.2; launching a task's host application uses `CreateProcessW`.

- Short commands (WSL list and probes, SSH probes, Codex progress setup, Claude hook setup) use `WindowsSubprocess.capture`. It bounds stdout and gives the child two `NUL` descriptors that the engine opens once.
- Do not pass `.none` input or `.discarded` output on Windows. swift-subprocess then opens `NUL` through the C runtime on every run and never releases the descriptor; the 30-second WSL discovery once exhausted the runtime's 8,192 descriptors in about 15 hours and stopped the engine. `WindowsSubprocessTests` checks that captures keep no descriptors.
- Long-running helpers (Codex app-server, SSH and WSL helpers) stream `.sequence` output through `WindowsCodexProcess`.

### WSL discovery

WSL monitoring starts disabled. The desktop applies the one-time opt-in migration before it initializes the engine. The Remote page can check the installed distributions even when monitoring is off. The engine validates that at least one is installed before it accepts an enable request.

While monitoring is on, Pacer watches the current user's WSL registrations and refreshes the installation list when they change. It starts helpers only in running distributions. If a helper disconnects, Pacer rechecks its route before reconnecting it. Other helpers in that distribution can keep reporting unless their own route changes or the distribution stops. Unread completions stay when a distribution stops and are removed when it is unregistered.

Pacer checks the running list once a minute if it cannot watch the registry or if any of the first eight installed distributions still lacks a route for an enabled provider. That includes stopped distributions, missing Python, and providers whose configuration directories do not exist yet. The fallback reuses the installation list while the watch is working and probes each incomplete profile at most every five minutes. Registration changes, a restart, a disconnect or a manual refresh can trigger an earlier probe. Once all enabled routes are verified and the watch is working, streams and registration notifications take over. WSL discovery does not refresh the Remote Control directory.

## Writers of a session file

Host tracking, opening a task and the Codex Desktop source binding ask which processes hold a session file open for writing. The Desktop source binding rechecks a granted thread's proof at most once a second and retries a denied thread after 2, 2, 2, then 300 seconds, or at once when a follow names its owner. `WindowsFileOwners.c` asks Restart Manager for candidates, captures each one's handle table with `PssCaptureSnapshot`, and compares the file identity of every handle with write access.

Always request `PSS_CAPTURE_HANDLE_NAME_INFORMATION` with the basic information. Windows 10 (through at least build 19045.7725) clears the capture's name buffer only when names are requested and otherwise leaves stale stack pointers there, which can crash the engine in `ntdll.dll`. Windows 11 and CI clear it either way, so they cannot show the fault. The fix has not been run on a Windows 10 machine. `WindowsProcessOwnershipTests` checks that the capture reports names.

## Crash reports

When the engine stops on an unhandled exception, a damaged heap or `abort()`, `CrashReport.c` writes `%LOCALAPPDATA%\CodexPacer\CrashLogs\engine-crash-<identifier>.txt`. The desktop gives each engine start its own identifier with `--crash-log-id`, `--crash-log-directory` and `--app-version`, so a reused process number cannot mix two starts. After the engine's output ends, the desktop's `EngineCrashLog` appends the exit code and running time, or writes the whole report for a fail-fast exit. The ten newest reports are kept.

Reports are meant to be attached to public issues, so they hold a fixed set of fields and no free text:

- Pacer and Windows versions, the exception and faulting address, and the stack and modules as file names with offsets, plus each module's link time, image size and symbol identity.
- No memory contents, register values, paths, arguments or environment. The stack walk stops at a frame outside every module.
- From Swift's error text only the kind, module, file name and line are kept (as `swift:`); the message and the runtime's printed stack are dropped.

The handlers do only what a damaged process still can: the file is opened at install time and marked for deletion, text is built in static storage without the heap, locale or loader lock, and the stack is unwound from the faulting registers. A vectored handler catches heap corruption and a `SIGABRT` handler catches `abort()`, because Windows skips the unhandled-exception filter for both.

```powershell
PacerEngine.exe --crash-log-directory <existing folder> --diagnose-crash access-violation   # or fatal-error, abort
python scripts/windows/symbolize-crash-report.py <report> [--binaries <folder with this build>]
```

The symbolizer fetches Microsoft's symbols by the identities in the report and reads the engine's own modules from `--binaries`. `WindowsCrashReportTests` crashes the real engine each way; `EngineCrashLogChecks` covers the desktop's part.

## Heap below 2 GB

Swift 6.4.2 keeps either a string's UTF-16 length or a pointer to its breadcrumbs in one word of the string's storage, and reads any value up to `Int32.max` as a length ([swiftlang/swift#92199](https://github.com/swiftlang/swift/pull/92199)). Windows places a process's heap far above 2 GB only while both bottom-up and high-entropy address randomization apply to it. With either turned off in Exploit Protection, the heap starts a few megabytes up. The length of a non-ASCII string of 64 UTF-8 bytes or more then becomes a heap address once its breadcrumbs exist, and Foundation stops the engine with `0xC000001D` in `NSString.getCharacters` (`Foundation.dll+0x103785` in 4.5.1). The first such string is usually a path under a user folder with a non-ASCII name, while the engine looks for `codex.exe`.

The desktop's `EngineLaunch` asks Windows which randomization applies (`GetProcessMitigationPolicy`), for itself and then for the engine it started. Where both forms apply, the engine starts through `Process.Start` as before. Otherwise the desktop creates the engine suspended, reserves every free region below 2 GB in it with `VirtualAllocEx(MEM_RESERVE, PAGE_NOACCESS)`, and resumes it. Windows creates the process heap when the first thread runs, so no heap block can lie below the limit. The reservation takes address space only, no memory.

- The guard covers the engine the desktop starts. `PacerInstallerHooks.exe`, `PacerWindowsBridge.dll` inside the desktop and the engine's console modes (`--ssh-terminal`, `--wsl-terminal`) are not covered. The fix is on Swift's `release/6.4.x` branch and in no release up to 6.4.2; a pinned toolchain that has it covers them too.
- `PacerEngine.exe --diagnose-low-addresses` prints `heap high` or `heap low` and checks the lengths in that process.
- `EngineAddressSpaceChecks` clears `IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA` in a copy of the engine outside the build, which gives it the low heap on any machine, and runs it with and without the guard: `dotnet run --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -- --address-guard-only <PacerEngine.exe>`.

## SSH sources

Windows reads hosts already saved by Codex or Claude, with the shared discovery, route keys, activity monitors and shutdown deadline. Claude Desktop routes come from `ssh_configs.json` in the [active Desktop data folder](windows-shell.md#claude-desktop-data-folder); the selected Claude home's `settings.json` can override them.

- **Setting:** Monitor Tasks on SSH Hosts uses the Mac key `monitorSSH` (absent means on). Turning it off closes owned helpers. Sleep and exit close stdin and use the shared 650 ms cleanup deadline.
- **ssh.exe:** `%SystemRoot%\System32\OpenSSH\ssh.exe` first, then absolute PATH entries. Routes resolve through bounded `ssh -G` output.
- **Connection policy:** `BatchMode=yes` and `StrictHostKeyChecking=yes`; password prompts, host-key updates, local commands, agent and port forwarding and connection sharing are off. Pacer never edits SSH config or `known_hosts`. A host without access stays unavailable until the user sets access up.
- **Commands:** the shared collector command travels in a bounded, length-prefixed stdin frame that a small remote Python bootstrap reads before running it. This avoids the Windows command-line limit without writing a helper to the remote host.
- **Opening a task:** a base64 plan goes to a console mode of `PacerEngine.exe` (`--ssh-terminal`), which revalidates the route and UUID before launching SSH with a TTY, in Windows Terminal or else a normal console. Codex runs `codex resume <UUID>`, Claude the shared `ClaudeRemoteResume` program; neither sends a prompt.

### Claude remote hooks

Reachable Claude sources use Core's `ClaudeRemoteAutoSetup` and `ClaudeRemoteSetup`, sharing the installer, digest cache and scheduler with WSL.

- Setup needs an existing remote Claude home, preserves user hooks, wraps the previous status-line renderer and respects telemetry conflicts. The adapter digest controls upgrades.
- A failed attempt waits 30 minutes or a manual retry, on one sleeping timer. Core limits setup to 15 seconds. Disabling, source replacement, sleep and quit cancel it; late results are discarded.
- The bounded version-1 cache (`claudeRemoteSetupDigests`) holds only validated SSH aliases and digests. Losing it only makes the idempotent installer check again.
- Snapshots carry `claudeRemoteSetups` rows (`sourceID`, opaque `context`, `configured`, `inFlight`, `canRetry`, optional `message` and `retryAt`). `retryClaudeRemoteSetup` takes the row's `sourceID` and `context`; the caller can never supply a host or command.
- Read-only diagnostics and demo never install hooks.

`WindowsSSHTests` and `WindowsClaudeRemoteTests` use a synthetic SSH executable and disposable remotes. They do not cover a real host, Windows Terminal TTY resume or remote sleep and reconnect.

## Claude Python runtime

The package ships the official CPython embeddable runtime for its architecture, so Claude hooks and the status line never depend on a user Python, PATH or the Store alias. Using Python lets Windows run the unchanged shared `claude_hook.py` with the same event, ownership, quota and privacy rules as the Mac. Telemetry stays on the engine's loopback HTTP server.

**Pins.** `windows/InstallerSupport/Resources/python-runtime-lock.json` (x64) and `python-runtime-lock-arm64.json` hold the version, URL, SHA-256, publisher and signed files. The build checks the ZIP hash and the Python Software Foundation Authenticode signatures and writes a per-file manifest. The official ARM64 archive carries an x64 `vcruntime140_1.dll`; `prune-arm64-runtime.py` removes it from the staging copy after confirming nothing references it. To take a security update, update both lock files from the official release, then rerun the shared tests, `test-claude-runtime.ps1` and the installer lifecycle test. Pacer never downloads a runtime at run time.

**Location.** The first time the local Claude module is on, the runtime is deployed to `%LOCALAPPDATA%\CodexPacer\ClaudeRuntime\<version>-<first 12 hex digits of the ZIP SHA-256>\`, shared by every Claude home. Moving the app or using the portable ZIP does not change commands already written. The Codex progress reporter uses the same package under `CodexProgressRuntime`, with its own ownership.
- For Codex, the folder name also carries the first 12 hex digits of the reporter's SHA-256. Store Codex can prefer a private AppData copy at the previous path, so a reporter change needs a new path.
- WorkBuddy trusts a command by its path and arguments, so its reporter lives in the Python-only folder and is replaced in place. Python reads the script and closes it before it runs, so a running reporter doesn't block the replacement. A Pacer update then keeps WorkBuddy's trust; only a new Python pin changes the command.

**Ownership.** The root and each version folder carry a `.pacer-owned.json` marker; an unmarked non-empty folder is never taken over. Files are checked by handle for owner, reparse points and hard links before any write or truncation. The owner must be the current user's SID, or BUILTIN\Administrators only when the token is elevated with that group enabled. Locks are a Windows mutex with a 30-second wait: Codex's and WorkBuddy's reporters prepare the runtime together on the first start after an update, and a setup that still fails is retried every ten minutes.

**Hook command.** Claude Code runs hooks through Git Bash, or PowerShell when Git Bash is missing, so the command is chosen in this order:

1. Unquoted absolute paths (`C:/.../python.exe -S C:/.../pacer/hook.py hook C:/...`) when the paths contain no spaces or shell characters.
2. Otherwise 8.3 short paths, when the volume provides safe ones. Pacer never changes volume settings.
3. Otherwise the system PowerShell (`-File`, found through the system directory, `RemoteSigned` for that process only) with a thin forwarding script. This adds about 150 to 400 ms per hook event, and Settings says so; group policy can still block it.

Old `cmd.exe /D/C` wrappers are migrated, because Git Bash can rewrite `/D` into `D:/`. The user's original status line runs through `CLAUDE_CODE_GIT_BASH_PATH`, then Git for Windows' standard location, then the system PowerShell, never through cmd.exe. It keeps byte-exact stdio and a 10-second timeout.

**Limits.** Local drive paths only. Paths with control characters or any of `` " $ ` % ! ^ & | < > `` are refused; spaces and Chinese are fine. Commands are capped at 7,000 UTF-16 units. The root records at most 128 Claude homes.

**Upgrades and removal.** A new runtime goes to a new folder. Old versions are removed file by file only when no recorded home's settings or saved status line still references them; invalid or unreadable configuration keeps them. App start, the module switch and home changes trigger one asynchronous install or removal with a 5-second deadline and a retry in Claude settings. Turning the module off removes the current home's entries; quitting keeps them. Demo and read-only engines never install hooks. Uninstall is described in [Windows installation](windows-installation.md#uninstall-and-data).

`test-claude-runtime.ps1` uses synthetic stdin, isolated `HOME`, `CLAUDE_CONFIG_DIR` and `LOCALAPPDATA`, and a PATH without Python. It covers each command tier with Bash and PowerShell (timing five hook calls per tier), ownership, concurrency, lock timeouts, privacy, repair, moving the app and cross-home uninstall. CI also runs `check-claude-shell.py` from PowerShell and Git Bash before compiling, because Git Bash gives new files a different default owner. Hooks copied by hand into unrecorded homes are not found, and ARM64 devices are not tested.

## Idle CPU checks

Idle work must be driven by events or deadlines, never by polling. Valid data, deadlines and business refreshes still wake the app; do not disable them to improve an idle number.

| Target | Limit (percent of one core) |
| --- | --- |
| Engine with empty provider homes | ≤ 1 |
| Shell, collapsed, unchanged data | ≤ 1 |
| Shell, expanded, unchanged data | ≤ 2 |
| Shell, hidden or covered by an opaque fullscreen window | ≤ 0.5 |

Engine with empty homes, for at least 120 seconds. CI runs this; it also changes the Codex source and checks a bounded shutdown:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --output output/windows/engine-idle.json
```

Engine against real provider homes, read-only (`--read-only-diagnostics`: no quota clients, browser sessions, hooks or persistence; only numeric counters are recorded):

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --seconds 300 --real-data --output output/windows/engine-real-idle.json
```

The script cannot sign in to Claude on the web, so the WinHTTP paths are covered only by the loopback tests above. A signed-in engine that falls back to URLSession holds about one full core while idle.

Shell, in a screen slot of its own: build `windows/Tests/BackdropTests/Pacer.BackdropTests.csproj` in Release, then run `python scripts/windows/check-shell-idle.py --probe <probe> --output <new folder> --seconds 300 --appearance classic|liquidGlass --snapshot <synthetic snapshot>`, optionally with `--states collapsed expanded hidden covered`. CPU is read only at the start and end. Process CPU excludes DWM and GPU work.

The engine compares snapshots at display precision: clock-derived percents and the wallet hand at 0.1, amounts at 0.01, and a reading's reference time not at all, so a source callback that changes nothing visible sends no frame. Codex Desktop is looked for by checking that its `codex-ipc` pipe exists (without connecting) before any package query or connection; a closed Desktop costs one lookup per discovery tick. Provider installation is detected at most every ten minutes, and at once when settings change.

`QuotaScheduleChecks`, `IdleSchedulingChecks`, `OcclusionPolicyChecks`, `OcclusionSchedulingChecks` and `EngineSnapshotEmissionTests` guard the idle rules in CI. The shell's rules are in [Windows shell development](windows-shell.md#idle-rendering).

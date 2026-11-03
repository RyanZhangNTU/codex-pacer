# Windows shell development

The per-user installer, startup state, maintenance helpers and lifecycle checks are described in [Windows installation](windows-installation.md). The portable ZIP remains available.

Preference keys, edit acknowledgements, migration and protected history storage are described in [Windows preferences and quota history](windows-preferences.md).

Claude and DeepSeek sign in through separate Pacer-owned WebView2 profiles. Before showing the site, the host records the existing session's one-way fingerprint. A changed fingerprint shows confirmation and closes the window after 1.5 seconds. Continue, Ctrl+Enter, Later and the close button also finish while a session is present; an unchanged session retains its history and selected workspace. Browser-process failure cannot complete sign-in. The host checks navigation and a one-second timer only while the window is open; closing stops the observer.

Login revokes old quota reads before the profile can change. Claude clears the saved organization through the normal acknowledged preference transaction only for a new session. DeepSeek passes an optional `webNewSession` flag to the existing shared coordinator; omitted flags retain the older protocol behavior. Credential fingerprints still independently protect billing history. Sign-out cancels reads before clearing the owned profile; a failed clear stays paused. No external browser profile, cookie store or account is imported.

The island's Classic/Liquid Glass preference uses the native Composition material described in [Windows Composition glass](windows-composition-backdrop.md), including fallback, DPI, acceptance captures and performance checks. Its C++ bridge builds with the configured Visual C++ x64 tools and Windows SDK C++/WinRT headers; the DLL is copied and published with the desktop app.

The bridge uses C++20 with MSVC 19.30 or newer. VS 2019 19.29 uses C++17 because that compiler hits an internal error in the SDK's C++20 projection. Both paths keep warnings as errors; newer libraries' rejection of experimental coroutine headers is handled by the standard selection, without suppressing diagnostics.

Idle rendering uses a compositor badge ring, deadline-based quota switching and explicitly released finite animation clocks. Confirmed opaque fullscreen occlusion pauses cosmetic motion through window events. The [Windows idle CPU report](windows-idle-cpu.md) records the five-minute Black/Glass comparisons, engine measurements, rejected samples and remaining limits. This does not implement the pending fullscreen display preference.

The WPF shell renders the shared engine's presentations over protocol version 1. Build it on Windows x64 with the tools pinned in `windows/toolchain-lock.json`; engine setup is described in [windows-engine.md](windows-engine.md).

```powershell
./scripts/windows/build-desktop.ps1 -Configuration Release
./scripts/windows/test-desktop.ps1 -Configuration Release
./scripts/windows/test-presentation.ps1 -Configuration Release
./scripts/windows/package-preview.ps1 -SkipBuild
```

For focused DeepSeek checks, use the `web` and `deepseek` presentation groups once each. They use intercepted pages and isolated synthetic profiles. `DeepSeekOptionPersistenceChecks` also covers 26 schema-2 option writes, fresh stores and independent engine restarts. Production accounts are not needed for these checks.

The unsigned ZIP and SHA-256 file are written under `output/windows`. The `windows-app-x64-unsigned` CI artifact contains both. Packaging validates the extracted application with a restricted runtime environment, Unicode paths, demo capture, and single-instance activation. It does not create a tag or release. The shipping Mac package and release workflow are unchanged.

For local toolchains outside the worktree, set `PACER_SWIFT_ROOT`, `PACER_WINDOWS_SDK_ROOT` and `PACER_DOTNET_ROOT` before running the scripts. They identify existing installations; build outputs, NuGet packages and source snapshots stay under the worktree or its configured temporary directory. Generated UI strings and DeepSeek scripts come from Core resources; `python scripts/windows/build-shell-resources.py --check` checks them.

## Presentation and request handling

Snapshots supply task labels, counts, rates, quota and wallet projections. The additive read-only methods `projectCompactBar` and `layoutQuotaChart` call `CompactBarPresentation` and `QuotaCycleChartPresentation` in Core. WPF handles drawing and input. `PacerWindowsBridge` supplies UI geometry, finite motion and native application activation; it does not calculate quotas, billing or compact component rules.

All engine requests are asynchronous. Ordinary commands have a 15-second deadline; presentation queries have a 3-second deadline. The deadline includes waiting for the write gate, writing the command and receiving its result. The hello handshake has a 10-second deadline. An engine exit fails pending requests. Rendering reads a bounded cache and returns immediately; identical requests share one pending operation. Failed inputs are not retried by repainting. A missing or failed projection shows a loading/error placeholder, and settings edits report failure without saving an incomplete layout.

`SlowEngineChecks` tests silent, slow and exiting engines. It checks dispatcher heartbeats, immediate rendering, visible errors, bounded request counts and rejection of late responses. Pipe readers await input; animation subscriptions end when motion settles. There is no request polling loop.

The island retains a transparent HWND canvas across transitions, so its native rectangle can remain large after the visible panel closes. Its root UIA `ExpandCollapse` pattern reports the logical state and supports reveal/close actions. Input tests should read that state alongside the bounds, rather than infer expansion from the HWND size alone. Hover exit keeps the existing 0.4-second grace period used by the Mac model.

Opaque WPF windows use per-window `HwndTarget.RenderMode = SoftwareOnly`. This covers Settings, login windows and their dialogs, including browser host windows. On the development machine, the default hardware path produced an empty client area in ordinary WPF windows; software rendering restored content and input. The machine has multiple physical and virtual display adapters, but the fault has not been isolated to a driver. The layered Black island keeps its existing rendering mode. This changes WPF client drawing only; it does not change system graphics settings, window materials or WebView2's browser rendering. Settings captures record the actual mode, and presentation tests assert both policies. Software rendering uses CPU for these mostly static windows; measure it with Settings open before extending this policy to animated surfaces.

## System notifications

The Reminders switch opts in to Windows App SDK notifications. The engine uses Core's existing `IslandNotice`, attention, quota and DeepSeek policies, including their baselines, deduplication and warning selection. The shell checks the current Hide Project Names setting when delivering and clears its notification history when that setting changes. OS denial keeps the saved preference and appears in Settings, with an Open Settings button for Windows' notification page. Demo windows never post system notifications.

Activation arguments contain only a fixed action name and a random 128-bit reference. The engine saves at most 128 references for 24 hours, with hashed source and task fingerprints; it saves no labels, paths, URLs, account identifiers or credentials. Issuance and single-use consumption must commit before an action is allowed. A callback waits for initialization, then rechecks the source, account/organization where available, and task family/ending. Historical logs can recover a task action without replaying its completion notice. A second COM process forwards only the bounded reference to the existing marked HWND. Top Up uses a fixed DeepSeek URL; task and Harness opening use the existing validated navigation routes. There is no custom URI protocol.

`NotificationRegistryTests`, `NotificationActionChecks`, `NotificationChecks`, `NotificationActivationWindowChecks` and `ReminderSettingsChecks` cover expiry, replay, source changes, cold initialization, privacy, denied delivery, routing and the settings link. For native checks, first build the desktop, then publish `windows/Tests/NotificationProbe/Pacer.NotificationProbe.csproj` as self-contained. This separate QA identity uses an offline engine and synthetic content. `--native` verifies delivery, its own OS history and cleanup. `--warm all` waits for the five `--invoke-show`, `--invoke-task`, `--invoke-topup`, `--invoke-harness` and `--invoke-snooze` COM callbacks. For each cold action, run `--prepare-cold <action>` to completion, then the matching `--invoke-*` command. Results go to `notification-activation.result.jsonl` beside the probe. `--cleanup` removes only that QA identity's history, registration and reference store, including the SDK's retained path-to-AppId mapping. Close other screen tests before posting visible QA notifications.

Native delivery/history and all five warm and cold COM routes passed on Windows 11 25H2 x64, build 26200.9711, on 2026-11-03. Cold checks registered and invoked the probe from a temporary current-user interactive scheduled task outside Codex's process tree; SCM started the executable with the App SDK activation flag and `-Embedding`. Every route waited for the offline engine and passed its source validation. External application handlers recorded synthetic destinations instead of opening a real account or Harness. QA history, registrations in both observed registry views, processes and temporary tasks were removed.

The earlier cold `0x80040154` was a test-environment issue: a Codex child saw one QA `HKCU\Software\Classes\CLSID\...\LocalServer32` and AppUserModelId, while a same-user, same-session external caller saw neither. Both callers had medium integrity, no restricted SIDs and belonged to a Job; Job membership alone does not explain the difference. Registering and invoking outside Codex succeeded with `0x00000000`. No matching DistributedCOM failure event was found. An Application event from a separate clean-environment check reported the QA probe's missing global .NET 10 runtime; publishing the probe as self-contained fixed that deployment issue. Real notification-banner clicks, real installed task/Harness activation and system notification-setting changes still need user acceptance, so notification preview coverage remains partial.

## Local acceptance

[Windows SSH sources](windows-ssh.md) describes saved-route discovery, owned helpers, the shared SSH setting and terminal navigation. Remote hooks and real remote acceptance are tracked separately.

Use demo data for screenshots and interaction checks:

```powershell
./windows/Desktop/bin/Release/net10.0-windows/CodexPacer.exe --demo --language en --theme light --collapsed
```

`--theme light|dark` is a demo-only override. Repeat with `--language zh-Hans` and dark appearance. Check hover expansion, click to pin, Esc and opening Settings. Use `--demo --reference-fixture --activation-qa <unique-guid>` to isolate activation tests from an existing user instance. Close only the instance started for the check.

The engine can be sampled without opening the shell:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --seconds 300 --real-data --output output/windows/engine-real-idle.json
```

This option reads real sources for at least five minutes, does not change source configuration or record protocol bodies, and reports engine CPU and shutdown time. The default mode uses empty provider homes. CPU results cover the engine process; they do not establish complete feature acceptance. Record manual evidence in `windows/platform-coverage.json` without promoting features whose remaining requirements are untested.

## Codex Remote Control

`monitorRemoteControl` defaults to true, matching the Mac preference. Windows reads the paired-device directory through the shared catalog and projects its names, online state and runtime with the shared Realtime monitor. The authenticated Desktop pipe carries the stream. A saved routing hint alone grants no subscription or navigation.

The catalog keeps bearer credentials inside the read-only RPC/HTTP operation. Its Windows HTTP session has no cookie, credential or response cache, refuses redirects, caps the response at 512 KiB, and limits requests/resources to 8/10 seconds. Initialization owns catalog work separately so a slow directory cannot block the local task source or the 650 ms cleanup budget.

Only a currently verified account and exact device ID can open a Remote Control thread. Account and enrollment changes revoke old pipe proofs and navigation. A hashed account scope separates completion acknowledgments even when two accounts use the same device/thread/turn IDs. A token refresh for the same verified account retains its scope. EOF retains unread endings; failed opens retain unread state and report an error. Retry bypasses transport backoff without replacing a healthy channel.

Development checks use synthetic catalogs, RPC replies and a private named-pipe fixture. They do not send prompts, activate a real provider, or modify real accounts. The Remote Control switch and source rows still need the integration presentation pass and installed-host acceptance.

## WSL sources

Windows discovers installed and running distributions with the documented [WSL list commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands). Automatic probes run only inside distributions already running, as their default Linux user. They read directory metadata; they do not install WSL, Python, a provider, or change a distribution's state or settings. The feature needs an existing `/usr/bin/python3`.

A source binds the distribution, Linux user and UID, canonical home and directory identity. Codex and Claude retain separate roots. Helpers verify that identity before starting, then run the shared Core protocol and parsers. Their program travels through bounded stdin, following the reviewed #157 SSH adapter pattern; Windows command lines stay below the platform limit. Windows credential/environment overrides are removed. A Windows drive or another distribution's UNC path cannot become this source's Linux profile.

Discovery, active helpers and quota reads have owned work slots. Sleep, source changes and switches cancel them; a late scan cannot claim a newer slot. Offline sources keep their identity for unread retention, while directory replacement revokes old navigation and acknowledgments. Each provider has at most eight WSL targets. Integration must combine this target list with #157's SSH list in the shared monitor and preserve a bounded total.

The source's quota action uses read-only Codex RPC or the shared Claude quota client with a bounded, owner-checked Linux file snapshot. It never borrows Windows credentials or writes a credential cache. Credential stamps are checked again before publishing; only formatted quota windows reach the desktop. These on-demand readings stay separate from the selected Windows account's history. Source navigation uses a dedicated console mode and validates the same distribution/user/root before opening the captured session; failure keeps the ending unread.

Development tests use synthetic profiles, private helpers and intercepted transport. Real WSL lifecycle, actual terminal activation and the complete presentation pass belong to integration and preview acceptance.

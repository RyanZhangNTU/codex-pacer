# Windows shell development

The per-user installer, startup state, maintenance helpers and lifecycle checks are described in [Windows installation](windows-installation.md). The portable ZIP remains available.

Preference keys, edit acknowledgements, migration and protected history storage are described in [Windows preferences and quota history](windows-preferences.md).

The update window, verified download and installation handoff are described in [Windows automatic updates](windows-automatic-updates.md).

Claude and DeepSeek sign in through separate Pacer-owned WebView2 profiles. Before showing the site, the host records the existing session's one-way fingerprint. A changed fingerprint shows confirmation and closes the window after 1.5 seconds. Continue, Ctrl+Enter, Later and the close button also finish while a session is present; an unchanged session retains its history and selected workspace. Browser-process failure cannot complete sign-in. The host checks navigation and a one-second timer only while the window is open; closing stops the observer.

Login revokes old quota reads before the profile can change. Claude clears the saved organization through the normal acknowledged preference transaction only for a new session. DeepSeek passes an optional `webNewSession` flag to the existing shared coordinator; omitted flags retain the older protocol behavior. Credential fingerprints still independently protect billing history. Sign-out cancels reads before clearing the owned profile; a failed clear stays paused. No external browser profile, cookie store or account is imported.

The island's Classic/Liquid Glass preference uses the native Composition material described in [Windows Composition glass](windows-composition-backdrop.md), including fallback, DPI, acceptance captures and performance checks. Its C++ bridge builds with the configured Visual C++ x64 tools and Windows SDK C++/WinRT headers; the DLL is copied and published with the desktop app.

The bridge uses C++20 with MSVC 19.30 or newer. VS 2019 19.29 uses C++17 because that compiler hits an internal error in the SDK's C++20 projection. Both paths keep warnings as errors; newer libraries' rejection of experimental coroutine headers is handled by the standard selection, without suppressing diagnostics.

Idle rendering uses a compositor badge ring, deadline-based quota switching and explicitly released finite animation clocks. Confirmed opaque fullscreen occlusion pauses cosmetic motion through window events. The [Windows idle CPU report](windows-idle-cpu.md) records the five-minute Black/Glass comparisons, engine measurements, rejected samples and remaining limits. Fullscreen visibility uses the separate policy described below.

The [display and fullscreen controls](windows-display-fullscreen.md) select a stable Windows monitor identity, retain a disconnected selection and apply the target screen's DPI/work area. The fullscreen switch controls policy hiding or nonactivating display above fullscreen apps. Its checks use synthetic windows and injected topologies, not physical multi-monitor or exclusive-fullscreen setups.

The WPF shell renders the shared engine's presentations over protocol version 1. Build it on Windows x64 with the tools pinned in `windows/toolchain-lock.json`; engine setup is described in [windows-engine.md](windows-engine.md).

```powershell
./scripts/windows/build-desktop.ps1 -Configuration Release
./scripts/windows/test-desktop.ps1 -Configuration Release
./scripts/windows/test-presentation.ps1 -Configuration Release
./scripts/windows/package-preview.ps1 -SkipBuild
```

`-Group` also takes several groups, such as `-Group settings,island`; CI splits the suite this way across three jobs. For focused DeepSeek checks, use the `web` and `deepseek` presentation groups once each. They use intercepted pages and isolated synthetic profiles. `DeepSeekOptionPersistenceChecks` also covers 26 schema-2 option writes, fresh stores and independent engine restarts. Production accounts are not needed for these checks.

The unsigned ZIP and SHA-256 file are written under `output/windows`; the `windows-app-x64-unsigned` and `windows-app-arm64-unsigned` CI artifacts contain them. The Release workflow packages both architectures for a release tag or a manual run; Platforms packages x64 on pull requests that change what the installers are built from or what the package checks start. x64 packaging validates the extracted application with a restricted runtime environment, Unicode paths, demo capture, and single-instance activation; ARM64 only compiles on pull requests and packages without running in the Release workflow. Only a tag run publishes: it signs the Windows feed and publishes the installers with the Mac DMG ([release workflow](releasing.md)).

For local toolchains outside the worktree, set `PACER_SWIFT_ROOT`, `PACER_WINDOWS_SDK_ROOT` and `PACER_DOTNET_ROOT` before running the scripts. They identify existing installations; build outputs, NuGet packages and source snapshots stay under the worktree or its configured temporary directory. Generated UI strings and DeepSeek scripts come from Core resources; `python scripts/windows/build-shell-resources.py --check` checks them.

## Main window

Settings is Pacer's main window, as on the Mac. It opens at 980 by 660, resizes down to 860 by 560, and opens on Overview. Most pages are one centered column of cards, at most 640 wide; Overview and History use 900. Cards follow the Mac's kit: gray section titles, 44-point rows, explanations behind an ⓘ that opens under the row, status rows with a colored dot, outline pickers, and folding rows for custom locations. Spacing, buttons, segments and switches use the Mac's metrics: 22 points between cards and under the title, 24-point buttons in 12-point medium on a translucent fill, the Mac's segmented control, and 38 by 22 switches. Links use the Mac's link blue rather than the accent; on the island's dark cards they keep the dark-mode blue in either theme.

The sidebar has a search field, then Overview and History, then the services (Codex, Claude, DeepSeek, Remote) and the preferences (Appearance, Collapsed Bar, Notifications, General). Help & Updates and Support & Feedback sit in its footer, with Quit, because Windows has no app menu. A service that is turned off shows Off. An amber dot marks Claude, Codex or Remote when it needs the user, using the same rules as Overview's attention card. A found update replaces the installed version under Help & Updates.

- Overview: the attention card, one dark card per service with the island's own quota view, and up to eight task rows. A row opens its task through the island's prepared navigation.
- History: one service's current quota cycle at a time, with chips to switch, and DeepSeek's last seven days.
- Service pages: the module switch sits in the page header, then Status (source, account, a one-line quota summary with a link to History), Display, and folded custom locations. Remote Control moved to Remote, and the quota trend to History.
- Remote: the overall state is the subtitle, then SSH hosts, Codex Remote Control, WSL (Windows only) and other task sources.
- Appearance: Theme (Auto, Light, Dark), Material (Classic or Liquid Glass), Accent (Multicolor and eight colors, as in System Settings), then Position, whose Island and Free Move cards play the welcome guide's scenes, and the expanded panel. The theme applies to the main and guide windows; the island stays dark. Multicolor follows the Windows accent, except in synthetic previews and checks, which keep the classic blue. A single accent tints buttons, switches and selections and turns Codex, Claude and DeepSeek into three shades of it. Theme, Material and Position are picture choices drawn as on the Mac; Return to Top Center is unavailable while the island already sits there. The settings save as `appTheme` and `accentColor`, the Mac's keys.
- Collapsed Bar: Restore Defaults at the header's end, then the bar itself on a desktop picture, drawn with the island's own components and live values, as on the Mac. A click selects a component, a drag moves it within its side or to the other side, arrow keys reorder it, Delete removes it, and its menu offers the same moves. A component with nothing to show right now keeps its place as a faint label. Below it come the component library by group, where a tile adds or removes a component, and an inspector for the selected one with its explanation, Add or Remove, and its options. The quota windows follow every component that shows a quota.
- Notifications: each event shows where it reminds you, in the collapsed bar and in system notifications. System notifications still follow their one switch, so that column only shows the result.
- Help & Updates: the version card with one action (Check for Updates, or Update and Restart, which downloads with its progress in the card), the last check time when idle and Download from GitHub after a failure, then What's New and Help as tabs. Overview's update banner installs in place too, offers the notes, and remembers a closed version across launches (`PacerUpdateBannerDismissed`, beside the updater's other state).

Search matches page titles and the shared `main.search.*` words, and lists only pages that can open. Return opens the first match, and Escape clears the query before it can close the window. The page id is stored in `settingsPane`, and an unknown value opens Overview. Older values open where their content moved: `reminders` opens Notifications, `connections` opens Remote, and `whatsNew` or `help` opens the matching tab of Help & Updates. Windows has no Dock, so the Mac's Dock icon choice has no Windows counterpart.

The What's New window follows the main window too: the icon over one large centered title, each highlight as a feature row with its setting in place, then one wide Continue and a Release Notes link.

## Presentation and request handling

Snapshots supply task labels, counts, rates, quota and wallet projections. The additive read-only methods `projectCompactBar` and `layoutQuotaChart` call `CompactBarPresentation` and `QuotaCycleChartPresentation` in Core. WPF handles drawing and input. `PacerWindowsBridge` supplies UI geometry, finite motion and native application activation; it does not calculate quotas, billing or compact component rules.

All engine requests are asynchronous. Ordinary commands have a 15-second deadline; presentation queries have a 3-second deadline. The deadline includes waiting for the write gate, writing the command and receiving its result. The hello handshake has a 10-second deadline. An engine exit fails pending requests. Rendering reads a bounded cache and returns immediately; identical requests share one pending operation. Failed inputs are not retried by repainting. A missing or failed projection shows a loading/error placeholder, and settings edits report failure without saving an incomplete layout.

`SlowEngineChecks` tests silent, slow and exiting engines. It checks dispatcher heartbeats, immediate rendering, visible errors, bounded request counts and rejection of late responses. Pipe readers await input; animation subscriptions end when motion settles. There is no request polling loop.

## Embedded sessions and host applications

Codex and Claude each have a “sessions from other apps” switch, enabled by default. Schema 2 stores them with the Mac keys `showEmbeddedCodexSessions` and `showEmbeddedClaudeSessions`; older profiles keep their saved Codex choice and default Claude to visible. Turning one off hides that provider's embedded families, retained completion cards, requests and reminders. Collection continues, and hidden endings remain unread. A later CLI launch record makes the family visible again. Provider and source identities keep unrelated sessions separate; Zotero translation sessions remain excluded.

Windows uses the shared host tracking policy for caching, two-second scan throttling, sleep cancellation and wake retries. A bounded native process snapshot supplies parent links; every candidate is checked against its PID and creation time. The cache records the observed application's name and executable file identity while its task or completion card remains referenced.

Opening a card first uses its current verified host. If that host has exited, the engine can restart the captured executable or packaged application after checking its file identity, size and modification time again. It passes no transcript arguments or prompt. Executable paths and package launch identities stay inside the engine; WPF receives a one-use navigation context. An unknown or replaced application, a failed launch, sleep or a source change leaves the ending unread.

### Claude Desktop data folder

A Claude task without a live host opens through Desktop's `claude://code/continue` link only when the active Desktop account's `local_UUID` metadata maps it. The same folder supplies the Desktop account check, the SSH/WSL mirror exclusion and Desktop's `ssh_configs.json`.

Desktop 4.23118 moved this data out of its MSIX package to `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc`, named for the package family. When that folder has a `config.json`, it is the only folder read. Older builds use `%APPDATA%\Claude` or the package's `LocalCache\Roaming\Claude` and `RoamingState\Claude`. The engine skips any of those that contain Desktop's `.user-data-left.claude_pzs8sxrjxfjjc` marker, so leftover files from another account cannot disable every mapping. Without a verified mapping, the card falls back to its host or reports that the starting app is unknown.

The island retains a transparent HWND canvas across transitions, so its native rectangle can remain large after the visible panel closes. Its root UIA `ExpandCollapse` pattern reports the logical state and supports reveal/close actions. Input tests should read that state alongside the bounds, rather than infer expansion from the HWND size alone. Hover exit keeps the existing 0.4-second grace period used by the Mac model.

Opaque WPF windows use per-window `HwndTarget.RenderMode = SoftwareOnly`. This covers Settings, login windows and their dialogs, including browser host windows. On the development machine, the default hardware path produced an empty client area in ordinary WPF windows; software rendering restored content and input. The machine has multiple physical and virtual display adapters, but the fault has not been isolated to a driver. The layered Black island keeps its existing rendering mode. This changes WPF client drawing only; it does not change system graphics settings, window materials or WebView2's browser rendering. Settings captures record the actual mode, and presentation tests assert both policies. Software rendering uses CPU for these mostly static windows; measure it with Settings open before extending this policy to animated surfaces.

## System notifications

The Reminders switch opts in to Windows App SDK notifications. The engine uses Core's existing `IslandNotice`, attention, quota and DeepSeek policies, including their baselines, deduplication and warning selection. The shell checks the current Hide Project Names setting when delivering and clears its notification history when that setting changes. OS denial keeps the saved preference and appears in Settings, with an Open Settings button for Windows' notification page. Demo windows never post system notifications.

Activation arguments contain only a fixed action name and a random 128-bit reference. The engine saves at most 128 references for 24 hours, with hashed source and task fingerprints; it saves no labels, paths, URLs, account identifiers or credentials. Issuance and single-use consumption must commit before an action is allowed. A callback waits for initialization, then rechecks the source, account/organization where available, and task family/ending. Historical logs can recover a task action without replaying its completion notice. A second COM process forwards only the bounded reference to the existing marked HWND. Top Up uses a fixed DeepSeek URL; task and Harness opening use the existing validated navigation routes. There is no custom URI protocol.

`NotificationRegistryTests`, `NotificationActionChecks`, `NotificationChecks`, `NotificationActivationWindowChecks` and `ReminderSettingsChecks` cover expiry, replay, source changes, cold initialization, privacy, denied delivery, routing and the settings link. For native checks, first build the desktop, then publish `windows/Tests/NotificationProbe/Pacer.NotificationProbe.csproj` as self-contained. This separate QA identity uses an offline engine and synthetic content. `--native` verifies delivery, its own OS history and cleanup. `--warm all` waits for the five `--invoke-show`, `--invoke-task`, `--invoke-topup`, `--invoke-harness` and `--invoke-snooze` COM callbacks. For each cold action, run `--prepare-cold <action>` to completion, then the matching `--invoke-*` command. Results go to `notification-activation.result.jsonl` beside the probe. `--cleanup` removes only that QA identity's history, registration and reference store, including the SDK's retained path-to-AppId mapping. Close other screen tests before posting visible QA notifications.

Register and invoke cold checks as the interactive user outside an agent's sandboxed process tree, for example from a temporary current-user scheduled task. Inside Codex's process tree HKCU is isolated, so a probe registered there cannot be cold-activated (`0x80040154`). Real notification-banner clicks and system notification-setting changes are not automated.

## Local checks

Welcome, What's New, Help and Support behavior and validation are described in [Windows guide pages](windows-guide-pages.md). Use `--welcome` or `--whats-new` with a demo instance for synthetic checks; demo runs never record either page as seen.

[Windows SSH sources](windows-ssh.md) describes saved-route discovery, owned helpers, the shared SSH setting and terminal navigation. SSH and WSL share remote hook setup; see [WSL sources](#wsl-sources).

Use demo data for screenshots and interaction checks:

```powershell
./windows/Desktop/bin/Release/net10.0-windows/CodexPacer.exe --demo --language en --theme light --collapsed
```

`--theme light|dark` is a demo-only override. Repeat with `--language zh-Hans` and dark appearance. Check hover expansion, click to pin, Esc and opening Settings. Use `--demo --reference-fixture --activation-qa <unique-guid>` to isolate activation tests from an existing user instance. Close only the instance started for the check.

The engine can be sampled without opening the shell:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --seconds 300 --real-data --output output/windows/engine-real-idle.json
```

This option reads real sources for at least five minutes, does not change source configuration or record protocol bodies, and reports engine CPU and shutdown time. The default mode uses empty provider homes. CPU results cover the engine process only.

## Codex Remote Control

`monitorRemoteControl` defaults to true, matching the Mac preference. Windows reads the paired-device directory through the shared catalog and projects its names, online state and runtime with the shared Realtime monitor. The authenticated Desktop pipe carries the stream. A saved routing hint alone grants no subscription or navigation.

The catalog keeps bearer credentials inside the read-only RPC/HTTP operation. Its Windows HTTP session has no cookie, credential or response cache, refuses redirects, caps the response at 512 KiB, and limits requests/resources to 8/10 seconds. Initialization owns catalog work separately so a slow directory cannot block the local task source or the 650 ms cleanup budget.

Only a currently verified account and exact device ID can open a Remote Control thread. Account and enrollment changes revoke old pipe proofs and navigation. A hashed account scope separates completion acknowledgments even when two accounts use the same device/thread/turn IDs. A token refresh for the same verified account retains its scope. EOF retains unread endings; failed opens retain unread state and report an error. Retry bypasses transport backoff without replacing a healthy channel.

Development checks use synthetic catalogs, RPC replies and a private named-pipe fixture. They do not send prompts, activate a real provider, or modify real accounts.

## WSL sources

Windows discovers installed and running distributions with the documented [WSL list commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands). Automatic probes run only inside distributions already running, as their default Linux user. They read directory metadata; they do not install WSL, Python, a provider, or change a distribution's state or settings. The feature needs an existing `/usr/bin/python3`.

A source binds the distribution, Linux user and UID, canonical home and directory identity. Codex and Claude retain separate roots. Helpers verify that identity before starting, then run the shared Core protocol and parsers. Their program travels through bounded stdin, following the reviewed #157 SSH adapter pattern; Windows command lines stay below the platform limit. Windows credential/environment overrides are removed. A Windows drive or another distribution's UNC path cannot become this source's Linux profile.

Discovery, active helpers and quota reads have owned work slots. Sleep, source changes and switches cancel them; a late scan cannot claim a newer slot. Offline sources keep their identity for unread retention, while directory replacement revokes old navigation and acknowledgments. Each provider shares one monitor for up to eight SSH and eight WSL targets.

Claude hooks on SSH and WSL use the same installer, digest cache and scheduler. Successful setup is reused until the adapter changes; failures wait 30 minutes or a manual retry. WSL verifies the Linux source before setup and discards results after that source is revoked. Its Linux supervisor terminates the owned installer when stdin closes, without stopping the distribution. Tests cover both transports, retry timing, version changes and late results after root replacement.

The source's quota action uses read-only Codex RPC or the shared Claude quota client with a bounded, owner-checked Linux file snapshot. It never borrows Windows credentials or writes a credential cache. Credential stamps are checked again before publishing; only formatted quota windows reach the desktop. These on-demand readings stay separate from the selected Windows account's history. Source navigation uses a dedicated console mode and validates the same distribution/user/root before opening the captured session; failure keeps the ending unread.

Development tests use synthetic profiles, private helpers and intercepted transport; they do not exercise a real WSL lifecycle or terminal activation.

## Connections page

The Windows page consumes `ConnectionPagePresentation`, which combines Core's `ConnectionSource`, `SSHHost` and `ConnectionSummary`. It shows local collectors, Cloud Projects and Remote Control, then SSH and WSL hosts with Codex and Claude side by side. Problems come first within those groups. Session counts exclude a Claude source whose hooks are still being configured or have failed.

The page exposes the existing SSH and Remote Control preferences and the Windows WSL preference. A task-source retry clears backoff for inactive helpers, retries failed Claude setup and refreshes discovery without restarting healthy subscriptions. Quota and balance requests have their own actions. WSL quota reads remain bound to the selected Linux source; local quota rows use the existing shared freshness and error projections.

SSH and WSL setup buttons use the same source/context pair. Removing a source, disabling it or replacing its identity invalidates an old button. The desktop also rejects a duplicate retry while setup is in flight. Synthetic Swift and headless desktop tests cover grouping, counts, source switches, retry ownership and protocol compatibility. They access no real provider account.

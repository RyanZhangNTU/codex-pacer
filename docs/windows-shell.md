# Windows shell development

The WPF shell (`windows/Desktop`) draws the shared engine's presentations over protocol version 1 and handles input, windows and Windows integration. It does not calculate quotas, billing or collapsed-bar rules: those come from Core through the engine. The engine is described in [Windows engine development](windows-engine.md), the installer in [Windows installation](windows-installation.md), the updater in [Windows automatic updates](windows-automatic-updates.md). Behavior shared with the Mac is in [development](development.md).

## Build and test

Build on Windows x64 with the tools pinned in `windows/toolchain-lock.json` (setup is in [the engine guide](windows-engine.md#build-and-test)).

```powershell
./scripts/windows/build-desktop.ps1 -Configuration Release
./scripts/windows/test-desktop.ps1 -Configuration Release
./scripts/windows/test-presentation.ps1 -Configuration Release            # -Group settings,island for a subset
./scripts/windows/test-claude-runtime.ps1
./scripts/windows/package-preview.ps1 -SkipBuild
python scripts/windows/build-localization.py --check
python scripts/windows/build-shell-resources.py --check
```

- `test-presentation.ps1 -Group` takes one or more groups. `all` runs the groups in `AllGroups` (`windows/Tests/PresentationTests/Program.cs`); CI splits them across three jobs, and the platform contract checks that each group sits in exactly one job. Add a new group to both places.
- Groups outside `all` run only when named: `deepseek`, `displaySettings`, `persistence`, `position`, `progress`, `quotaIdle` and `ssh`. `position` moves the real pointer and restores it afterwards.
- Screen tests use offline engines and synthetic data, never real accounts. Close other screen tests first; captures go to the ignored `output/windows` and are not committed.
- `package-preview.ps1` writes the unsigned ZIP and its SHA-256 under `output/windows` and, unless `-BuildOnly`, checks the extracted app with a restricted environment, Unicode paths, a demo capture and single-instance activation. The portable ZIP is for development only; keep the whole folder (Engine, Maintenance, resources and runtimes) together.
- Which CI jobs run on a pull request is described in [continuous integration](development.md#continuous-integration); packaging and publishing a release in [the release workflow](releasing.md). ARM64 is compiled and packaged in CI but never run.

The Composition bridge (`windows/Native/CompositionBackdrop`) builds with the Visual C++ x64 tools and the Windows SDK's C++/WinRT headers, as C++20 on MSVC 19.30 or newer and as C++17 on VS 2019 (19.29 hits an internal compiler error in the SDK's C++20 projection). Warnings stay errors in both modes. Its DLL is published with the desktop app.

## Strings and resources

- Shared UI strings come from Core's `Localizable.strings`. Windows-only strings use `windows.*` keys in `windows/EngineSupport/Resources/Localization/<language>.json` and cannot override a shared key.
- `build-localization.py` merges both into `Localization/Catalogs`; `build-shell-resources.py` copies the catalogs and Core's DeepSeek scripts into `windows/Desktop/Assets`. Run each without `--check` to regenerate. English and Chinese must have the same keys and format arguments.

## Demo and manual checks

```powershell
./windows/Desktop/bin/Release/net10.0-windows/CodexPacer.exe --demo --language en --theme light --collapsed
```

- Repeat with `--language zh-Hans` and `--theme dark` (a demo-only override). Check hover expansion, click to pin, Esc and opening Settings.
- `--demo --reference-fixture --activation-qa <unique-guid>` isolates a run from an existing instance. Close only the instance you started.
- `--demo-preferences <absolute path>` (with `--reference-fixture` and a preview capture or an `--activation-qa` scope) keeps a synthetic preference file across demo launches; the production path is refused.
- `--welcome` and `--whats-new` force those windows; demo runs never record them as seen. Demo never posts system notifications or touches production storage.

## Engine requests

- Every request is asynchronous. Commands have a 15-second deadline, presentation queries 3 seconds and the hello handshake 10 seconds; the deadline includes waiting for the write gate.
- Rendering reads a bounded cache and returns at once; identical requests share one pending operation; there is no polling loop. A missing projection shows a placeholder, and a failed settings edit saves nothing.
- An engine exit fails pending requests. If the engine stops after running at least 10 minutes, Pacer restarts itself, unless an update is in progress. An engine that stops sooner keeps the stopped status, so a startup failure cannot loop.
- Collapsed-bar and quota-chart drawing come from `projectCompactBar` and `layoutQuotaChart` (Core's `CompactBarPresentation` and `QuotaCycleChartPresentation`). `PacerWindowsBridge` supplies only geometry, finite motion and native activation.
- The expanded panel's layout and choices reach the engine in `configure` (`expandedPanel`: layout, options and whether DeepSeek's former content was Detailed). Each snapshot carries `expandedPanel`: the resolved sections with each quota section's drawing in both styles, every ring's window and the choices after fallback, so a style change needs no new snapshot. The Expanded Panel page edits blocks through `projectExpandedPanel` (Core's `ExpandedPanelPresentation`) and saves the layout it returns.
- `SlowEngineChecks` covers silent, slow and exiting engines.

## Main window

Settings is the main window, as on the Mac. Windows-specific points:

- It opens at 980 × 660 and resizes down to 860 × 560. Help & Updates, Support & Feedback and Quit sit in the sidebar footer, because Windows has no app menu. There is no Dock icon setting.
- The Remote page also lists WSL. Every collapsed-bar size is offered, since there is no camera housing to match.
- Multicolor follows the Windows accent color; synthetic previews and checks keep the classic blue. The theme applies to the main and guide windows only.
- The open page is saved in `settingsPane`. An unknown value opens Overview; old values open where their content moved: `reminders` opens Notifications, `connections` opens Remote, and `whatsNew` or `help` opens that tab of Help & Updates.
- Search matches page titles and the shared `main.search.*` words. Return opens the first match; Escape clears the query before it closes the window.
- The update banner remembers a closed version in `PacerUpdateBannerDismissed`, in the updater's state file.

Opaque WPF windows (Settings, sign-in windows, dialogs and non-layered popups) use `RenderMode.SoftwareOnly`, because hardware rendering showed an empty client area on a machine with several physical and virtual display adapters. The layered island keeps hardware rendering. This costs CPU only for mostly static windows; measure before extending it to animated surfaces.

## Island

- The island keeps one transparent HWND canvas across transitions, so its window can stay large after the panel closes. Its root UIA `ExpandCollapse` pattern reports the logical state; input tests should read that, not infer it from the window size. Hover exit keeps the Mac's 0.4-second grace period.
- When a dragged island opens, the panel picks a direction and anchor from the free space, slides inward to fit the work area, and keeps that direction until it closes or the placement changes.
- Task status icons are drawn as on the Mac (`TaskStatusIcon`, `TaskProgressRing`, `TaskGlyphArt`). Their loops run on a shared clock through leased WPF clocks, so a rebuilt row continues in step and a removed row stops its clocks.

### Idle rendering

- The collapsed badge ring is drawn by Windows.UI.Composition in a small non-activating HWND, not by a forever-running WPF animation. Without the compositor it falls back to a 30 fps WPF rotation and retries after display or compositor notifications.
- Quota rotation uses a one-shot timer to the next switch deadline (four-second slots, 350 ms fade); a late wake jumps to the current phase.
- Finite animations hold controllable clocks and stop them explicitly when they finish, are replaced or unload. Production code never forces garbage collection.
- When an opaque fullscreen window fully covers the island, cosmetic motion pauses. Detection is driven by WinEvents with a 250 ms trailing throttle; nothing runs without events. Layered and `WS_EX_NOREDIRECTIONBITMAP` windows never count as covering, because their transparency cannot be proven.
- The engine publishes a snapshot only when its encoded state changed, ignoring only the sequence number and capture times.

Targets and measurement commands are in [idle CPU checks](windows-engine.md#idle-cpu-checks).

## Glass and Composition backdrop

`islandAppearance` uses the Mac values `classic` (Black), `liquidGlass`, `liquidGlassLight` and `graphite`. A missing or unknown value means `liquidGlass`. A change saves at once without restarting the engine or collectors.

- Glass is a native Composition backdrop HWND (`WS_EX_NOREDIRECTIONBITMAP`, `WS_EX_NOACTIVATE`, tool window) directly below the layered WPF content HWND. It uses `CreateHostBackdropBrush()` with an 18 DIP blur, a dark tint at 0.72 opacity (the host backdrop lacks the Mac material's dark base, so light text needs it) and a noise texture generated once.
- Light glass is the same material with a near-white wash (`pacer_surface_tone`, opacity 0.78) and turns the whole island light; without native support it falls back to an opaque light surface. Switching between dark and light glass rebuilds the backdrop. Graphite is drawn by the island and loads no backdrop.
- Both HWNDs use the same outline, device-pixel origin and DPI, and both get the same native window region. The region is required: WPF's layered bitmap commits later than the backdrop, so without it text briefly drew outside the glass.
- The backdrop takes no input, is hidden from UI Automation and the taskbar, and clicks never activate the island.
- Glass falls back to Black, keeping the saved choice, when the build is below 22621 (the DLL is not even loaded), transparency effects are off, high contrast is on, creation fails or the graphics device is lost (a D3D11 event). It is rebuilt when settings recover, after display or DWM change messages, or when the user picks Classic and then Liquid Glass. Nothing polls.

Checks, after building the desktop and in a screen slot of their own (pixel checks need Pillow and NumPy):

```powershell
./scripts/windows/test-backdrop.ps1 -Mode overlay   # also input, cpu, motion, interactive
```

Each run needs a fresh output folder (default `output/windows/backdrop/<id>/`) and refuses to start while another Pacer screen test runs. An unavailable native backdrop fails the run instead of passing Black as glass. `interactive` keeps the window for up to 180 seconds; create a `finish` file in its output folder to end it early. Not automated: real changes of system settings, several monitors or mixed DPI, Narrator, recovery after sleep, lock, Remote Desktop or a GPU switch, and other GPUs.

## Accessibility and reduced motion

- The collapsed bar's main button works through UIA and the keyboard: Space runs the main action, Alt+Left and Alt+Right change pages (WPF reports these as `Key.System`, so read `SystemKey`), Esc collapses. Text fields keep their own arrow keys.
- A page that fades out leaves the automation tree at once and disables hit testing, focus and its old peers. Hiding the island closes its menus.
- `SystemAppearanceSource` reads light or dark mode, client animations, high contrast and transparency from system events and publishes immutable snapshots on the window's dispatcher. It never polls and never saves these values.
- High contrast uses the system's semantic colors and keeps the area outside the island's outline transparent. Transparency off or high contrast disables glass but keeps the saved material.
- Reduced motion stops window, page, hover, dimming, quota-rotation and badge animations at once; reversed or repeated input keeps the last target.
- Compact values scale their full text and never add an ellipsis.
- Known difference kept by decision: badge curves are linear on Windows, cubic or spring on the Mac.

The `accessibility` group checks UIA names, roles and actions and the keys above in both languages, with injected system snapshots. `Pacer.PresentationTests --unit-only` runs the windowless checks. Not covered: Narrator speech, real system broadcasts, other monitors and scales, other high-contrast themes and IME focus.

## Displays and fullscreen

- The picker offers Main Display and each monitor. `displayID` stores the monitor's device-interface path (from [`EnumDisplayDevicesW`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaydevicesw)), never the unstable `DISPLAY1`/`DISPLAY2` names. A unique name and position is the fallback; an ambiguous match uses the main display.
- If the chosen monitor disconnects, the island moves to the main display while Settings keeps and explains the choice; it returns on reconnect. If enumeration fails, the window's current screen is used and the preference is kept.
- Windows use the DPI of the screen they are on and jump directly across screens or DPI changes instead of animating. Topology, work-area and DPI changes arrive through events and are handled while hidden too; the app is PerMonitorV2.
- While dragging, the pointer's physical position picks the screen and an edge outline previews the snap. Position and display are saved only on release.
- With **Show above fullscreen apps** off (`showInFullscreen`, default off), the island hides while a fullscreen app covers its screen and returns afterwards; only policy hiding is undone. With it on, the island is raised with `SetWindowPos` and `SWP_NOACTIVATE`, never activated. Detection shares the occlusion observer and excludes minimized, other-desktop, desktop, taskbar, layered, tool and Pacer windows. A maximized window with a title bar is not fullscreen.

Checks: `-Group display` (synthetic fullscreen windows and injected two-screen topologies on one real screen), `-Group displaySettings` and `-Group position`. Not covered: real multi-monitor connection changes, mixed DPI, taskbar positions, exclusive or cross-screen fullscreen apps. Two identical monitors that swap places and change interface paths cannot be told apart; the user picks again.

## Welcome, What's New, Help and Support

- Content comes from Core (`WhatsNew.releases`, `WelcomeGuide.currentMajor`, `ProjectSupport`) through the engine's read-only `guidePages` query, which also returns the version records. Selection rules are the Mac's.
- Welcome shows on first launch or a new major version and records `welcomeGuideVersion` on close. What's New shows unseen entries within a major version and records `whatsNewVersion`. Running an older version never lowers a record.
- Demo and `--settings` launches never open these windows on their own. Records use the normal preference transaction; a failed save keeps the old record, and an unreadable production file is never overwritten.
- The pages make no network requests. QR codes are bundled images; the share sheet and Copy pass only the fixed public project link or the QQ group number; HTTPS links open in the default browser. Help and Support navigation is not saved.

The `pages` group covers both languages and themes with injected browser and clipboard services. Not covered: the system share sheet, scanning a QR code and real sign-in.

## Preferences file

Preferences live in `%LOCALAPPDATA%\CodexPacer\preferences-v1.json`; keep the file name across upgrades. Schema 2, used by every released build since 4.2.2, stores the Mac UserDefaults keys. Schema 1 (development previews only) migrates on the next successful edit. Loading never rewrites the file, and unknown root keys survive edits.

| Choices | Keys | Default when missing |
| --- | --- | --- |
| Language | `appLanguage` | `system` |
| Window theme and accent | `appTheme`, `accentColor` | `auto`, `multicolor` |
| Position | `islandPlacement`, `islandDisplayMode`; legacy `islandPosition`, `floatingIsland` | no explicit position, `automatic` |
| Display and fullscreen | `displayID`, `displayName`, `displayX`, `displayY`, `showInFullscreen` | Main Display, off |
| Place per display | `islandPositionPerDisplay`, `islandDisplayPlaces` | on, none saved |
| Surface | `islandAppearance`, `expandedQuotaStyle` | `liquidGlass`, `split` |
| Collapsed bar | `compactIslandLayout`, `compactComponentOptions`, `compactBarSize`, `compactSingleTask`, `compactMetric` | Core's defaults, `standard`, `stage`, `remaining` |
| Expanded panel | `expandedPanelLayout`, `expandedPanelOptions` | automatic layout, Core's defaults |
| Quota windows and rings | `quotaWindowID`, `claudeQuotaWindowID`, `quotaRingOuter`, `quotaRingInner` | `auto`, automatic rings |
| DeepSeek | `deepseekPanelStyle`, `deepseekMode`, `deepseekBalanceSource`, `deepseekDailyBudget`, `deepseekWeeklyBudget`, `deepseekRingPeriod`, `deepseekSpeedSource`, `deepseekShowsTurnCost`, `deepseekLowBalanceLine`, `deepseekSpikeLimit` | `detailed`, `balance`, `automatic`, no amounts, `day`, `local`, turn cost on |
| Task progress rings | `codexProgressRing`, `claudeProgressRing`, `deepseekProgressRing` | on |
| Privacy and visible tasks | `hideProjects`, `showAppButtons`, `showEmbeddedCodexSessions`, `showEmbeddedClaudeSessions`, `showClaudeCloudProjects` | off, then on |
| Remote sources | `monitorSSH`, `monitorRemoteControl`, `monitorWSL` (Windows only) | on |
| Retention and page | `completedRetentionMinutes`, `settingsPane` | `30`, `overview` |
| Source overrides | `codexExecutable`, `codexHome`, `claudeHome`, `deepseekHome`, `claudeWebOrganizationID` | empty |
| Modules | `providerModule.codex`, `providerModule.claude`, `providerModule.deepseek` | `automatic` |
| Notifications and updates | `systemNotifications`, `SUEnableAutomaticChecks` | off, on |
| Welcome and What's New | `welcomeGuideVersion`, `whatsNewVersion` | `0`, unset |

Encoding rules:

- `compactIslandLayout`, `compactComponentOptions`, `expandedPanelLayout`, `expandedPanelOptions` and `islandDisplayPlaces` hold the Mac's UTF-8 JSON Data as base64. The compact layout carries the warnings. Damaged component options, panel data or places read as defaults (the panel as its automatic layout) without touching other settings; an explicit empty compact layout stays empty.
- A present but empty or unknown ring value means no ring; an absent key means automatic.
- `settingsPane` stores the desktop's `collapsed` page as the Mac value `collapsedBar`; the Expanded Panel page is `expandedPanel` on both.
- `islandPlacement` holds `edge` (`Free`, `Top`, `Bottom`, `Left`, `Right`) and the collapsed bar's center as work-area fractions `x` and `y`; a docked edge fixes the coordinate across it. Notch mode keeps the last free placement. A move to another monitor saves placement and display in one edit; while a disconnected display falls back to the main one, a move saves only the placement.
- `displayID` absent, null, empty, `0` or `"0"` means Main Display; anything else is a Windows device-interface path (the Mac's numeric IDs mean nothing here). A monitor without a device path is saved as `displaySelection: "specified"` with its name and position. Legacy `displaySelection` values `automatic` and `primary` both mean Main Display and survive unrelated edits.
- Open at Login is an OS registration, not a preference. Credentials and browser sessions live in their own stores.

Writes:

- Every edit first waits for the engine's `validatePreferences` (3 seconds), which returns a SHA-256 acknowledgement of the whole payload and no paths or organization IDs. Edits that change collectors also wait for `configure` (15 seconds). A failed write restores the last acknowledged fields and collector configuration, and offers a restart if that rollback fails. WPF never recalculates budgets, billing, thresholds or day and week boundaries.
- Edits from all windows are serialized and written off the UI thread under a named mutex (1-second wait). The file must still match the version the session loaded, so a stale writer fails instead of overwriting another process.
- The file is limited to 60 KiB, written to a flushed temporary file and atomically replaced. Redirected paths are refused.
- A malformed file is renamed to `<original>.damaged-<UTC timestamp>` (at most three backups per file) and the app starts from defaults, telling the user once with only the backup's name. A file from a newer schema is never overwritten by ordinary edits; Settings offers **Back Up and Use Defaults**.

## Quota history storage

- Codex and Claude keep Core's `QuotaCycleCache` format, home-path hash, account-scope checks and separate provider folders. Windows supplies bounded reads and atomic replacement through `PlatformFileSystem`. Writing still coalesces over 30 minutes, writes at once on context changes, flushes at shutdown and keeps seven days.
- DeepSeek keeps `DeepSeekBalanceHistory`: eight days, bound to the billing source and credential fingerprint (changing the log home does not split it), version-1 format, 64 KiB, local credential salt.
- Damaged or oversized history and completion-acknowledgement files are quarantined with the preference backup rule and rebuilt empty. A valid cache for another account is not damage. `storageRecoveryStatus` reports only counts per store.
- A failed history write keeps live readings; Codex and Claude show a cache-write warning. Files from a newer version stay untouched until the user backs them up from Settings. Read-only diagnostics refuse that action, and maintenance only inspects.

`PreferencesPersistenceChecks`, `DisplaySelectionChecks`, `PersistentSettingsChecks`, `PreferencesResponsivenessChecks` and `WindowsHistoryPersistenceTests` cover saving every field through a real offline engine, reading it back in a new process, migration, independent writers and damaged or future files.

## Web sign-in

- Claude and DeepSeek sign in through separate Pacer-owned WebView2 profiles. No external browser profile, cookie store or account is imported.
- Before showing the site, the host records the current session's one-way fingerprint. A changed fingerprint confirms sign-in and closes the window after 1.5 seconds; an unchanged session keeps its history and workspace. A browser-process failure never completes sign-in. Navigation and a one-second timer are watched only while the window is open.
- A new session revokes old quota reads before the profile can change. Claude clears the saved organization only for a new session. DeepSeek passes an optional `webNewSession` flag; omitting it keeps the older protocol behavior.
- Sign-out cancels reads before clearing the owned profile; a failed clear stays paused.
- The `web` and `deepseek` presentation groups and `DeepSeekOptionPersistenceChecks` use intercepted pages and synthetic profiles.

## System notifications

The system notifications switch (`systemNotifications`, off by default) uses Windows App SDK notifications driven by Core's existing notice, attention, quota and DeepSeek policies. The current Hide Project Names setting applies at delivery, and changing it clears Pacer's notification history. If Windows denies notifications, the saved choice stays and Settings offers Open Settings.

Activation privacy rules:

- Arguments contain only a fixed action name and a random 128-bit reference. The engine keeps at most 128 references for 24 hours with hashed source and task fingerprints; no labels, paths, URLs, account identifiers or credentials.
- A reference is issued and consumed once, both committed before the action runs. The callback waits for initialization and rechecks the source, account or organization and task.
- A second COM process forwards only the reference to the running app. Top Up opens a fixed DeepSeek URL; task and Harness actions use the validated navigation routes. There is no custom URI protocol.

`NotificationRegistryTests`, `NotificationActionChecks`, `NotificationChecks`, `NotificationActivationWindowChecks` and `ReminderSettingsChecks` run in CI. For native checks, build the desktop, then publish `windows/Tests/NotificationProbe/Pacer.NotificationProbe.csproj` self-contained. The probe has its own QA identity, offline engine and synthetic content:

- `--native` checks delivery, its own history and cleanup.
- `--warm all` waits for the `--invoke-show`, `--invoke-task`, `--invoke-topup`, `--invoke-harness` and `--invoke-snooze` callbacks.
- For a cold action, run `--prepare-cold <action>` to completion, then the matching `--invoke-*`. Results go to `notification-activation.result.jsonl` beside the probe.
- `--cleanup` removes only the probe's history, registration, reference store and the SDK's path-to-AppId mapping.

Run cold checks as the interactive user outside an agent's sandboxed process tree, for example from a temporary current-user scheduled task: inside Codex's process tree HKCU is isolated and cold activation fails with `0x80040154`. Clicking real banners and changing system notification settings are not automated.

## Embedded sessions and host applications

- Codex and Claude each have a "sessions from other apps" switch (`showEmbeddedCodexSessions`, `showEmbeddedClaudeSessions`, on by default). Turning one off hides that provider's embedded families, completion cards and reminders; collection continues and hidden endings stay unread. Zotero translation sessions are always excluded.
- Host tracking uses Core's policy (caching, two-second scan throttle, sleep cancellation, wake retry). A bounded native process snapshot gives parent links, and each candidate is checked by PID and creation time.
- Opening a card uses its verified live host. If the host has exited, the engine may restart the captured executable or packaged app after checking its file identity, size and modification time again. It passes no transcript arguments or prompt. Executable paths stay in the engine; WPF gets a one-use navigation context. Any failure leaves the ending unread.

### Claude Desktop data folder

A Claude task without a live host opens through Desktop's `claude://code/continue` link only when the active Desktop account's `local_<UUID>` session metadata maps it. The same folder supplies the Desktop account check, the SSH and WSL mirror exclusion and `ssh_configs.json`.

- Desktop 4.23118 and later keep this data in `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc`, named for the package family. When that folder has a `config.json`, it is the only folder read.
- Older builds use `%APPDATA%\Claude` or the package's `LocalCache\Roaming\Claude` and `RoamingState\Claude`. A folder containing Desktop's `.user-data-left.claude_pzs8sxrjxfjjc` marker is skipped, so leftover files from another account cannot break every mapping.
- Without a verified mapping the card falls back to its host or reports that the starting app is unknown.

## Codex Remote Control

- `monitorRemoteControl` defaults to on, as on the Mac. The paired-device directory is read through the shared catalog and the stream arrives over the authenticated Desktop pipe. A saved routing hint alone grants nothing.
- Bearer credentials stay inside the read-only catalog request ([WinHTTP limits](windows-engine.md#http-through-winhttp)). Catalog work is separate from initialization, so a slow directory cannot block the local task source or the 650 ms cleanup budget.
- Only the currently verified account and exact device ID can open a Remote Control thread. Account or enrollment changes revoke old pipe proofs and navigation; a token refresh for the same account keeps its scope. A hashed account scope keeps acknowledgements of two accounts apart.

Checks use synthetic catalogs, RPC replies and a private named-pipe fixture; they never send prompts or touch real accounts.

## WSL sources

- Windows lists distributions with the [WSL commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands) and probes only distributions that are already running, as their default user. It never installs WSL, Python or a provider, and never changes a distribution's state. The feature needs an existing `/usr/bin/python3`. The setting is `monitorWSL`.
- A source is bound to the distribution, Linux user and UID, canonical home and directory identity; Codex and Claude keep separate roots. Helpers verify that identity before starting, then run the shared Core protocol. Their program arrives over bounded stdin, as for SSH, and Windows credential and environment overrides are removed. A Windows drive or another distribution's path can never become the Linux profile.
- Discovery, helpers and quota reads have owned work slots; sleep, source changes and switches cancel them. Directory replacement revokes old navigation and acknowledgements. Each provider shares one monitor for up to eight SSH and eight WSL targets.
- Claude hooks use the same installer, cache and retry rules as [SSH](windows-engine.md#claude-remote-hooks). The Linux supervisor ends the owned installer when stdin closes, without stopping the distribution.
- Quota reads use read-only Codex RPC or the shared Claude client on a bounded, owner-checked Linux file snapshot. They never borrow Windows credentials or write a credential cache, and they stay separate from the Windows account's history.
- Opening a task uses a console mode of the engine (`--wsl-terminal`) that validates the same distribution, user and root first; failure keeps the ending unread.

Tests use synthetic profiles, private helpers and intercepted transport; a real WSL lifecycle and terminal activation are not covered.

## Remote page

The Remote page draws `ConnectionPagePresentation` (Core's `ConnectionSource`, `SSHHost` and `ConnectionSummary`): local collectors, Cloud Projects and Remote Control, then SSH and WSL hosts with Codex and Claude side by side, problems first. Session counts exclude a Claude source whose hooks are still being set up or failed.

- A source retry clears backoff for inactive helpers, retries failed Claude setup and refreshes discovery without restarting healthy subscriptions. Quota and balance have their own actions.
- Setup buttons carry the source and its context. Removing, disabling or replacing a source invalidates old buttons, and a second retry is refused while setup runs.
- The `connection` group and synthetic Swift tests cover grouping, counts, source switches and retry ownership.

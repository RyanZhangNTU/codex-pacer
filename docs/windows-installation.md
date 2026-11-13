# Windows installation

Pacer for Windows ships as a per-user Inno Setup installer. The Release workflow builds an unsigned installer (`windows-installer-<arch>-unsigned`) and a portable ZIP (`windows-app-<arch>-unsigned`) for x64 and ARM64; a tag run signs the Windows feed and publishes the installers with the Mac DMG ([release workflow](releasing.md)). The Release workflow only packages. Lifecycle tests run in the Platforms workflow on manual runs and on pull requests that touch the installer, maintenance, updates, packaging, the toolchain or the app code these checks start ([continuous integration](development.md#continuous-integration)).

## Installer identity and requirements

| Item | Value |
| --- | --- |
| Inno Setup `AppId` and name | `CodexPacer.Windows`, `Codex Pacer`. QA builds (`-QaScope`) append `.QA.<scope>` and ` QA <scope>` so they install beside the real app. |
| Default folder | `%LOCALAPPDATA%\Programs\Codex Pacer` |
| Privileges | [`PrivilegesRequired=lowest`](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm): registry entries and shortcuts belong to the current user; no administrator prompt |
| Minimum Windows | Windows 10 2004 (build 19041) for the app and installer |
| User data | `%LOCALAPPDATA%\CodexPacer` (preferences, history, read records, update state) |

Keep the identity, folder and data path stable: upgrades, updates and uninstall depend on them.

- The installer is not Authenticode-signed yet. SmartScreen may show "Windows protected your PC"; choose More info, then Run anyway.
- It uses English or Simplified Chinese from the Windows display language and asks otherwise. The Chinese messages are an unofficial Inno Setup translation pinned in `windows/ThirdParty/InnoSetup` with its license and source hash, verified before packaging.
- The finish page offers a desktop shortcut, a Start menu entry and Run Codex Pacer, all checked. Unchecking only skips creating a shortcut; it never deletes one. A silent in-app update refreshes only the shortcuts that exist and lets the updater relaunch the app. A silent fresh install creates both shortcuts.
- The package carries the .NET, Swift, VC and Python runtimes, so the app starts offline. Web sign-in needs the WebView2 Runtime that Windows provides. Installing downloads nothing, installs no service and changes no system or graphics settings.

## Upgrade and repair

- Run the installer again into the same folder to upgrade or repair. Files of the same version are replaced too. User data lives outside the app folder and is kept.
- The installer extracts its new maintenance program and checks the current installation first. After copying, it deletes files the new build no longer lists, judged by the installed manifest and content hashes; changed or unlisted files are kept. Repair works even when the installed .NET main assembly is damaged.
- Patch installers from in-app updates refuse any installation that is not exactly their base ([patch updates](windows-automatic-updates.md#patch-updates)).
- Maintenance asks only the app with the same executable path, user and session to exit, then waits a bounded time. It never closes other copies by name. A file still in use fails the install before anything is overwritten; there is no reboot replacement and no forced kill.
- Only local folders are accepted: network paths, drive roots and paths with reparse points are refused. Do not put task data or other apps' files in the install folder.

## Open at Login

- **Settings > General > Open at Login** manages the HKCU [Run entry](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys) for the current install path. The state is read back from Windows; there is no preference key. Paths with spaces stay quoted; a path over the Run command limit shows a failure.
- Windows Startup Apps or policy can still block the entry. Settings then shows disabled, blocked by policy or unknown, with a button for [`ms-settings:startupapps`](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings). Pacer never rewrites StartupApproved to get around the user's choice.
- StartupApproved's binary format has no public contract. Values 2 and 6 read as allowed, 3 and 7 as disabled, anything else as unknown.
- A failed change restores the previous entry and shows an error. The state refreshes when the window is activated; nothing polls.

## Uninstall and data

Uninstall from Windows **Installed apps**. Maintenance first checks the Claude configuration, then closes this installation, removes what Pacer owns, and deletes the program files and folder. Finished update downloads are deleted. Preferences, history, read records, update state, the last install log and sign-in data are kept; to clear sign-in data, sign out or delete keys in Settings before uninstalling.

If cleanup fails, the user can Retry, Continue Uninstall or Cancel:

- Cancel keeps the app files. If the preflight finds invalid JSON, an oversized configuration or an unsafe path, neither Claude configuration nor app registrations change.
- Continue deletes the app files, removes the owned items it still can, keeps the failed ones and writes manual steps to the uninstall log. A Pacer hook left behind calls a deleted program, so Claude Code may report errors until that entry is removed. Prompts name only the configuration file and where to find it, never its contents.
- A silent uninstall (`/SILENT`, `/VERYSILENT`) returns a nonzero result on cleanup failure and keeps the app files. `uninstall-cleanup.log` in the data folder records which part failed: Codex configuration, DeepSeek Harness configuration, Claude configuration or Windows registration. Uninstalling from Installed apps enables the Inno log; add `/LOG` when uninstalling from the command line.

What uninstall removes, and only when Pacer owns it:

- **Windows:** the install registration, Start menu and desktop shortcuts, the Run entry and the notification registration. Entries for another path, other apps' values and shortcuts the user changed are kept. Notification cleanup checks the activator path before calling [`UnregisterAll`](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.appnotifications.appnotificationmanager.unregisterall) and removes the executable's path mapping.
- **Claude:** the shared `ClaudeHookInstaller` rules remove only Pacer's current and old hook commands, restore the status line if it is still Pacer's wrapper, and remove only environment values Pacer added that the user has not changed. It covers the default, configured and recorded local Claude homes, not remote ones, and never guesses ownership without an install record. The [shared Python runtime](windows-engine.md#claude-python-runtime) is deleted last, only if owned and unreferenced. Adapter scripts and cleaned bookkeeping in the Claude home stay; nothing references them any more.
- **Codex progress:** Pacer revokes running reporters and removes its `pacer_progress` entry and Dot progress plugin. Invalid TOML blocks uninstall. The reporter's runtime (`%LOCALAPPDATA%\CodexPacer\CodexProgressRuntime`) stays with user data.
- **DeepSeek Harness:** in `%USERPROFILE%\.dsh` (or `DSH_HOME`) and the data folder chosen in Settings, only folders containing `pacer\deepseek-progress` are touched. Pacer's entries in `cordis.patch.yml` whose checksum still matches, the switch file and the marked reporter script are removed. A changed entry is kept and reported, with instructions to delete the two marker lines and everything between them.
- **WorkBuddy:** Pacer removes its `pacer_progress` entry in `mcp.json` and its progress rule. It keeps other connectors and rules. The tool uses the same private runtime as Codex. Removing the enable file stops a running reporter from accepting progress.

## Demo

Quit Pacer, then run `CodexPacer.exe --demo` from the install folder. It shows sample data only, reads no real tasks and writes no preferences. All copies share one single-instance lock, so while Pacer runs, the demo only brings the existing window forward. Never share real tasks, accounts, credentials or raw engine traffic in screenshots.

## Installation checks

Inno Setup 6.7.4 is pinned in `windows/installer-toolchain-lock.json`. The scripts verify the official installer's SHA-256 and publisher signature and unpack it as a portable tool under `output`, without a system install. `PACER_INNO_ROOT` can name an already verified portable copy.

After building the desktop:

```powershell
./scripts/windows/package-preview.ps1 -SkipBuild
./scripts/windows/test-installer.ps1 -Archive <ZIP>
./scripts/windows/package-installer.ps1 -Archive <ZIP>
./scripts/windows/test-patch.ps1 -Archive <ZIP>
```

`test-installer.ps1` builds an installer with a QA identity and installs it under a Chinese path with spaces, with its own Run entry, Start menu folder, shortcut names and synthetic Claude configuration. It covers:

- install with default shortcuts, repair (a silent repair keeps the shortcut choices), a locked file, and overwriting a running app;
- keeping synthetic preferences and read files, the Run entry, uninstall cleanup and the offline demo;
- invalid Claude JSON with a silent abort, an interactive cancel, repeated retries and an explicit continue, checking raw bytes and log privacy. QA-only arguments drive the interactive choices through the same maintenance entry.

`-CodexExecutable <path>` also runs the local Codex with two isolated configurations to test the progress reporter through an overwrite and an uninstall while it runs, and that invalid TOML blocks uninstall. The test uninstalls and deletes its folders afterwards; screenshots show only demo data.

Before using the screen, the test waits for other presentation or backdrop test processes to exit, checking each minute for up to 30 minutes. It closes only the app in its own install folder. `-ProtectedProcessId` only checks that the named process still exists and never sends it anything.

`test-patch.ps1` is described under [patch updates](windows-automatic-updates.md#patch-updates).

Limits:

- Inside Codex's process tree HKCU is isolated, so registry results there prove only that view. Real HKCU registration, Run, StartupApproved, notification and uninstall behavior needs CI or a temporary current-user task outside the tree; remove the task and installation afterwards. File-system results are real.
- These checks do not replace signing out and in, a clean system, other Windows devices or ARM64 devices; ARM64 CI only builds and packages.

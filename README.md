# Codex Pacer 3.0 candidate

[简体中文](README.zh-CN.md) · [Download the latest release](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)

A native macOS island for Codex and Claude Code tasks, output rate and account quota. Hover to expand, move away to collapse, or pin it open.

3.0.0 build 48 is a development candidate. The latest-release link above refers to the published release; it does not establish that this candidate has been published or installed.

![Earlier Codex Pacer 2.0 interface](docs/assets/pacer-2.0.png)

- See Codex and Claude Code tasks together at the top of the expanded island, including local and enabled SSH sources, plus Codex Remote Control. Teal identifies Codex; warm orange identifies Claude.
- See Codex and Claude quota together in paired rings: each ring shows remaining quota, and a white tick marks where an even pace would be, with an ahead/on-pace/fast verdict. With both providers, rings show 7d and the 5h value sits one line below each ring. A single provider's ring layout shows both periods; confirmed weekly-only limits use a PRO placeholder for 5h. The rings keep the quota value and a compact reset countdown at their center, with source/update details on hover and in Settings. The collapsed island alternates one provider-colored quota value beside rings that show both, and marks a low or exhausted 5h window.
- When only Codex is enabled and its primary account reports limits without a 5h window, use the original quota bars for all actual service windows, including nonstandard or unspecified durations.
- Enable either module independently in Settings. Defaults follow detected app/CLI installations; explicit choices survive relaunch, and Use Automatic restores detection.
- Follow current task stages and retained ended turns. Codex cards open their conversation. Claude opens a mapped Desktop session or uses the installed CLI's Desktop/Terminal resume path; opening does not send a prompt.
- See the aggregate output-rate estimate for running tasks, with tool waits handled separately from generation.
- Track the reported short and seven-day quota, reset times, pacing and current cycle. A missing reset date stays unknown and cannot establish pacing or a cycle curve.
- View quota history, Credit balance and banked-reset details in Settings when the service supplies them. Codex reset-expiry details remain available; Claude has no fabricated Credit or reset-bank equivalent.
- Retain completion cards until a successful conversation open, state change or configured expiry; acknowledged endings stay dismissed across normal relaunch. Claude requires a verified Desktop destination and keeps its card after a Terminal resume fallback. Receive reminders while the island is collapsed.
- Adjust appearance, display, reminders and privacy. Menu-bar visibility is optional. Quit from the island or settings.
- Choose Automatic, Notch or Floating on any display; browse tasks three at a time while quota stays visible.
- Use adaptive width by default, or adjust a single width with a preview and slider in Settings.
- Customize the single-line collapsed bar: choose components by category and drag their order or left/right placement, with a live preview and one Save action.
- View available task TPS and first-output latency; spawned agents are grouped under the parent with their running count and summed TPS. Matching numeric OTLP request evidence supplies exact Claude request timing. After a verified stop, authoritative transcript token counts with a complete observed window can supply estimated throughput. First-output latency needs an actual partial display callback or reported TTFT. Desktop SDK and `-p` final-only messages leave it unknown without numeric telemetry; completed messages cannot establish it. Previous measurements stay visible during tools or while awaiting new data; white means updated within 15 seconds, gray means older.
- Use English or Simplified Chinese, following your Mac's language by default or selecting a language in Settings.
- Update inside the app: daily checks by default, with download and installation after you choose to install.

**Requirements:** macOS 14 or later, Apple Silicon or Intel. Liquid Glass requires macOS 26 or later. Install and sign in to the provider modules you use. Native local readers observe available logs; optional Claude hooks improve lifecycle and attention coverage. Setup and remote helpers require Python 3, with Python 3.6 or newer supported on SSH hosts. Codex Remote Control requires the Codex desktop app to remain open and connected to the remote host, with the conversation loaded by a stream owner. SSH requires existing non-interactive OpenSSH access.

Claude quota prefers a fresh account-matched status-line sample, then a session in Pacer's own WebKit profile. Sign in to Claude opens Pacer's dedicated claude.ai window; you complete normal website sign-in and any verification. Existing web sessions use read-only quota GETs, and multiple organizations require an explicit choice. Production never reads another app's Keychain or Safe Storage, including during sign-in. Cookies stay under WebKit management, not in settings, JSON or logs. A quiet Pacer-owned OAuth cache or explicit environment/file credential remains a compatibility fallback. Session expiry may require signing in again; this is not a promise of indefinite access. Missing reset dates and stale data remain explicit. Claude-only SSH installations can add existing SSH aliases in Settings. See the [user guide](docs/usage.zh-CN.md) and [data semantics](docs/development.md).

## Install the unsigned release

The unsigned release may be blocked by macOS before the DMG opens. For a manual replacement, quit the old version first. If your installed version has **Check for Updates**, use it to download, verify, install and relaunch automatically.

1. [Download the DMG from the latest release](https://github.com/RyanZhangNTU/codex-pacer/releases/latest) and **double-click it first**. Dismiss the macOS blocking alert.
2. Go to **System Settings → Privacy & Security**, **scroll to Security at the bottom**, find the blocked installer, and choose **Open / Open Anyway**. Confirm when prompted.
3. **Double-click the DMG again**, drag **Codex Pacer** into **Applications**, then launch it from Applications.

If macOS also blocks the app, repeat step 2 for Codex Pacer, then launch it again.

![Privacy & Security, the Security section, and the Open Anyway button](docs/assets/macos-open-anyway.png)

[First-launch help from Apple](https://support.apple.com/102445) · [Chinese user guide](docs/usage.zh-CN.md)

## Development

Requires Xcode 26 or newer. The app has no npm or Rust dependencies.

```sh
make test TEST_FILTER='CompletionInboxTests|SessionNameTests' # during development
make build # when an app is needed for UI checks
```

Run the full suite once for a release candidate. Builds run in local temporary directories, reuse pinned dependency caches and print the app path. Use `make release-unsigned` for the unsigned universal DMG, or `make release` for the separate Developer ID signing/notarization workflow; no separate preview build is needed just for publication. See [development and data semantics](docs/development.md) and [releasing](docs/releasing.md).

The maintained codebase contains only native macOS code. React/Tauri and Windows 1.x remain available in [Git history and previous releases](https://github.com/RyanZhangNTU/codex-pacer/releases).

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

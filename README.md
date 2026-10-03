# Codex Pacer 2.0

[简体中文](README.zh-CN.md) · [Download 2.0.0 unsigned](https://github.com/RyanZhangNTU/codex-pacer/releases/tag/v2.0.0)

A native macOS island for Codex tasks, output rate and account quota. Hover to expand, move away to collapse, or pin it open.

![Codex Pacer 2.0](docs/assets/pacer-2.0.png)

- See local and enabled SSH tasks, their current stage, and ended turns; click a task to open its conversation.
- See the aggregate output-rate estimate for running tasks, with tool waits handled separately from generation.
- Track short and seven-day quota, reset countdowns, pacing and the current cycle. Banked resets expiring within the current cycle appear on the curve.
- View account Credit balance and available reset credits; select an expiry marker to see its date.
- Keep ended-turn cards until clicked, their state changes, or the configured retention expires; receive a reminder while the island is collapsed.
- Adjust appearance, display, reminders and privacy. Menu-bar visibility is optional. Quit from the island or settings.

**Requirements:** macOS 14 or later, Apple Silicon or Intel. Liquid Glass requires macOS 26 or later. An authenticated Codex installation and Python 3 provide account/task data; remote sources require existing non-interactive OpenSSH access.

## Install the unsigned release

**2.0.0 has no Developer ID signature and is not Apple-notarized.** The application retains a local ad hoc signature for execution compatibility; this does not identify a trusted developer.

1. Download `Codex-Pacer-2.0.0-universal-unsigned.dmg` from [v2.0.0](https://github.com/RyanZhangNTU/codex-pacer/releases/tag/v2.0.0), open it, and drag the app into Applications. Quit the old version before replacing it.
2. Try launching the app once. Dismiss the unidentified-developer or unverified-app alert.
3. Go to **Apple menu → System Settings → Privacy & Security → Security**. Find the Codex Pacer notice and choose **Open Anyway** (some versions first show **Open**).
4. Confirm **Open Anyway / Open** and authenticate when requested. Later launches work normally.

Use files from this repository and check `SHA256SUMS.txt` from the Release. If the exception button is missing, try launching the app again; Apple makes it available for about one hour after the attempt. See [Apple's instructions](https://support.apple.com/guide/mac-help/mh40616/mac) and [app security guidance](https://support.apple.com/102445).

See the [Chinese user guide](docs/usage.zh-CN.md) and [release notes](docs/release-notes-2.0.zh-CN.md). Chinese landscape and portrait promotional images are also attached to the Release.

## Development

Requires Xcode 26 or newer. The app has no npm or Rust dependencies.

```sh
make test
make build
```

Builds run in local temporary directories and print the app path. Use `make release-unsigned` for the unsigned universal DMG, or `make release` for the separate Developer ID signing/notarization workflow. See [development and data semantics](docs/development.md) and [releasing](docs/releasing.md).

The 2.0 main branch maintains only native macOS code. React/Tauri and Windows 1.x remain available in [Git history and previous releases](https://github.com/RyanZhangNTU/codex-pacer/releases).

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

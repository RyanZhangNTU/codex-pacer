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

2.0.0 is an unsigned build, so macOS may block its first launch.

1. [Download the DMG](https://github.com/RyanZhangNTU/codex-pacer/releases/download/v2.0.0/Codex-Pacer-2.0.0-universal-unsigned.dmg), open it, and drag **Codex Pacer** into **Applications**. Quit the old version before updating.
2. Launch the app. If macOS blocks it, go to **System Settings → Privacy & Security → Security**, find Codex Pacer, and choose **Open / Open Anyway**. Confirm when prompted.

[First-launch help from Apple](https://support.apple.com/guide/mac-help/mh40616/mac) · [Chinese user guide](docs/usage.zh-CN.md)

## Development

Requires Xcode 26 or newer. The app has no npm or Rust dependencies.

```sh
make test
make build
```

Builds run in local temporary directories and print the app path. Use `make release-unsigned` for the unsigned universal DMG, or `make release` for the separate Developer ID signing/notarization workflow. See [development and data semantics](docs/development.md) and [releasing](docs/releasing.md).

The 2.0 main branch maintains only native macOS code. React/Tauri and Windows 1.x remain available in [Git history and previous releases](https://github.com/RyanZhangNTU/codex-pacer/releases).

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

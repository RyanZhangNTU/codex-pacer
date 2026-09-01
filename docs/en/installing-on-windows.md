# Installing on Windows

## Windows test-stage status

Windows installer publishing is paused for `v1.2.2`. No Windows setup `.exe` is attached to the current stable GitHub Release.

Windows support is currently in a test stage. When a future release includes a Windows installer, it is unsigned unless Windows code signing is separately configured for that release, and Windows SmartScreen may warn that the publisher is unknown.

## Local validation result

The `v1.2.2` source tree has now completed a local Windows x64 validation on Windows build 26200 with WebView2 151.0.4129.107:

- frontend lint, build, and tests passed
- all 416 enabled Rust tests passed; 2 tests remained ignored as designed
- the release script produced an NSIS setup executable and SHA-256 checksum
- the installer completed with its default per-user location, registered an uninstaller, and created a desktop shortcut
- the installed app launched normally, imported existing local Codex history, and displayed aggregate usage and conversation data

The validated installer is still unsigned and is not part of the public `v1.2.2` GitHub Release.

## Source validation flow

1. Check out the release tag from the GitHub repository.
2. Install the Windows Tauri prerequisites.
3. Run `npm ci`.
4. Run `npm run lint`, `npm run build`, and `cargo test --manifest-path src-tauri/Cargo.toml --locked`.
5. For local installer validation only, run `.\scripts\release\build-windows-release.ps1 -Version 1.2.2` on Windows.

## After installation

When testing a local Windows build:

1. Confirm the Codex home path (`~\.codex` by default) or choose a custom `CODEX_HOME`.
2. Make sure local Codex CLI session and rate-limit data already exist at that path.
3. Run the first scan/import.
4. Wait for local indexing to complete.
5. Review the overview and pacing views.

## Notes

- GitHub Releases is the official distribution channel.
- `v1.2.2` only publishes the macOS Apple Silicon DMG asset.
- Any locally built Windows setup `.exe` remains a test-stage NSIS installer.
- A Windows installer does not install the Codex CLI and does not create Codex usage history.
- Stable Windows support, Windows code signing, and auto-update delivery are not currently promised.

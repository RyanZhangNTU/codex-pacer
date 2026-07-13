# Installing on Windows

## Windows test-stage status

Windows installer publishing is paused for `v1.2.0`. No Windows setup `.exe` is attached to the current stable GitHub Release.

Windows support is currently in a test stage. When a future release includes a Windows installer, it is unsigned unless Windows code signing is separately configured for that release, and Windows SmartScreen may warn that the publisher is unknown.

## Source validation flow

1. Check out the release tag from the GitHub repository.
2. Install the Windows Tauri prerequisites.
3. Run `npm ci`.
4. Run `npm run lint`, `npm run build`, and `cargo test --manifest-path src-tauri/Cargo.toml --locked`.
5. For local installer validation only, run `.\scripts\release\build-windows-release.ps1 1.2.0` on Windows.

## After installation

When testing a local Windows build:

1. Confirm the Codex home path (`~\.codex` by default) or choose a custom `CODEX_HOME`.
2. Make sure local Codex CLI session and rate-limit data already exist at that path.
3. Run the first scan/import.
4. Wait for local indexing to complete.
5. Review the overview and pacing views.

## Notes

- GitHub Releases is the official distribution channel.
- `v1.2.0` only publishes the macOS Apple Silicon DMG asset.
- Any locally built Windows setup `.exe` remains a test-stage NSIS installer.
- A Windows installer does not install the Codex CLI and does not create Codex usage history.
- Stable Windows support, Windows code signing, and auto-update delivery are not currently promised.

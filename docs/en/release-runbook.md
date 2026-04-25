# Release Runbook

## Purpose

This runbook is for maintainers producing public **Codex Pacer** release assets:

- signed and notarized Apple Silicon DMG
- unsigned Windows NSIS setup EXE
- published through GitHub Releases

The local release entry points are:

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.1.1
./scripts/release/publish-github-release.sh 1.1.1
```

```powershell
.\scripts\release\build-windows-release.ps1 1.1.1
```

The macOS release scripts default `CARGO_TARGET_DIR` to `~/Library/Caches/CodexPacer/cargo-target` so signed macOS bundles are produced outside cloud-synced folders such as iCloud Drive. This avoids `codesign` failures caused by Finder and file-provider metadata on `.app` bundles.

## Prerequisites

- macOS on Apple Silicon for the standard public build flow
- Apple Developer account with a valid **Developer ID Application** certificate installed in the login keychain
- Xcode command line tools available (`codesign`, `spctl`, `xcrun`)
- `npm`, `cargo`, and the repo dependencies available locally
- `gh` authenticated to the GitHub repository
- release notes file present at `docs/en/release-notes-vVERSION.md`
- matching release version in both `package.json` and `src-tauri/tauri.conf.json`
- committed `package-lock.json` present and up to date for the release commit
- committed `src-tauri/Cargo.lock` present and up to date for the release commit
- clean git working tree before starting the build or publish steps
- release tag `vVERSION` created locally, pointing at `HEAD`, and pushed to `origin` before publishing
- if you override `CARGO_TARGET_DIR`, use the same value for both build and publish, and keep it on a local non-cloud-synced path

For Windows release builds:

- Windows PowerShell or PowerShell on Windows
- `git`, `node`, `npm`, and `cargo` available on `PATH`
- Tauri prerequisites for Windows NSIS builds installed
- clean git working tree unless `-AllowDirty` is explicitly used for a local test build
- no Windows code signing is configured by default; the setup EXE is unsigned unless a release separately adds signing

To list available local signing identities:

```bash
security find-identity -v -p codesigning
```

Use the exact certificate name for `APPLE_SIGNING_IDENTITY`.

## Required environment variables

The build script expects a local signing identity plus exactly one notarization credential path.

### Signing

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

`APPLE_SIGNING_IDENTITY` is the official Tauri-supported way to point a local macOS build at a keychain-installed certificate.

### Notarization with Apple ID

```bash
export APPLE_ID="maintainer@example.com"
export APPLE_PASSWORD="app-specific-password"
export APPLE_TEAM_ID="TEAMID1234"
```

### Notarization with App Store Connect API

```bash
export APPLE_API_ISSUER="00000000-0000-0000-0000-000000000000"
export APPLE_API_KEY="ABC123DEFG"
export APPLE_API_KEY_PATH="$HOME/keys/AuthKey_ABC123DEFG.p8"
```

Pick one notarization path and leave the other unset. The build script rejects ambiguous or incomplete credential sets.

## Standard macOS release flow

1. Confirm the target release notes file exists.
2. Confirm `package.json` and `src-tauri/tauri.conf.json` both match the release version.
3. Confirm `git status --short` is empty before starting release actions.
4. Export `APPLE_SIGNING_IDENTITY` and one notarization credential set.
5. Run the build script.
6. Review the generated DMG and checksum.
7. Create and push the Git tag.
8. Confirm the tag still points at `HEAD` after any final review.
9. Publish the GitHub Release with the DMG, checksum, and English release notes.
10. Run the manual smoke test on the packaged app.

GitHub Releases is the handoff point between maintainer workflow and user installation. The tag records exactly what source was released, the release notes explain the user-facing change, and the attached platform installers plus checksums are the canonical install assets for that version.

## Build the signed and notarized DMG

```bash
./scripts/release/build-macos-release.sh 1.1.1
```

What the build script does:

- requires a clean git working tree before release actions start
- runs `npm ci` against the committed `package-lock.json`
- runs `./scripts/release/audit-public-branding.sh`
- runs `npm run lint`
- runs `npm run build`
- runs `cargo test --manifest-path src-tauri/Cargo.toml --locked`
- runs `npm run tauri build -- --ci --bundles app,dmg [--target ...] -- --locked`
- defaults `CARGO_TARGET_DIR` to `~/Library/Caches/CodexPacer/cargo-target`
- rejects cloud-synced target roots that can inject Finder metadata into `.app` bundles
- locates the most recent built `.app` and `.dmg` under the active Cargo target root
- verifies the signed app with `codesign`, `spctl`, and `xcrun stapler validate`
- submits the built DMG to Apple with `xcrun notarytool submit --wait`
- staples the DMG ticket with `xcrun stapler staple`
- verifies the signed DMG with `codesign`, `spctl --type open --context context:primary-signature`, and `xcrun stapler validate`
- writes a sibling checksum file at `<artifact>.dmg.sha256`

## Build the Windows NSIS installer

Run this on Windows:

```powershell
.\scripts\release\build-windows-release.ps1 1.1.1
```

What the Windows build script does:

- requires Windows
- requires a clean git working tree unless `-AllowDirty` is passed
- runs `npm ci` against the committed `package-lock.json`
- runs `npm run lint`
- runs `npm run build`
- runs `cargo test --manifest-path src-tauri/Cargo.toml --locked`
- runs `npm run tauri build -- --ci --bundles nsis -- --locked`
- locates the generated NSIS setup `.exe` under the active Cargo target root
- writes a sibling checksum file at `<installer>.exe.sha256`

The Windows installer is unsigned unless Windows code signing is separately configured for the release. Do not describe it as signed, notarized, or SmartScreen-trusted by default.

### Optional Windows Cargo target override

If you need to override the Windows build output location, set `CARGO_TARGET_DIR` before running the script:

```powershell
$env:CARGO_TARGET_DIR = "C:\Users\you\AppData\Local\CodexPacer\cargo-target"
.\scripts\release\build-windows-release.ps1 1.1.1
```

### Optional target override

If you need to pass a specific Tauri target triple, set `TAURI_TARGET` before running the build:

```bash
export TAURI_TARGET="aarch64-apple-darwin"
./scripts/release/build-macos-release.sh 1.1.1
```

`TAURI_TARGET` stays on the Tauri CLI side of the command, before the final `--` that introduces Cargo runner args such as `--locked`.
The script does not assume a single target output path; it searches the active Cargo target root for the fresh build artifacts after Tauri finishes.
Because the release path uses `npm ci` plus Cargo `--locked`, maintainers should update and commit both `package-lock.json` and `src-tauri/Cargo.lock` before starting the clean release flow rather than letting dependency resolution change during the build.

### Optional Cargo target override

If you need to override the build output location, export `CARGO_TARGET_DIR` before running the release scripts:

```bash
export CARGO_TARGET_DIR="$HOME/Library/Caches/CodexPacer/custom-target"
./scripts/release/build-macos-release.sh 1.1.1
./scripts/release/publish-github-release.sh 1.1.1
```

Do not point `CARGO_TARGET_DIR` at iCloud Drive, Dropbox, OneDrive, or other cloud/file-provider folders. Signed `.app` bundles created there can pick up `com.apple.FinderInfo` metadata and fail during `codesign`.

## Create and push the release tag

```bash
git status --short
git tag v1.1.1
git push origin v1.1.1
```

The publish script expects:

- a clean git working tree
- the local tag to exist
- the local tag to resolve to `HEAD`
- the same tag to already exist on `origin`

## Publish the GitHub Release

```bash
./scripts/release/publish-github-release.sh 1.1.1
```

The publish script uses:

- the built DMG for `v1.1.1`
- the sibling `.sha256` checksum file
- `docs/en/release-notes-v1.1.1.md`

It publishes those assets with `gh release create`.

For releases that include Windows, also attach the generated NSIS setup `.exe` and its `.sha256` checksum to the same GitHub Release. Note in the release body that the Windows installer is unsigned unless Windows signing was separately configured for that release.

## macOS manual smoke test

Run this before announcing the release publicly:

1. Open the generated DMG on an Apple Silicon Mac.
2. Confirm the DMG shows **Codex Pacer.app**.
3. Drag the app into `Applications`.
4. Launch the installed app from `Applications`.
5. Confirm Gatekeeper does not report the app as broken or unsigned.
6. Confirm the window title and menu bar entry use **Codex Pacer** branding.
7. Run an import from the default `~/.codex` path or a known-good sample environment.
8. Confirm the overview loads and the first local indexing pass completes.
9. Confirm the menu bar popup opens below the macOS menu bar.
10. Confirm macOS-only Dock settings are present on macOS and are not described as Windows settings.
11. Confirm the app quits and relaunches cleanly from `Applications`.

Useful spot checks:

```bash
spctl -a -vv --type exec "/Applications/Codex Pacer.app"
codesign --verify --deep --strict --verbose=2 "/Applications/Codex Pacer.app"
spctl -a -vv --type open --context context:primary-signature "/path/to/Codex Pacer.dmg"
xcrun stapler validate "/path/to/Codex Pacer.dmg"
```

## Windows manual smoke test

Run this before announcing Windows availability publicly:

1. Confirm the generated setup `.exe` and sibling `.sha256` file are present.
2. Verify the checksum with `Get-FileHash`.
3. Run the setup `.exe` on a Windows test machine.
4. If SmartScreen warns about an unknown publisher, confirm the warning is expected for an unsigned installer.
5. Launch **Codex Pacer** from the Start menu.
6. Confirm the app reads the default `~\.codex` path or a custom `CODEX_HOME`.
7. Run an import from a known-good local Codex environment.
8. Confirm the overview loads and the first local indexing pass completes.
9. Confirm the tray popup opens above a bottom taskbar and grows upward when optional modules are shown.
10. Refresh live quota data and confirm no black console window appears.
11. Confirm the app quits and relaunches cleanly.

Useful spot check:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath "C:\path\to\Codex Pacer_1.1.1_x64-setup.exe"
```

## Troubleshooting

- If the build fails before notarization, confirm the Developer ID certificate is installed in the login keychain and that `APPLE_SIGNING_IDENTITY` matches `security find-identity -v -p codesigning`.
- If notarization fails, confirm only one credential path is exported and that the App Store Connect key file still exists at `APPLE_API_KEY_PATH`.
- If the DMG fails Gatekeeper assessment, confirm the script completed the explicit `notarytool submit` and `stapler staple` steps for the DMG itself, not just the app bundle.
- If `codesign` reports `resource fork, Finder information, or similar detritus not allowed`, confirm the build output is not under a cloud-synced path and rerun with the default `CARGO_TARGET_DIR` or another local cache directory.
- If either release script stops on the clean-tree check, clear or stash local changes and rerun only after `git status --short` is empty.
- If the build succeeds but the release script cannot find artifacts, clear old outputs and rerun the build so the newest `.app` and `.dmg` are unambiguous.
- If `gh release create` fails, confirm `gh auth status`, the local `vVERSION` tag, that the tag still matches `HEAD`, that the same tag exists on `origin`, and the presence of the checksum file beside the DMG.
- If the Windows release script cannot find the NSIS installer, confirm the Tauri build completed and inspect `src-tauri\target\release\bundle\nsis` or the configured `CARGO_TARGET_DIR`.
- If users report a Windows SmartScreen warning, confirm whether the published installer was intentionally unsigned and make the unsigned note visible in the release body.

## Related docs

- [Packaging and release](./packaging-and-release.md)
- [Installing on macOS](./installing-on-macos.md)
- [Installing on Windows](./installing-on-windows.md)

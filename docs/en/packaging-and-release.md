# Packaging and Release

## Official release scope

The stable public release of **Codex Pacer** is distributed through **GitHub Releases**.

The stable packaged asset is:

- signed and notarized **macOS Apple Silicon DMG**

Windows is currently published as a test-stage asset:

- unsigned **Windows NSIS setup EXE** for compatibility testing and early validation

Items that are **not currently promised** as official release assets:

- Intel macOS builds
- universal macOS builds
- Linux bundles
- stable Windows support
- Windows code signing
- auto-update delivery

Keep release messaging aligned with this scope so the project does not over-promise Windows stability, signing, notarization, or auto-update behavior beyond the supported stable workflow.

## Stable release workflow

The intended public release flow is:

1. Confirm public branding and documentation are ready for release.
2. Build the signed macOS Apple Silicon DMG.
3. Build the unsigned Windows NSIS setup EXE when the release includes a Windows test-stage asset.
4. Publish the release assets through GitHub Releases.
5. Attach or include release notes for the tagged version.

## Local release preparation

Public release preparation is driven by the release scripts below:

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.1.1
./scripts/release/publish-github-release.sh 1.1.1
```

```powershell
.\scripts\release\build-windows-release.ps1 1.1.1
```

Those scripts are the stable local entry points for public release preparation. The macOS build script verifies the version, runs the audit/lint/build/test checks, produces the signed and notarized DMG, and writes a checksum beside the artifact. The Windows build script runs on Windows, verifies the version, runs lint/build/Rust tests, produces the NSIS setup EXE, and writes a checksum beside the installer. The Windows installer is unsigned and test-stage unless Windows code signing and a stable Windows release policy are separately configured. The publish script verifies the tag and uploads the macOS DMG plus checksum to GitHub Releases; upload the Windows EXE and checksum as test-stage release assets for releases that include Windows.

## Platform isolation rules

Keep macOS and Windows differences behind explicit platform boundaries so one release line can remain on `main`/`develop` without cross-platform drift:

- use Rust `#[cfg(...)]` gates for native behavior that only exists on one OS
- use frontend capability checks before showing OS-specific settings such as macOS Dock controls
- keep release packaging in platform-specific scripts (`build-macos-release.sh` and `build-windows-release.ps1`)
- verify macOS menu bar behavior and Windows taskbar behavior separately before merging platform changes

Windows-specific tray popup placement, hidden child-process windows, and unsigned installer handling must not change macOS Dock, menu bar, signing, or notarization behavior.

## Recommended validation before publishing

- confirm `package.json` and `src-tauri/tauri.conf.json` are aligned on the release version
- confirm release notes and docs point to the stable public release line
- run the branding/doc audit before publishing
- verify the generated DMG opens correctly on Apple Silicon macOS
- verify the signed app launches from `Applications`
- verify the macOS menu bar popup opens below the menu bar and macOS-only Dock settings remain macOS-only
- verify the generated Windows setup EXE installs on Windows
- verify the Windows tray popup opens above a bottom taskbar, grows upward as optional modules are shown, and live quota refresh does not show a console window
- verify the Windows installer checksum and note that it is test-stage and unsigned unless signing was separately configured

## Publishing guidance

- Create the Git tag for the stable release version.
- Create the GitHub Release from that tag.
- Upload the signed and notarized Apple Silicon DMG.
- Upload the unsigned Windows NSIS setup EXE as a test-stage asset when the Windows release script has been run.
- Add the matching release notes document for the version being published.
- Verify the download and install flow after publication.

GitHub Releases is more than a file host in the current workflow. It is the public boundary where a reviewed Git tag, human-readable release notes, platform installers, and checksums meet. Users should install the platform-specific asset attached to the tagged release, while maintainers use the tag and checksums to make the release reproducible and auditable.

## What users should be told

For public docs and announcements, use this message consistently:

- official distribution channel: GitHub Releases
- stable release asset: signed and notarized macOS Apple Silicon DMG
- Windows test-stage asset: unsigned Windows NSIS setup EXE
- current stable line: `v1.1.1`

## Related docs

- [Getting started](./getting-started.md)
- [Installing on macOS](./installing-on-macos.md)
- [Installing on Windows](./installing-on-windows.md)
- [Release runbook](./release-runbook.md)
- [Release notes for v1.1.1](./release-notes-v1.1.1.md)

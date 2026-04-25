# Installing on Windows

## Windows test-stage install path

The Windows public installer for **Codex Pacer** is the NSIS setup `.exe` published through GitHub Releases.

Windows support is currently in a test stage. The Windows installer is unsigned unless Windows code signing is separately configured for a release, and Windows SmartScreen may warn that the publisher is unknown.

## Standard install flow

1. Open the latest GitHub Releases page for `codex-pacer`.
2. Download the latest Windows NSIS setup `.exe`.
3. Run the downloaded setup file.
4. If SmartScreen warns about an unknown publisher, confirm that the file came from the project GitHub Release before continuing.
5. Launch **Codex Pacer** from the Start menu after installation.

## After installation

On first run:

1. Confirm the Codex home path (`~\.codex` by default) or choose a custom `CODEX_HOME`.
2. Make sure local Codex CLI session and rate-limit data already exist at that path.
3. Run the first scan/import.
4. Wait for local indexing to complete.
5. Review the overview and pacing views.

## Notes

- GitHub Releases is the official distribution channel.
- The Windows setup `.exe` is a test-stage NSIS installer.
- The installer does not install the Codex CLI and does not create Codex usage history.
- Stable Windows support, Windows code signing, and auto-update delivery are not currently promised.

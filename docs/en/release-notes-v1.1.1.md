# Codex Pacer v1.1.1

## Summary

`v1.1.1` is a stability release for live quota refreshes and macOS menu bar popup placement.

This release makes Codex Pacer more resilient when Codex app-server is still initializing, exits early, or cannot return live rate limits immediately.

## Highlights

- live quota refresh now waits for the Codex app-server `initialize` response before requesting rate limits
- failed live quota refreshes now try to refresh Codex history and load the latest session-sourced quota sample
- fallback loading can still use older persisted live samples or memory cache when no session quota sample is available
- menu bar popup placement now stays on the display where the menu bar item was clicked when external monitors are attached
- error paths now distinguish initialization timeout, app-server early close, and rate-limit query failure more clearly

## Packaging

Stable public release asset:

- signed and notarized macOS Apple Silicon DMG via GitHub Releases

Windows is available as a test-stage asset for this release:

- unsigned Windows NSIS setup EXE via GitHub Releases

The Windows installer is intended for compatibility testing and early validation. It is not code signed, does not install the Codex CLI, and may trigger Microsoft SmartScreen unknown-publisher warnings.

GitHub Releases remains the public release boundary for Codex Pacer: each release is tied to a Git tag, carries the user-facing release notes, and hosts platform installers plus checksums users should install from.

## Notes

- `v1.1.1` is the current stable release line.
- Intel macOS, universal builds, Linux bundles, Windows code signing, stable Windows support, and auto-update delivery are not currently promised as official release assets.
- Codex Pacer remains local-first and does not depend on a cloud sync service to work.

# Codex Pacer v1.1.2

## Summary

`v1.1.2` fixes token overcounting after Codex state resets, replayed session files, or process restarts.

Compared with `v1.1.1`, this release also includes the database query refactor, refreshed pricing data, custom dashboard range controls, and Windows compatibility groundwork now promoted to `main`.

## Highlights

- token imports now treat cumulative usage snapshots as monotonic high-water marks per session
- replayed or rolled-back token totals no longer add the full current total again
- component counters that roll back are clamped without losing legitimate total-token growth
- existing overcounted token usage rows are repaired once during the next scan
- source files that cannot be repaired are tracked for targeted retry instead of repeatedly forcing every session to reimport
- database query SQL is split into versioned files, with smaller persistence modules for sync settings, subscription data, and rate-limit samples
- custom dashboard date range selection makes it easier to inspect a specific local usage period
- API-equivalent pricing uses refreshed Standard short-context pricing with deterministic pricing row selection
- dashboard distribution controls have clearer button behavior and wrapping
- Windows compatibility scripts and docs are present for source validation, while installer publishing remains paused for this release

## Packaging

Stable public release asset:

- signed macOS Apple Silicon DMG via GitHub Releases

Windows installer publishing is paused for this release. Windows compatibility should still be checked from source or on a Windows build host, but no Windows setup EXE is attached to `v1.1.2`.

GitHub Releases remains the public release boundary for Codex Pacer: each release is tied to a Git tag, carries the user-facing release notes, and hosts the platform installer plus checksum users should install from.

## Notes

- `v1.1.2` is the current stable release line.
- Intel macOS, universal builds, Linux bundles, macOS notarization, Windows code signing, stable Windows support, Windows installer publishing, and auto-update delivery are not currently promised as official release assets.
- Codex Pacer remains local-first and does not depend on a cloud sync service to work.

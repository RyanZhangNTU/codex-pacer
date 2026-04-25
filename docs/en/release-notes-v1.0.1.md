# Codex Pacer v1.0.1

## Summary

`v1.0.1` updates Codex Pacer for GPT-5.5 usage accounting and documents the current signed DMG release workflow.

This is a focused maintenance release for users who want API-equivalent value estimates to stay accurate as Codex model usage moves to GPT-5.5.

## Highlights

- added official GPT-5.5 pricing for API-equivalent value estimates
- added GPT-5.5 Codex fast-mode cost handling with the documented `2.5x` multiplier
- preserved GPT-5.4 fast-mode valuation at `2x`
- updated session import, recalculation, turn timelines, and token-composition breakdowns to use the same model-aware fast-mode logic
- refreshed settings copy for new GPT-5.4 / GPT-5.5 sessions
- updated packaging docs to explain why GitHub Releases is the canonical distribution point for versioned signed DMG installers

## Packaging

Official public release asset:

- signed and notarized macOS Apple Silicon DMG via GitHub Releases

GitHub Releases is used as the public release boundary for this project: each release is tied to a Git tag, carries the user-facing release notes, and hosts the signed DMG plus checksum users should install from.

## Notes

- `v1.0.1` was the previous stable release line. See the latest release notes for the current stable version.
- Intel macOS, universal builds, Windows, Linux, and auto-update delivery are not currently promised as official release assets.
- Codex Pacer remains local-first and does not depend on a cloud sync service to work.

# Codex Pacer v1.1.0

## Summary

`v1.1.0` improves the macOS menu bar experience and refreshes the settings layout for quicker daily use.

This release focuses on making the menu bar popup more compact, more visual, and better aligned with the content the user chooses to display.

## Highlights

- added a macOS option to keep Codex Pacer visible in the menu bar while hiding the Dock icon
- redesigned Settings into a cleaner single-column layout with switch controls for binary preferences
- updated menu bar defaults for logo, API value, popup, reset timeline, auto scan, refresh intervals, and fast-mode behavior
- clarified language labels as `简体中文 · Chinese` and `English · English`
- replaced the popup's 7-day pacing text with a visual usage line chart, reference line, current point, speed badge, and 7-day API value badge
- made the popup quota rings and chart blend into the popup background instead of sitting in separate cards
- made the menu bar popup height adapt to the selected visible content, with scrolling only when needed

## Packaging

Official public release asset:

- signed and notarized macOS Apple Silicon DMG via GitHub Releases

GitHub Releases remains the public release boundary for Codex Pacer: each release is tied to a Git tag, carries the user-facing release notes, and hosts the signed DMG plus checksum users should install from.

## Notes

- `v1.1.0` is the current stable release line.
- Intel macOS, universal builds, Windows, Linux, and auto-update delivery are not currently promised as official release assets.
- Codex Pacer remains local-first and does not depend on a cloud sync service to work.

# Codex Pacer v1.2.2

## Summary

Version 1.2.2 fixes the repeated disk reads reported on large Codex histories. Routine one-minute refreshes now inspect the small set of active, changed, or pending-repair files instead of walking the full archive. Dashboard and quota queries are bounded to the selected window, and conversation history loads in pages.

This release also supports Codex accounts that no longer expose a 5-hour quota. The dashboard opens on the 7-day view, keeps the weekly quota visible, and uses that same 7-day window for the menu bar API-equivalent value.

## What changed

- default dashboard view changed to the current 7-day window
- 7-day quota remains available when the 5-hour quota is absent
- menu bar API-equivalent value falls back to the current 7-day window
- routine scans use incremental discovery and durable parser checkpoints
- archived sessions are reconciled during bounded maintenance instead of every automatic refresh
- quota trends query the exact normalized window and retain one point per chart bin
- overview data is cached and invalidated when usage, quota, or subscription settings change
- conversation lists use SQL pagination, and turn details load only after selection
- duplicate dashboard reads on view and search changes have been removed
- pending repair files without import state are retried directly

## Resource validation

The release work was tested with automatic scanning set to one minute. Over a 30-minute sample, Codex Pacer read 34.41 MiB and averaged 0.14% of one CPU core. The trace did not show recurring full archive scans. A separate 130-second smoke test of the packaged app recorded 4 KiB of reads after launch.

These figures come from the release test machine and its local Codex history. Results will vary with active sessions, database size, and whether a scheduled reconciliation is due.

## Upgrading from 1.2.0

Install 1.2.2 over the existing app. Do not uninstall the previous version or delete the local database.

Codex Pacer keeps the same app name, bundle identifier, and data location. Existing conversations, token usage, quota samples, subscription settings, menu bar preferences, and custom Codex paths remain in place.

## Packaging

The public macOS asset is an Apple Silicon DMG distributed through GitHub Releases with a SHA-256 checksum. The release is Developer ID signed, notarized by Apple, stapled, and checked with Gatekeeper before publication.

Windows installer publishing remains paused for this release.

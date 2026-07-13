# Codex Pacer v1.2.0

## Summary

Version 1.2.0 focuses on reliable background refresh and lower resource use. Token statistics and online quota now refresh through independent workers, so a slow local scan does not hold up live quota updates and a live request does not delay token imports.

The importer now reads only the completed tail of growing session files. It also updates usage and quota history in place instead of rebuilding unchanged rows. Menu bar totals are calculated inside SQLite, which avoids loading a large usage history just to render a value.

## What changed

- added GPT-5.6 Sol, Terra, and Luna recognition with bundled Standard API-equivalent pricing
- added automatic discovery of the Codex CLI bundled with the ChatGPT desktop app on macOS
- separated token and online quota refresh scheduling, retries, and freshness tracking
- replaced frontend refresh polling with backend events
- added durable parser checkpoints for growing JSONL session files
- reduced database write amplification for usage and quota history
- moved timestamp migration into bounded, resumable background batches
- corrected forked-session accounting, including nested forks and temporarily unavailable parent files
- fixed stale refresh overwrites, listener startup races, shutdown races, and lost retry work
- fixed complete final JSONL records being skipped when the file has no trailing newline
- reduced refresh allocation retention and temporary spool size on macOS

## Upgrading from 1.1.1 or 1.1.2

Install 1.2.0 over the existing application. You do not need to uninstall the previous version or remove its database.

Codex Pacer keeps the same app name, bundle identifier, and local data location. On first launch, it adds the new schema fields and indexes in place. Existing conversations, token usage, quota samples, subscription settings, menu bar preferences, and custom Codex paths are preserved.

Older timestamp rows are filled in by a small resumable background job. Normal token and online quota refresh continue independently while that work runs. Compatibility tests build databases from the exact 1.1.1 and 1.1.2 schemas, populate user data, upgrade them to 1.2.0, and verify the stored values and database integrity.

## Performance notes

Local restart testing on the release build no longer showed the previous roughly 53 MiB startup and per-refresh write bursts. A clean-cache launch wrote 1.68 MiB over 75 seconds, including one background refresh. A four-minute sample averaged 1.53% of one CPU core, read 0.18 MiB, and wrote 5.30 MiB. Refresh memory peaks returned to roughly 136–142 MiB of physical footprint after the work completed.

These figures describe the release test machine and dataset; actual use depends on session history and refresh activity.

## Packaging

The public macOS asset is an Apple Silicon DMG distributed through GitHub Releases with a SHA-256 checksum. The release is Developer ID signed, notarized by Apple, stapled, and checked with Gatekeeper before publication.

Windows installer publishing remains paused for this release.

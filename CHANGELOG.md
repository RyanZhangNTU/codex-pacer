# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- updated the Windows frontend toolchain to Vite 8.2.2 and `@vitejs/plugin-react` 6.1.1

### Fixed
- Windows builds no longer compile the macOS-only Objective-C dependencies
- Windows test and application binaries now embed the Common Controls v6 manifest, fixing the `STATUS_ENTRYPOINT_NOT_FOUND` test startup failure
- the local Windows NSIS installer now builds, installs, launches, and reads existing Codex history successfully on an x64 Windows validation host

## [1.2.2] - 2026-07-13

### Added
- the dashboard now opens on the 7-day view, and conversation history is loaded in pages with detail fetched only after selection
- the menu bar uses the current 7-day window for API-equivalent value when Codex does not provide a 5-hour quota

### Changed
- routine refreshes use incremental file discovery, durable parser checkpoints, bounded database queries, and cached dashboard results
- quota charts read only the selected normalized window and keep one sample per chart bin instead of loading the full bucket history
- frontend refresh and conversation loading avoid duplicate requests when the view, search, or time window changes

### Fixed
- Codex accounts without a 5-hour quota no longer lose their 7-day quota or fail to open the default dashboard
- incremental scans no longer revisit the full archived session tree every minute, while pending repair files still receive targeted retries
- subscription profile changes invalidate cached overview values immediately
- conversation search keeps complete root-session totals and metadata when only a child session matches
- historical quota samples with second-level timestamps remain visible after epoch backfill

### Upgrade notes
- install 1.2.2 over 1.2.0 without uninstalling or deleting the local database
- existing usage, quota history, subscription settings, menu bar preferences, and custom Codex paths are retained
- automatic refresh remains incremental; a bounded full reconciliation runs only when the source changes or scheduled maintenance is due

## [1.2.0] - 2026-07-11

### Added
- GPT-5.6 Sol, Terra, and Luna model recognition with bundled Standard API pricing; the `gpt-5.6` alias uses Sol pricing
- automatic discovery of the Codex CLI bundled with the ChatGPT desktop app on macOS, while retaining standalone CLI and `CODEX_BIN` support
- independent background refresh lanes for local token usage and online quota data, with bounded retries and missed-refresh recovery

### Changed
- active session logs are parsed from durable checkpoints instead of being reread from the beginning on every refresh
- usage and quota records are appended or reconciled in place instead of deleting and rebuilding unchanged history
- menu bar totals are calculated with bounded SQLite aggregates, and frontend refresh polling has been replaced with backend events
- database timestamp migration now runs in small resumable batches so startup remains responsive on larger histories
- changing a custom Codex home starts a full refresh without reusing scan times from the previous directory

### Fixed
- GPT-5.6 API-equivalent values now recalculate at startup, including rows that were zero or used a cache-write price as the output price
- incremental imports now capture final snapshots moved into `archived_sessions`, refresh titles from `session_index.jsonl`, avoid saving partial results from unreadable files, and repair missing conversation links
- persisted quota fallback now chooses the latest timestamp by its actual instant and never combines windows from different samples
- forked and nested sessions no longer rebill usage inherited from their parent, including single-snapshot and temporarily missing-parent cases
- token and quota refreshes no longer overwrite newer results, block one another, or lose a scheduled retry when settings change
- complete JSONL records without a trailing newline are imported instead of being skipped permanently
- refresh scratch memory and temporary spool files are released promptly after commits and menu bar updates

### Upgrade notes
- macOS users can install 1.2.0 over 1.1.1 or 1.1.2 without uninstalling the previous version
- the existing local database is migrated in place; session history, token usage, quota samples, subscription settings, menu bar preferences, and custom Codex paths are retained
- the first launch may perform a bounded background timestamp backfill, but token and online quota refresh continue independently while it runs

## [1.1.2] - 2026-05-19

### Added
- custom dashboard date range selection for inspecting a specific local usage period
- Windows compatibility groundwork, release scripts, and source-validation documentation; Windows installer publishing remains paused for this release
- updated README popup screenshot for the current public UI

### Changed
- API-equivalent pricing now uses refreshed Standard short-context pricing and deterministic pricing row selection
- database query access now uses versioned SQL query files and smaller persistence modules for cleaner release maintenance
- public release documentation now points to the macOS DMG-only GitHub Release flow while Windows installer publishing remains paused

### Fixed
- token usage imports now treat cumulative snapshots as monotonic high-water marks so Codex state resets, replayed files, or process restarts do not rebill already-counted tokens
- existing overcounted token usage rows are repaired once on the next scan, with failed source files tracked for targeted retry instead of forcing full repeated reimports
- dashboard distribution controls now align with button semantics and wrap more predictably

## [1.1.1] - 2026-04-25

### Changed
- live quota refresh now waits for the Codex app-server initialization response instead of relying on a fixed delay before requesting rate limits
- failed live quota refreshes now attempt to refresh Codex history and load the latest session-sourced quota sample before falling back to older persisted or cached data

### Fixed
- reduced `Broken pipe (os error 32)` failures when Codex app-server exits or closes stdin before a live quota request is ready
- menu bar popup placement now stays on the display where the menu bar item was clicked when external monitors are attached

## [1.1.0] - 2026-04-25

### Added
- macOS setting to keep Codex Pacer visible in the menu bar while hiding the Dock icon
- menu bar popup 7-day usage chart with reference pacing, current point, speed badge, and 7-day API value badge
- adaptive menu bar popup height based on the content enabled in Settings

### Changed
- redesigned Settings into a cleaner single-column layout with switch controls for binary preferences
- refreshed menu bar default settings for logo, API value, popup, reset timeline, auto scan, refresh intervals, and fast-mode behavior
- simplified language labels as `简体中文 · Chinese` and `English · English`
- made popup quota rings and the 7-day chart blend into the popup background instead of separate cards

### Fixed
- popup layout now avoids unnecessary empty space when optional menu bar content is disabled

## [1.0.1] - 2026-04-24

### Added
- official GPT-5.5 API-equivalent pricing for input, cached input, and output token valuation
- GPT-5.5 Codex fast-mode cost handling with the documented 2.5x multiplier
- release notes and packaging guidance for the v1.0.1 GitHub Releases workflow

### Changed
- fast-mode valuation is now model-aware, preserving GPT-5.4's 2x behavior while applying GPT-5.5's 2.5x cost
- settings copy now describes the default fast-mode behavior for both GPT-5.4 and GPT-5.5 sessions
- public docs now identify GitHub Releases as the versioned distribution point for signed DMG installers and checksums

### Fixed
- GPT-5.5 sessions no longer fall through to zero API-equivalent value during import or recalculation
- token composition cost breakdowns now use the same model-aware fast-mode multiplier as session totals

## [1.0.0] - 2026-04-16

### Added
- first stable public release of Codex Pacer
- local-first Codex usage import, indexing, and overview analytics
- API-equivalent value estimation and subscription payoff tracking
- rolling `5-hour` and `7-day` quota tracking when available
- conversation-level drill-down across root sessions, subagents, models, and token metrics
- macOS menu bar integration and popup snapshot UI
- bilingual open-source repository documentation for the stable launch

### Changed
- repository surface, contributor guidance, and issue templates were aligned for the `v1.0.0` release
- stable release messaging now points contributors and users to the refreshed install, packaging, and release-note documents

### Fixed
- token accounting edge cases involving reasoning-output tokens
- pricing and model mapping gaps for newer GPT-5.x variants
- browser preview fallback behavior for Tauri-only APIs
- chart layout, popup UI regressions, and stale snapshot refresh issues

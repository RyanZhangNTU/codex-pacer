# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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

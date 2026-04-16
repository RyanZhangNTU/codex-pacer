# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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

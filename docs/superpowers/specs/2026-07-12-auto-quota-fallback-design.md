# Auto refresh quota fallback source precedence

## Context

The application has two refresh paths for online quota data. A manual refresh usually succeeds because it waits for a live app-server request. The background scheduler can occasionally fail that request and ask the live worker for a fallback value.

The fallback loader currently combines in-memory data, persisted `live` samples, and `session` history. It then selects the candidate with the greatest timestamp. That comparison treats an observation from an old session as equivalent to a successful online fetch. A later historical timestamp can therefore replace a valid online value.

## Decision

Fallback selection will respect source precedence before comparing timestamps:

1. A live value already confirmed by the current process remains the preferred value.
2. If the process has no confirmed live value, use the newest persisted `live` sample.
3. If no persisted live sample exists, keep an available display fallback.
4. Use `session` history only when no live value is available.

Timestamp ordering will apply only between values from the same source class. A `session` timestamp will never outrank an online value merely because it is later.

The existing cache field `last_live_success_at` identifies whether the current in-memory value has been produced by a live request in this process. Startup loading will also prefer persisted `live` data before loading `session` history, so the cache does not begin with a historical value when an online value is available.

## Data flow

When a live request fails, `AppLiveQuotaFetcher::fallback` will use the source-prioritized loader. If the cache contains a live value from the current process, the loader returns it without consulting session history. Otherwise it checks the database for `source_kind = 'live'`, then falls back to the existing display value or `source_kind = 'session'` history.

The runtime will continue to mark the live lane as needing refresh after a fallback. This change affects which value is displayed while the retry is pending. It does not suppress retries, change refresh intervals, or turn a fallback into a fresh live success.

## Implementation scope

- Update `src-tauri/src/lib.rs` so automatic fallback loading separates persisted live samples from session history.
- Update startup fallback selection to use the same source precedence.
- Keep existing timestamp comparison helpers for candidates that share the same source class.
- Add regression tests for a later session timestamp failing to replace a current in-memory live value.
- Add regression coverage showing that persisted live data wins over a newer session record and that session history remains available when no live data exists.

No frontend behavior or database schema changes are required.

## Error handling

If the database cannot be opened, the loader returns the available in-memory value. If no in-memory or persisted live value exists, the loader may return a session fallback as it does today. A fallback never updates the live success timestamp and remains eligible for another live refresh.

## Verification

The implementation will follow a red, green, refactor cycle:

1. Add the regression tests and run them to confirm the current mixed-source selection fails.
2. Implement the smallest source-priority change.
3. Run the focused Rust tests, the existing refresh event tests, the full Rust test suite, lint, and the frontend build.

Acceptance requires that a newer session timestamp cannot replace a current live value during a failed background refresh, while the existing historical fallback behavior still works when no live data is available.

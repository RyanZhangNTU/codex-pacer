# Development and data semantics

## Structure

- `native/Sources/PacerCore`: quota decoding, task lifecycle, rate estimates, source discovery, transport, completion retention and window geometry.
- `native/Sources/PacerIsland`: SwiftUI/AppKit presentation, settings, notifications and native glass.
- `native/Tests/PacerCoreTests`: regression coverage for lifecycle, privacy, transport, rate calculation, account isolation, retention, geometry, singleton locking and preferences migration.
- `scripts/native`: isolated local build/test entry points.
- `scripts/performance`: controlled event and native UI replays; see [measurements and reproduction](performance.md).
- `scripts/release`: native signing, notarization and publication.
- `marketing`: editable Chinese campaign source and reproducible exports.

Run `make test` and `make build` with Xcode 26 or newer. Both copy native sources into `/private/tmp` with isolated SwiftPM/module caches, avoiding iCloud metadata and restricted shared caches. The executable remains `CodexPacerIsland`; the user-facing app is Codex Pacer. `native/Info.plist` is the production version source.

Development builds are ad hoc signed. The build prints its app path; open that app in Finder for UI checks. Exit the installed app first: all copies share the same singleton lock. Demo arguments `--demo` and `--demo-completion` supply labeled sample data without querying Codex. `--demo-notch` supplies hardware-notch geometry for marketing on virtual displays; production mode uses the screen’s own safe areas. Command+1/2/3/4 switches synthetic thinking/tool/reply/completion events through the same runtime projection. Demo clicks open an explicitly labeled sample destination, never a real conversation. `--expanded` starts with the island open. Command-line diagnostics `--diagnose` and `--diagnose-events --observe-seconds 20` report protocol/counter availability without credentials, account identity or task text.

## Data and calculation

Quota comes from a dedicated read-only Codex app-server connection using `account/read` and `account/rateLimits/read`. No turns are created or resumed. Missing data remains unavailable. Multiple service buckets take precedence over a legacy single-bucket response. Credit and reset details are read from the service, without API-price conversions.

Pace is remaining quota percentage divided by remaining time percentage, multiplied by 100. Values below 85% indicate faster consumption; above 115% indicate spare capacity. The value is capped at 1000%; stale/expired windows have no live pace. The curve is isolated by hashed account/workspace identity and service reset date. A reset starts a new seven-day cycle. Expiry markers are only for available banked resets that expire inside that cycle; they do not redefine its start/end.

The output-rate estimate uses increases in cumulative output tokens and excludes confirmed blocking-tool intervals, input tokens and internal reviews. Model generation events resume measurement even when a background tool exists. Running-task estimates aggregate across sources independently of row selection. A sample is fresh for 15 seconds; pauses retain a gray estimate. New turns, counter rollback and matching turn completion clear it. Mid-turn reconnects seed a partial baseline. Reporting/network delay can remain in the denominator; this is not a model-side decode benchmark.

Local Desktop IPC and remote app-server subscriptions project only lifecycle, timestamps, bounded display metadata and output counters. Prompt text, reasoning, tool arguments/output and authentication data are excluded. One startup log scan fills gaps; fallback scans run every 120 seconds while connected or 60 seconds while disconnected. Stream-evidenced threads are skipped. The visible clock updates do not trigger frequent log scans.

Desktop IPC is private and version dependent. Sender identity, protocol/version and consecutive revisions are checked; gaps request a new snapshot with bounded retries. Unsupported sessions fall back to sanitized logs. Silence and orphan terminals cannot end an active turn. Connection success does not prove every client is observed.

SSH uses enabled discovered aliases, known host keys and existing non-interactive authentication. Agent/port forwarding are disabled. Pacer never modifies or restarts shared Codex processes. Source changes, sleep and quit close only Pacer-owned helpers; stdin EOF and broken stdout end remote helpers. Keep real subprocess lifecycle tests when changing shutdown behavior.

## Persistence and verification

The production bundle is `com.codexpacer.app`. A one-time allowlist migration copies unset native preview preferences; existing production choices take precedence. `~/Library/Application Support/CodexPacerIsland` remains the cache/lock location for continuity. Completed cards and unread reminders are in memory; startup history does not replay old alerts.

After presentation changes, check the actual app: expand/collapse with fixed top anchoring, rapid reversal, pin/Esc, menu-bar visibility, settings save, quota states, expiry-marker hover/tap and both quit controls. Check reduced motion/transparency and older macOS separately when those behaviors change. Source tests do not establish live appearance, protected Codex deep-link behavior or every OS/display configuration.

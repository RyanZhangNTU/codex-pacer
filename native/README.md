# Codex Pacer Island preview

The macOS version of Codex Pacer is being rebuilt around current task activity and account quota. This preview uses SwiftUI and AppKit. It has no historical analytics, pricing engine, SQLite database, or API value calculation.

## Build and run

Requires macOS 14 or later and Xcode with a Swift 5.10 or newer toolchain.

```sh
npm run island:test
npm run island:build
open "output/island-preview/Codex Pacer Island.app"
```

The scripts copy the Swift package to a temporary local directory before building. This avoids iCloud build metadata and keeps compiler caches outside the source tree. The resulting app is ad hoc signed for local testing. It is not a notarized distribution.

The preview uses bundle ID `com.codexpacer.island.preview`, separate from the existing Tauri app. Settings stay in the preview's preferences. The old app's database is not migrated.

For a UI demonstration without reading Codex data:

```sh
open "output/island-preview/Codex Pacer Island.app" --args --demo
```

For a live quota connection check without displaying account identity or task text:

```sh
"output/island-preview/Codex Pacer Island.app/Contents/MacOS/CodexPacerIsland" --diagnose
```

## Interaction

- Hover to expand. Move away to collapse after a short delay.
- Click the compact strip or the pin button to keep it open.
- Click outside, press Escape while the app has keyboard focus, or use the collapse button to close it.
- Left-click the menu bar item to show or collapse the island. Right-click for refresh, settings, and quit.
- Settings select a display, floating capsule mode, fullscreen visibility, Codex executable, and Codex home.

The app uses the physical notch's safe area when available. Other displays use a capsule below the menu bar. Hovering uses a nonactivating panel; settings are a normal keyboard-focused window.

## Data boundaries

Quota comes from a dedicated `codex app-server` process using only initialization and `account/rateLimits/read`. The app never starts or resumes a Codex turn. Codex owns authentication; the preview does not read or copy tokens. App-server remains an evolving protocol, so unavailable and malformed responses are handled explicitly.

Multi-bucket responses take precedence over the legacy single-bucket response. Window labels use the reported duration. Null usage stays unavailable. Expired reset timestamps do not imply restored quota. Failed reads keep the last snapshot with its age; changing the source clears it.

Quota refreshes every 30 seconds while expanded and every two minutes in the background, with bounded backoff on errors. Sleep pauses updates; wake requests fresh data. These intervals are initial defaults, not measured performance claims.

Activity reads at most 16 recent JSONL files from today's and yesterday's local session directories. Initial and catch-up reads are capped at 128 KiB per file. Files and directories are watched, with a periodic bounded discovery pass for rollover and missed events. Conversation text is not stored.

Only explicit `task_started`, `task_complete`, and `turn_aborted` events determine lifecycle state. Unmatched completions cannot end a newer turn. A task with no observed event for three minutes becomes unconfirmed. A completion means the task ended; it does not prove the work succeeded. Waiting for approval, remote tasks, and global desktop status are not inferred in this preview. Account quota can include usage from other devices.

## Architecture

- `PacerCore`: quota normalization, lifecycle reduction, bounded log reads, and reusable RPC transport.
- `PacerIsland`: observable state, adaptive refresh, file watches, native panel geometry, SwiftUI views, and settings.
- `PacerCoreTests`: missing and multi-bucket quota, stale data, lifecycle ordering, partial/rotated logs, concurrent refresh, and transport timeout coverage.

Interface inspiration: [boring.notch](https://github.com/TheBoredTeam/boring.notch), [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit), and [CodexBar](https://github.com/steipete/CodexBar). This package has no third-party Swift dependencies and incorporates no source from those projects.

Before release, verify physical-notch and external-display placement, fullscreen/Spaces, pointer and keyboard behavior, sleep/wake, account-source switching, VoiceOver, and CPU/memory including the app-server child. Native UI checks and automated core tests provide different evidence.

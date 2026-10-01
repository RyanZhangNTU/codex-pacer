# Codex Pacer Island preview

The native macOS app focuses on task interaction, account quota and pacing. SwiftUI and AppKit provide the island window; Swift Charts displays the current quota cycle. There are no model-price calculations or historical usage analytics.

## Build and run

Requires macOS 14 or later and Xcode with Swift 5.10 or newer.

~~~sh
npm run island:test
npm run island:build
open "output/island-preview/Codex Pacer Island.app"
~~~

The scripts build and sign in a local temporary directory, then validate the copied app. The preview is ad hoc signed for local testing and is not notarized. Its bundle ID, com.codexpacer.island.preview, is separate from the Tauri app.

Quit a running preview before using launch flags:

~~~sh
open "output/island-preview/Codex Pacer Island.app" --args --demo
open "output/island-preview/Codex Pacer Island.app" --args --demo --quota
open "output/island-preview/Codex Pacer Island.app" --args --expanded
"output/island-preview/Codex Pacer Island.app/Contents/MacOS/CodexPacerIsland" --diagnose
~~~

Demo mode labels its sample data and does not query Codex. The diagnostic prints connection availability and window durations, without account identity, credentials or task text.

## Task interaction

Hover to expand; move away to collapse after a short delay. Click the top strip or pin button to keep it open. Select a task to open its conversation. The headline state and output rate summarize all running user tasks and do not follow the selection. Input waits appear ahead of running tasks. The task action opens the selected conversation when it belongs to the default local Codex home; other sources open Codex without assuming that its desktop profile matches.

Left-click the menu bar item to show or collapse the island; right-click for actions. Escape closes a keyboard-focused island. Hovering does not request keyboard focus; pinning or explicitly opening the panel does. Settings select the display, floating mode, fullscreen visibility, quota metric, source and reminders. Data and calculation notes are collapsed in settings; the island shows only task details, quota and the current curve.

Task state comes from local JSONL events. task_started and turn_context anchor the current turn. task_complete and turn_aborted apply only to that matching turn; an unpaired completion cannot end an unobserved turn. Fresh reasoning and tool calls restore active status when a start was missed. Tool call/output pairs provide recent execution stages. The synchronous request_user_input call waits for its matching result; request_user_input_async does not mark a task as waiting. Neither tool arguments requesting escalation nor an old heartbeat prove that approval is pending.

Metadata reads are bounded to 1 MiB. Startup tails use 512 KiB per file and catch-up tails use 128 KiB; a bounded backward scan of up to 8 MiB recovers the latest turn anchor when it lies outside that tail. Up to 16 user files in today's and yesterday's directories are monitored. Internal guardian/auto-review sources are filtered before that limit, with the codex-auto-review model as a fallback. Source metadata survives skipped data and rotation. File watches and a discovery pass handle new files and rotation. A task with no observed event for three minutes becomes unconfirmed; its last known wait remains visible as a last known state. A matched completion displays idle. It does not declare the user's overall task finished. Silent active turns remain unconfirmed rather than becoming completed. Conversation content is not retained.

Remote tasks and global desktop approval state are not reliably covered by this adapter. A separate app-server process cannot observe every other client. The preview does not start, restart or modify a shared Codex daemon to manufacture runtime status.

## token/s

The estimate uses increases in total_token_usage.output_tokens over report intervals. Input tokens are excluded. Samples over recent intervals are combined, count rollback clears the estimate, idle gaps are excluded at turn boundaries, and the display expires after 15 seconds without a report. At least two usable counter readings are needed unless a previous session counter anchors a new turn.

The value includes waiting and tool time between reports. It is not a direct measurement of model-side decode throughput. The island sums fresh rates across all running user tasks. Waiting, ended, stale and internal review turns contribute no samples. When no fresh rate exists, the aggregate is unavailable. Selecting a conversation cannot change it.

## Quota, pacing and current-cycle curve

Quota uses a dedicated read-only codex app-server connection. Initialization, account/read and account/rateLimits/read do not start or resume turns. The workspace identifier returned by Codex is hashed for isolation. The preview does not read or copy authentication tokens. Authentication file metadata changes reconnect the client.

Multi-bucket responses take precedence over the legacy view. Window labels follow the reported duration, and missing usage stays unavailable. Account quota may include usage from other devices.

Pacing preserves the original formula: remaining quota percentage divided by remaining time percentage, multiplied by 100. The original 85% and 115% thresholds indicate faster consumption and more spare capacity. The value is capped at 1000%; an expired or stale window has no live pace estimate.

Only the current seven-day curve is recorded per bucket. A changed reset deadline starts a fresh cycle, including an early manual reset. Small deadline corrections preserve a curve; a quota recovery with a forward reset deadline still starts a new one. Out-of-order snapshots cannot restore an older cycle. Expired cycles and points older than seven days are pruned.

Every valid refresh contributes an actual reading. Storage is bounded to 20,161 readings per curve. The chart displays a subset of actual points with their original endpoints; it does not invent a full-quota starting point. Its dashed line is an explicitly labeled uniform-pacing reference.

The private cache under Application Support/CodexPacerIsland/CurrentCycle contains only the current quota snapshot and cycle points. Files are isolated by Codex home, have owner-only access, and load only after a matching workspace has been verified. Switching account or workspace discards the previous account's active curve. No seven-day history is imported from the old database.

Refreshes use 30-second intervals while expanded and two-minute intervals in the background, with bounded error backoff. Failed reads show cached data with its age; they never add curve points. Sleep pauses work, wake requests new data, and source changes reject obsolete responses.

## Reminders and validation

Low-quota and input-wait reminders appear briefly in the island. Turn-end reminders are optional. Startup task events are not replayed, and repeated quota refreshes do not repeat a low-quota alert. System notifications stay off until the user enables them and grants macOS permission. Project names can be hidden in the interface and new notices.

The core tests cover pacing, reset and account boundaries, current-cycle persistence, token-rate estimation, synchronous input waits, late tool responses, reminder deduplication, geometry, and RPC timeout/reconnection.

Before release, check physical-notch and external-display behavior, fullscreen/Spaces, keyboard and pointer focus, sleep/wake, settings, source/account switching, notification permissions, VoiceOver, and CPU/memory including the child app-server. Automated tests and screenshots provide different evidence.

Interface references: boring.notch, DynamicNotchKit and CodexBar. The package has no third-party Swift dependencies and copies no source from those projects.

# Codex Pacer Island preview

The native macOS app focuses on task interaction, account quota and pacing. SwiftUI and AppKit provide the island window; Swift Charts displays the current quota cycle. There are no model-price calculations or historical usage analytics.

## Build and run

Requires Xcode 26 or newer to build. The app runs on macOS 14 or later; native Liquid Glass is available on macOS 26 or later.

~~~sh
npm run island:test
npm run island:build
open "output/island-preview/Codex Pacer Island.app"
~~~

The scripts build and sign in a local temporary directory, then validate the copied app. The preview is ad hoc signed for local testing and is not notarized. Its bundle ID, com.codexpacer.island.preview, is separate from the Tauri app.

Quit a running preview before using launch flags:

~~~sh
open "output/island-preview/Codex Pacer Island.app" --args --demo
open "output/island-preview/Codex Pacer Island.app" --args --demo --demo-completion
open "output/island-preview/Codex Pacer Island.app" --args --expanded
"output/island-preview/Codex Pacer Island.app/Contents/MacOS/CodexPacerIsland" --diagnose
~~~

Demo mode labels its sample data and does not query Codex. The diagnostic prints connection availability and window durations, without account identity, credentials or task text.

## Task interaction

Hover to expand; move away to collapse after a short delay. Click the top strip or pin button to keep it open. One panel shows the global state and output rate, task cards, quota, account details and the current curve. There is no task/quota tab switch.

Task cards show the Codex conversation title, current stage and source host. Click a card to open that conversation directly. SSH links include the configured host ID; local links use the default desktop Codex home. Unsupported local profiles have a disabled card rather than opening a different conversation. Waiting tasks appear first, and order within each state follows the turn start/change time so counter updates do not move a task under the pointer.

Left-click the menu bar item to show or collapse the island; right-click for actions. Escape closes a keyboard-focused island. Hovering does not request keyboard focus; pinning or explicitly opening the panel does. Settings select the display, floating mode, fullscreen visibility, quota metric, source and reminders. Data and calculation notes are collapsed in settings; the island shows only task details, quota and the current curve.

Settings → Display → Appearance selects Classic or Liquid Glass. macOS 26 and later default to the native regular glass material, applied once to the island shell; task cards and charts retain their existing layout. The selection is saved and applies without restarting or reconnecting task sources. Earlier systems use Classic. Reduce Transparency uses the solid shell while preserving the saved preference. The strip beside a physical notch stays black when collapsed; expanding uses one glass surface without a separate black header band.

When Liquid Glass is selected, its settings offer Regular/Clear material, transparency, Neutral/Cool/Warm tint and corner radius, with a live local preview and Restore Defaults. Changes apply to the island only when saved; Cancel discards the draft. Transparency adjusts the dark content backing within a readable range; it is a relative control, not the native material's alpha. The system controls blur and refraction. Classic keeps its existing shape and colors. Defaults are Regular, 50% transparency, Neutral tint and a 27-point corner radius.

Task state updates through subscriptions: the existing app-server Unix WebSocket endpoint, or Desktop IPC v11 on local macOS when that endpoint is absent. JSONL is used for startup and low-frequency fallback. task_started and turn_context anchor the current turn. task_complete and turn_aborted apply only to that matching turn; an unpaired completion cannot end an unobserved turn. Fresh reasoning and tool calls restore active status when a start was missed. Tool call/output pairs provide recent execution stages. The synchronous request_user_input call waits for its matching result; request_user_input_async does not mark a task as waiting. Neither tool arguments requesting escalation nor an old heartbeat prove that approval is pending.

Metadata reads are bounded to 1 MiB. Startup tails use 512 KiB per file and catch-up tails use 128 KiB; a bounded backward scan of up to 8 MiB recovers the latest turn anchor when it lies outside that tail. The read-only Codex session index supplements recent date directories, so resumed sessions are not restricted to their creation day. Up to 16 user files are considered for fallback; already observed active turns retain discovery slots. Internal guardian/auto-review sources are filtered before that limit, with the codex-auto-review model as a fallback. Source metadata survives skipped data and rotation. No filesystem watcher runs in the app. Discovery runs every 120 seconds with a connected subscription, or every 60 seconds when unavailable. Logs of stream-evidenced active tasks are skipped. An observed active turn remains active through long tool calls until a matching end. At startup, old unfinished logs without recent evidence are unconfirmed. A matched completion card displays "本轮结束". It does not declare the user's overall task finished. Silence does not declare a task completed. Conversation content is not retained.

SSH tasks are collected from the enabled SSH aliases saved by Codex. Existing non-interactive OpenSSH authentication and Python 3 are required. Global desktop approval state and remote-control Windows hosts are not covered. A separate app-server process cannot observe every other client. The preview does not start, restart or modify a shared Codex daemon to manufacture runtime status.

Ended and interrupted turns stay in the list until clicked, their state changes, or their retention time expires. Retention defaults to 30 minutes; settings offer 5 or 15 minutes, one or four hours, and until clicked. The in-memory inbox keeps an observed ended turn even if its source reader drops that file from its discovery slots. Clicking dismisses only that ended turn; a new turn can appear and notify again.

The collapsed island shows a checkmark (pause icon for interruption) and the count of unviewed ended turns. Click this status to open the newest conversation directly. Hovering or expanding does not dismiss it. The reminder remains until click, state change or expiry, respects reduced motion, and does not replay old completion alerts at startup. The completion reminder setting controls the collapsed prompt and optional system notifications. Task retention is independent of that setting.

## token/s

The estimate uses increases in the service's cumulative output token counter, subtracting confirmed blocking-tool intervals. Input tokens and internal reviews are excluded. Model generation signals resume measurement even if a background tool is still running. Samples are combined across running user tasks; selecting a task does not change the aggregate.

A report is fresh for 15 seconds. A pause retains the latest estimate in gray. Before a usable sample exists, the collapsed strip hides both the speed and its unit; the expanded panel shows sampling. New turns, counter rollback and matching turn completion clear the retained estimate. A snapshot received mid-turn seeds a partial counter baseline instead of assigning prior tokens to the short interval since connection.

Network and reporting delay may remain in the denominator. This is a generation-period estimate, not a direct measurement of model-side decode throughput.

## SSH sources

The monitor opens its own SSH connections to Codex's enabled, discovered aliases. It validates host aliases, requires known host keys, disables agent forwarding and port forwards, and does not install anything or alter the shared Codex process. A persistent Python helper subscribes to the existing app-server and batches sanitized lifecycle signals, names and output counters over 250 ms. It performs one startup log scan; later fallback scans run every 120 seconds while connected or every 60 seconds while disconnected, skipping stream-evidenced threads. Prompt text, reasoning content, tool arguments/output and authentication data are excluded from the transport.

Remote tasks use the same lifecycle parser and auto-review filter as local tasks. The list labels the source host; counts and throughput aggregate both sources. Connection failures expose a short SSH status with source details on hover, and retries are bounded. Source changes, sleep and quit close only the monitor's own connections. The SSH option can be disabled in settings.

## Realtime subscriptions

Subscriptions are the default for both local and SSH tasks. No file-change observer or two-second log polling runs in the native app. The 30-second folded clock and two-second expanded clock update visible time and check connection health; they do not trigger frequent log reads.

A connection does not prove every task is subscribed. SSH loaded-thread metadata excludes internal reviews and rejoins only active threads, without model input or configuration overrides. Local Desktop IPC follows advertised local streams and excludes review sources and review items. It never accepts routed task operations. Unsupported CLI sessions remain discoverable through the low-frequency fallback.

The Desktop adapter checks sender identity, protocol version and consecutive state revisions. It stores only turn/item identifiers and statuses, timestamps, output counts and display metadata. Snapshot bodies are discarded after projection; prompt and tool content are not retained. Version gaps invalidate that stream and request a fresh snapshot with a 30-second retry bound. Orphan terminals and idle runtime status cannot mark an active turn finished. Reconnection seeds a partial rate baseline.

Desktop IPC is private and version dependent. A long-history initial snapshot can be large; its frame bound is 16 MiB. Connections stay open to avoid repeated snapshots. A future incompatible Desktop release falls back to logs. Shared Codex processes are never started, restarted or killed. Sleep and quit close only Pacer's own helpers.

SSH stdin stays open for the lifetime of its owner. Owner EOF ends the remote helper; a broken output pipe also ends either helper immediately. Output failure never enters the connection retry loop. The 2026-10-02 performance check found and removed three orphaned helpers from an earlier diagnostic, then verified graceful shutdown and simulated owner crash on real SSH hosts.

~~~sh
"output/island-preview/Codex Pacer Island.app/Contents/MacOS/CodexPacerIsland" --diagnose-events --observe-seconds 20
~~~

Diagnostics report connection/subscription counts, fallback scans, file-watch status and helper CPU time without account identity or conversation content. See [the subscription validation record](../docs/zh-CN/realtime-experiment.md).

## Quota, pacing and current-cycle curve

Quota uses a dedicated read-only codex app-server connection. Initialization, account/read and account/rateLimits/read do not start or resume turns. The workspace identifier returned by Codex is hashed for isolation. The preview does not read or copy authentication tokens. Authentication file metadata changes reconnect the client.

Multi-bucket responses take precedence over the legacy view. Window labels follow the reported duration, and missing usage stays unavailable. Account quota may include usage from other devices.

Pacing preserves the original formula: remaining quota percentage divided by remaining time percentage, multiplied by 100. The original 85% and 115% thresholds indicate faster consumption and more spare capacity. The value is capped at 1000%; an expired or stale window has no live pace estimate.

Only the current seven-day curve is recorded per bucket. A changed reset deadline starts a fresh cycle, including an early manual reset. Small deadline corrections preserve a curve; a quota recovery with a forward reset deadline still starts a new one. Out-of-order snapshots cannot restore an older cycle. Expired cycles and points older than seven days are pruned.

Every valid refresh contributes an actual reading. Storage is bounded to 20,161 readings per curve. The chart displays a subset of actual points with their original endpoints; it does not invent a full-quota starting point. Its dashed line is an explicitly labeled uniform-pacing reference.

The private cache under Application Support/CodexPacerIsland/CurrentCycle contains only the current quota snapshot and cycle points. Files are isolated by Codex home, have owner-only access, and load only after a matching workspace has been verified. Switching account or workspace discards the previous account's active curve. No seven-day history is imported from the old database.

Refreshes use 30-second intervals while expanded and two-minute intervals in the background, with bounded error backoff. Failed reads show cached data with its age; they never add curve points. Sleep pauses work, wake requests new data, and source changes reject obsolete responses.

## Account usage details

The quota strip pairs remaining allowance with elapsed window time and a reset countdown. These use the same reset deadline and reported duration, including early resets; expiry fills the time track without inventing a new window.

The account row displays the backend's available reset count, the earliest future expiry among available reset credits, and the returned credit balance. Reset detail reads are explicitly enabled. A capped detail list does not replace the backend count; its earliest known expiry is labeled accordingly. Unavailable values show a dash, and unlimited credit is distinct from a missing balance. Expiring known resets decrease the displayed count until the next refresh. Balance values retain decimal precision in storage and are formatted for display without conversion to token or API prices.

Reset credits and purchased usage credits are separate. See [banked resets](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work) and [usage credits](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-personal-plans). The app displays these fields through the read-only account/rateLimits/read call and provides no redemption or purchase action. A returned account identifier must match the verified account before the response is accepted.

## Reminders and validation

Low-quota and input-wait reminders appear briefly in the island. Turn-end reminders are optional. Startup task events are not replayed, and repeated quota refreshes do not repeat a low-quota alert. System notifications stay off until the user enables them and grants macOS permission. Project names can be hidden in the interface and new notices.

The core tests cover pacing, reset and account boundaries, current-cycle persistence, token-rate estimation, synchronous input waits, late tool responses, reminder deduplication, geometry, and RPC timeout/reconnection.

Before release, check physical-notch and external-display behavior, fullscreen/Spaces, keyboard and pointer focus, sleep/wake, settings, source/account switching, notification permissions, VoiceOver, and CPU/memory including the child app-server. Automated tests and screenshots provide different evidence.

Interface references: boring.notch, DynamicNotchKit and CodexBar. The package has no third-party Swift dependencies and copies no source from those projects.

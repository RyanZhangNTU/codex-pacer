# Changelog

## 3.0.0 (development candidate)

- Add independently enabled Codex and Claude modules, installation-based defaults and persistent manual overrides.
- Include Codex Remote Control task stages, available performance data, attention and agent grouping through the connected Desktop owner's stream, with a Codex-specific setting independent of SSH. Codex must remain open and connected with the conversation loaded by a stream owner; this source has no independent remote-host discovery or log fallback. See [upstream PR #77](https://github.com/RyanZhangNTU/codex-pacer/pull/77) and [data semantics](docs/development.md#codex-accounting-and-lifecycle).
- Keep cached Remote Control counters as baselines rather than new measurements. Unseen first output remains unknown, and the inherited mid-request counter fallback is approximate and can still inflate TPS; it has no independent request-log correction. See the [merged rate implementation](https://github.com/RyanZhangNTU/codex-pacer/blob/6d76642ead54c3c721f1f5fc5b64c834b220f89f/native/Sources/PacerCore/GenerationRate.swift) and [documented limits](docs/development.md#codex-accounting-and-lifecycle).
- Combine local and SSH tasks in one provider-colored list. Show Codex/Claude quota and remaining time together in nested rings with tiny 5h/7d controls; a single provider's ring layout shows both periods, with a confirmed weekly-only PRO placeholder. When only Codex is enabled and its primary account reports limits without a 5h window, restore the original quota bars for all actual windows, including nonstandard or unspecified durations. Keep quota history and full details in Settings. Keep collapsed quota values separate while aggregating tasks and available throughput.
- Use lighter ring strokes around the central quota value and compact reset countdown. Disclose normal source/update details in hover help and Settings while retaining stale/error indicators. Show compact percentages with provider color alone, keeping full names in accessibility and help.
- Isolate task identity, parent/agent grouping, attention, completion retention, quota history and module shutdown by provider; preserve existing Codex identity and caches.
- Add bounded native Claude transcript, hook and numeric OTLP collection, owned Python 3.6+ SSH helpers, and additive monitoring setup that preserves existing configuration.
- Prefer fresh account-matched status-line quota and a Pacer-owned WebKit sign-in session, with explicit organization selection and read-only Web quota GETs. Production performs no foreign Keychain/Safe Storage reads; legacy own-cache/environment/file sources remain quiet compatibility fallbacks.
- Use matching Claude numeric request measurements, or observed throughput estimates after a verified stop; only actual partial display callbacks or reported TTFT establish first-output timing. Open Claude through mapped Desktop sessions or validated CLI resume paths; observed child tasks can route to a validated parent session without guessing its path.
- Keep successfully opened completion cards dismissed across normal relaunch using bounded, source-scoped hashes. A verified parent open acknowledges only captured, matching already-terminal descendants; running children, late endings, new turns, changed sources and Terminal/failure outcomes remain protected.
- Reduce repeated directory scans, transcript parses, unchanged-EOF reads and noneligible display-hook writes; reuse task grouping without reusing stale freshness clocks.
- Release Settings hosting content on save, cancellation and window close, while retaining its native window geometry for reopening.
- Redesign the island and Settings: one outline status icon family in tinted tiles, two-line task rows with right-aligned TPS/TTFT, cleaner quota rings with the period switch in the quota header, and a sidebar Settings window with per-provider pages that remembers the last pane.
- Route the sign-in window's Command-Return action before focused web content, while preserving ordinary Return and native window-close behavior.
- Confirm foreground and background Agent endings from owned result/engine-notification evidence, exclude unstarted internal agents, and preserve genuinely running background tasks.
- Read the owned SSH hook spool before transcripts during cold replay and concurrent appends, preserving exact terminal evidence without a timeout heuristic.

## 2.4.0

- Customize the single-line collapsed bar with task/performance/quota/warning categories, drag ordering, left/right placement and a live preview; apply with one Save action, cancel changes or restore defaults.
- Fit adaptive collapsed width to the visible components while preserving the hardware camera gap, expanded task/quota layout and existing collection frequency.
- Fix Python 3.6 SSH log timestamp parsing, isolate failed scans from healthy subscriptions, and prevent recurring helper errors from spinning without heartbeats.
- Use a numeric task badge, retain the latest TTFT in seconds, consolidate quota/pace labels and percentages, and show low-quota, delayed-update and SSH warnings only on issues.

## 2.3.2

- Preserve pending model-response timing across nested tools so delayed usage cannot divide a full request's output by the gap between tools.
- Apply authoritative request-log corrections to retained TPS and prevent older runtime caches from restoring an inflated value; preserve the original freshness timestamp.

## 2.3.1

- Group spawned agents under their parent conversation, show the running descendant count and add the available parent/child TPS without duplicate task rows or totals.
- Recognize Desktop subAgentActivity and runtime collaboration metadata; keep only thread relationships and status, with bounded discovery and log reads.
- Ignore copied ancestor history in forked agent logs so it cannot replace the child identity, seed its rate or suppress its exact usage.
- Retain each chat's last measured TPS across tools and new turns; use white for measurements updated within 15 seconds and gray afterwards, without a tilde. Reset accounting baselines independently.
- Keep first-output latency stable within a turn across partial reads and source replacement; retain SSH text-presence markers, recover complete log timing windows and import service-reported timing.

## 2.3.0

- Show settled per-request output throughput using authoritative usage, including reasoning once and excluding tool waits; supplement local and SSH streams with bounded, incremental request logs.
- Display observed first-output latency in each task and retain the last measured response through sparse usage reports and completion.
- Automatically coalesce ordinary updates at five seconds collapsed and one second expanded; flush pending data on expansion and handle first output, tool waits, lifecycle and attention immediately.
- Settle usage before a same-batch completion, keep metric-only updates independent of task lifecycle, and show global total TPS by summing available rates across active chats.

## 2.2.2

- Click the available-reset count to view exact expiry times, including deadlines beyond the weekly chart; distinguish unknown expiry details and non-expiring resets.
- Exclude ephemeral conversations from task and input-reminder lists, preventing duplicate entries that cannot open; preserve normal input and approval reminders.
- Apply remote session-name updates to running tasks and retained completion cards, including automatic naming after the first turn; preserve known names when live metadata is incomplete.
- Keep status text and token rates fully visible in adaptive Notch mode on displays without a camera gap.

## 2.2.1

- Support custom and adaptive width modes.

## 2.2.0

- Flush queued SSH completions before disconnect, discover later loaded tasks through bounded pagination, and prevent retired-turn events or stale fallback logs from overriding current state.
- Recognize live SSH tasks without a fallback log when the host alias contains dots, including IP-address aliases.
- Keep completion reminders when a completed subscription has been released and a later unload/error status arrives.
- Preserve active turns and their endings when start timestamps are missing; notify once for short live turns completed within one UI batch, and normalize collaboration-tool wait states across local and SSH sources.
- Seed output-rate counters independently for each turn, accumulate rapid updates, and expire stale numbers after 15 seconds without extra polling; prevent cached usage and delayed previous-turn reports from inflating new-turn speed.
- Discover new Desktop/SSH tasks from routing-index changes even when the owner emits no new following announcement.
- Run the usual local Desktop event subscription natively, skip transcript bodies and release historical item storage to reduce collection overhead.
- Retain five-minute weekly curve samples and coalesce normal cache writes over thirty minutes; flush on account/cycle changes, sleep and orderly exit.
- Keep nonblocking questions visible while a task continues running, observing both server requests and Desktop message questions for local and enabled SSH sources.
- Use approved native status icons with explicit task/reply/approval labels; show pending attention in matching task rows and keep quota warnings on the right.
- Show the current stage for a single running task and a task count for multiple tasks.
- Use Desktop hints and remote runtime-index changes to discover SSH activity, including when no Desktop owner announces a new turn; confirm states through the runtime and retain explicit completion reminders.
- Preserve a metadata-confirmed new turn when its first item supplies the turn ID, so an older completed log cannot hide running state or the next completion reminder.
- Keep the next turn in an open local conversation visible immediately, clear asynchronous reminders on steering replies, and preserve event order through connection shutdown.
- Preserve completion reminders across reconnects and failed conversation opens, exclude internal reviews, bound fallback transport, and improve CLI/application discovery and saved quota-window handling.

## 2.1.4

- Name the SSH source when one connection is unavailable, and show the number of disconnected SSH sources when there are several.
- Open Settings from the connection notice and list each disconnected SSH source in Data Sources.

## 2.1.3

- Restore the island's window level before its frame after dismissing update UI, keeping Notch mode attached to the screen's top edge.
- Retain the update-dialog focus and interaction fixes from 2.1.2.

## 2.1.2

- Keep update dialogs and installation controls accessible when the island is expanded or pinned.
- Collapse the island immediately and suspend its hover, pin and focus actions while update UI is open; restore normal interaction when the update is dismissed, cancelled or finished.
- Leave the island undisturbed during background checks that do not show an update.

## 2.1.1

- Add English and Simplified Chinese throughout the interface, with automatic macOS language selection and a language override in Settings.
- Add signed in-app updates with Sparkle: daily automatic checks, manual installation, and a Check for Updates entry in Settings and menus.
- Generate and verify signed update feeds during release packaging; publish only after both the feed and installer upload successfully.
- Add Automatic, Notch, and Floating display modes on every monitor, including non-Retina displays.
- Keep Notch mode attached to the top edge on monitors without a physical notch, without reserving a camera gap.
- Preserve existing display preferences when upgrading.
- Size the expanded panel to its content, including source and account notices.
- Page task lists three at a time, keeping the quota section in place while navigating.
- Discover CLI installations in relocated Codex apps and common Node/package-manager locations, and prepare their runtime PATH for GUI launches.
- Show actionable quota failures inline, including startup errors, RPC details and authentication-mode mismatches; add CLI discovery and connection testing in Settings.

## 2.0.0

- Replace the main-branch React/Tauri app with the native macOS island.
- Show local/SSH task stages, output-rate estimates, account quota, pacing and the current seven-day curve with banked-reset expiry annotations.
- Retain ended-turn cards with configurable reminders and add reliable quit controls.
- Support native Liquid Glass, optional menu-bar visibility and display/privacy settings.
- Preserve native preview preferences and caches when migrating to the production identity.
- Remove obsolete implementations, tests, experimental documents and in-app calculation explanations; retain meaningful native regressions.
- Ship a signed/notarized universal macOS DMG and Chinese promotional assets.

[Earlier versions](https://github.com/RyanZhangNTU/codex-pacer/releases) remain available with their tagged source.

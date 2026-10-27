# Changelog

## 4.0.0

- Add a DeepSeek Harness module beside Codex and Claude Code. Pacer reads Harness's own session logs on this Mac (`~/.dsh`, or `DSH_HOME`), which are compressed with Zstandard, and shows each session's stage, output speed, time to first output, turn time, model and reasoning effort, approvals and questions that wait for you, and how each turn ended, with completion cards, reminders and notifications like the other services. Only token counts and timing are kept; message text, reasoning and tool arguments are dropped while reading. A session left running when Harness quit becomes unconfirmed. Clicking a DeepSeek task brings Harness forward, since it has no link to a single conversation. The module turns itself on when Harness is installed and has its own Settings page, welcome card and app button. Harness sessions on SSH hosts are not followed yet.
- Show each DeepSeek turn's estimated cost before the model name, such as **≈¥0.42**, from its tokens and DeepSeek's published prices, doubled on Beijing weekdays 09:00–12:00 and 14:00–18:00. Public holidays are not known. Turn it off in **Settings → DeepSeek**.
- Read the DeepSeek balance the way Harness signs in. With a DeepSeek account, sign in to the DeepSeek platform once in Pacer's own window; the session stays in Pacer's private WebKit storage and reads only the wallet amounts, the platform's token estimate and its alert line. With an API key, paste a key in Settings; it is kept in your login keychain and sent only to the balance endpoint. Pacer never reads Harness's own credentials. **Balance source** in Settings can override the automatic choice.
- Draw DeepSeek's quota ring as a day dial: today on a 24-hour face with each hour's spend, amber arcs over the doubled-price hours, the current time and the balance with today's spend in the middle. With DeepSeek alone, Now, Today and Balance details sit beside it, above the last seven days of spend split into off-peak and peak. The expanded section is called **Quota & Balance**, or **Balance** with DeepSeek alone.
- Add the DeepSeek balance to the collapsed bar's alternating value; with DeepSeek alone, the bar shows the balance and today's spend. Add a low-balance warning (an outlined **¥**, solid when used up), on by default, and an optional blue **×2** while a DeepSeek task runs at peak price. The balance counts as low below the platform's alert line, or Pacer's own line (¥10 by default) when the platform has none, or with under three days left at the recent average; a system notification marks each crossing.
- Show the welcome guide again for 4.0, with a DeepSeek card that offers sign-in or a key as needed.

## 3.3.0

- Show each task's model and reasoning effort in the expanded island, right-aligned below the output speed in the service's color, for example **GPT-6.1 Sol High** or **Opus 5.5 XHigh**. Known Codex and Claude model identifiers are shortened, the full identifier appears when you hover, and effort levels are translated. Codex reads them from the turn's session log or the Codex app, and Claude Code from its conversation records, on this Mac, SSH hosts and Remote Control. A model is shown only for the turn that used it: a model change in the middle of a turn waits for the next one, and the row shows the service name until the model is known.
- Rework the task row's two lines without making it taller. The first line holds the title, limited so a long one can no longer widen the panel, then the speed and the turn time: counting up while the turn runs and showing how long it took once it ends. The second line holds the status, running agents and source, with a server icon for remote hosts. Time to first output moves to the speed's tooltip.
- Draw status icons as plain outlines without a tile. Endings you have already seen fade back, while unread endings, tasks waiting for you and failures keep their color, so the unread dot is no longer needed.

## 3.2.4

- Fix Claude tasks that could stay marked as running after Codex Pacer restarted, such as after an update. On restart Pacer reads its hook records in batches, and could reach a conversation's ending while an older batch still named the previous turn; it dropped that ending, and the next batch reopened the finished turn. Hook records are now read in full first, as they already were for SSH hosts. A task that was actually cut off shortly before a restart is checked again once its last activity is 15 minutes old instead of staying running.

## 3.2.3

- Default to the new Split Ring layout while retaining the original dashboard as **Classic** in **Settings → Appearance → Expanded Quota**. Switching applies immediately and the choice survives relaunch.
- Combine each service’s expanded quota windows in one ring: a shorter upper arc for 5 hours and a longer lower arc for 7 days, each with its own percentage, reset countdown and pace tick. Accounts without a 5-hour limit get a weekly gauge that opens at the bottom with **7d** in the opening, so a full ring never closes on itself. Codex-only accounts without a 5-hour limit now use it too; the quota bars remain for nonstandard limits and in Classic.
- With only one service enabled, place its ring on the left and its pace, reset time and forecast on the right. The forecast extends the spending so far to the reset and turns amber when quota would run out first. Weekly-only accounts show the same details as three rows: pace, reset and forecast.
- Keep missing and stale quota independent for each period. When a period has 15% or less left or is spending too fast, its label and percentage turn amber, for 7 days as well as 5 hours; the 5-hour arc also turns amber.

## 3.2.2

- Add a button for each enabled service's desktop app to the expanded island's task header, beside **Mark All as Read**, in the service's color. A click brings Codex or Claude forward, launching it if needed, even when that service has no task, and opens no conversation. A service whose desktop app isn't installed shows no button. Turn the buttons off with **Show App Buttons** in Settings → General; they are on by default and the switch is also offered in the 3.2.2 What's New note.
- Smooth the task badge's orbit when Codex and Claude run at the same time. Claude's arc used to blur ahead of its head and look twice as long as Codex's; both arcs now have a sharp head and the same shape. Each service keeps its own place on the ring, so one starting or stopping no longer makes the other jump half a turn, and an arc now grows in or fades out over about a third of a second instead of appearing or vanishing at once. The rotation no longer restarts when the badge switches between a task count and a stage icon.

## 3.2.1

- Add **Mark All as Read** next to the pin in the expanded island. One click clears every unread ended task on all pages, and cleared tasks stay cleared after a restart. Tasks that are running or waiting for a reply or approval, and sessions hidden in Settings, are left alone.
- Add **What's New** to Settings, above Help. It lists the highlights of every update since 3.1.0, newest first, with the same switches as the update note and a link to the full release notes.
- Fix Claude Desktop tasks that sometimes stayed marked as running after the reply finished. Desktop can save a record before the one it follows, such as an attachment before its tool result, so Pacer could not tell which prompt the final reply and its stop belonged to. Pacer now links them once the missing record arrives, even when it lands after the reply, and the task ends normally. This applies to local and SSH sessions alike; an ending from an earlier prompt still cannot end a newer one.
- Fix Codex Desktop questions that sometimes showed no reminder when Codex stopped sending live updates to Pacer. Pacer now also picks up the question from Codex's local session log, and the reminder clears once you reply or the turn ends. A question that moves between the two sources keeps a single reminder, and each new question still gets its own. Approval requests still rely on live updates.

## 3.2.0

- Replace the Automatic, Notch and Floating choices in Settings → Appearance with **Notch** and **Custom**. Custom places the island yourself under **Screen Position**: centered below the menu bar as before, or docked at any of the four corners as a narrow vertical strip whose long edge lies against the side of the screen, 10 points from the top or bottom. Choosing Custom over the notch starts at bottom left; a Mac that already floated keeps the centered bar.
- Stack the collapsed components in the docked strip, with each number on its own line above its unit so nothing is wider than an icon. The top and bottom groups stay at the strip's ends, and the panel opens beside it, aligned with the strip's top or bottom edge.
- Fix Claude Desktop tasks staying marked as running after the next-step box ends a turn. The task now shows as finished with a reply reminder until you answer, and sends one notification instead of two.

## 3.1.2

- Open a task in the app that started it. Claude tasks started in a terminal or an editor, and Claude or Codex tasks from apps that embed them, such as a Zotero plugin, show that app's name; clicking one switches to the app and relaunches it if it quit. Claude Desktop sessions still open in Claude Desktop, Codex tasks in the Codex app, and Claude sessions on SSH hosts still resume in Terminal.
- Stop resuming local Claude tasks in a new Terminal window or importing them into Claude Desktop. Pacer can only identify the app while a task runs; when it doesn't know, the click says so.
- Add **Show Claude Sessions from Other Apps** and **Show Codex Sessions from Other Apps** to Settings → Claude and Settings → Codex, on by default and offered once in the 3.1.2 What's New note. Turning one off hides those sessions, with their agents, questions and completion cards, until it is turned back on.
- Never show translation requests from the Zotero Agent plugin, which have no conversation to open.
- Fix answered Claude questions and approvals staying marked as waiting.

## 3.1.1

- Fix several bugs and improve overall stability.
- Make Remote Control task monitoring more reliable during long conversations.
- Show device names and clearer online, offline and waiting states for Remote Control connections.
- Keep completed remote task cards read after opening their conversations, including after a restart.

## 3.1.0

- Add Open at Login to Settings → General and the welcome guide. macOS keeps the choice in Login Items; when macOS still needs approval, Pacer says so and opens Login Items.
- Show a short What's New note once after an update, with any new setting it introduces. A fresh install sees the welcome guide instead.
- Fix ended Codex child tasks appearing to run again when an older parent status arrives. A newer activation can still start the child normally.
- Keep ended child tasks ended after Pacer reconnects to Codex, wakes from sleep or relaunches during the parent task, and release the parent's child states as soon as its turn finishes, so a finished conversation no longer stays marked as running.
- Keep parent status hints separate from the local log cache, so removing a running hint restores the task's recorded state without requiring another log write. Confirmed endings remain effective after the parent subscription closes.

## 3.0.1

- Sign Codex Pacer with Developer ID and notarize it with Apple, so a new install opens after the standard macOS confirmation without **Open Anyway** in System Settings. Installed 3.0.0 copies update in place as before.
- Notarize releases through a `notarytool` Keychain profile only, so the release scripts never handle the Apple password.

## 3.0.0

Codex Pacer now follows Claude Code as well as Codex.

### Claude Code and modules

- Show Claude Code tasks from this Mac and SSH hosts next to Codex tasks, with stages, replies and approvals that need you, endings, spawned agents, output speed and time to first output from Claude Code's own telemetry.
- Show Claude quota for its 5-hour and 7-day windows, from Claude Code's status line or a claude.ai session in Pacer's own sign-in window, with an explicit choice when an account has several organizations. Pacer never reads other apps' Keychain items or browser cookies.
- Make Codex and Claude independent modules. Each turns on automatically when its app or CLI is installed; an explicit choice sticks until you restore automatic detection.
- Set up Claude Code monitoring automatically: Pacer adds its own hooks and a local-only telemetry endpoint next to existing settings, on this Mac and on connected SSH hosts that have Claude Code, and removes the local entries when the module is turned off by hand.
- Follow the SSH hosts managed in Codex and Claude, including Claude Desktop's saved connections and their ports and identity files, so hosts no longer need to be added in Pacer.
- Add Codex Remote Control tasks through the connected Codex app ([#77](https://github.com/RyanZhangNTU/codex-pacer/pull/77)). An idle Remote Control connection shows as waiting for a session.
- Open Claude tasks in their Claude Desktop session, or resume them in Terminal.

### The island

- Merge the status icon and task count into one activity badge: an orbit in each provider's color while tasks run, solid amber when a task needs you, and marks for unread endings.
- Show both services' quota in rings with a white pace tick and an Ahead, On pace or Fast verdict, the 5-hour window below each ring and a compact reset countdown. The collapsed bar alternates one quota value beside rings that show both.
- Collect the 5-hour, SSH and quota-delay warnings into one warnings slot that appears only while a warning applies.
- Show each running turn's elapsed time, and right-align speed and time to first output in two-line task rows.
- Fit the island to its content at all times: around a notch the collapsed bar keeps equal sides sized by its components, and the expanded panel fits its task rows. The Specified Width option is gone.
- Use Liquid Glass that follows the system's glass setting on macOS 26 and later, with a dark wash for legibility. Around the notch the collapsed bar stays black to blend with the camera.
- Keep an ended task's card dismissed after a normal relaunch once you have opened its conversation.
- Remove the menu bar item and the in-island reminder banner; everything shows on the island.

### Settings

- Move Settings into a sidebar window that applies changes as you make them, without Save or Cancel.
- Customize the collapsed bar with a lane strip shaped like the bar: drag components between the sides of the camera, toggle each one, and choose 5 hours or 7 days for each service's quota.
- Simplify Reminders to the collapsed-bar warnings, one System Notifications switch and how long ended tasks stay.
- Add a Connections page that lists every task source with problems first, quota freshness, and the SSH and Remote Control switches.
- Add a Help page with a legend drawn from the real island components, and a two-step welcome guide on first launch that can be reopened from Help.
- Give Pacer its own icon.

### Fixes and performance

- Reduce Claude hook overhead, repeated directory scans, transcript parses and unchanged reads.
- Reject measurements from a previous turn, keep tool endings when results contain display fields, and keep unknown quota visibly distinct from zero.
- Treat a reachable SSH host without Claude as connected, and stop reporting missing Claude sources as SSH problems.
- Fix the demo mode showing Codex quota as unavailable when Claude was last selected in Settings.

### Upgrading

Preferences from 2.x carry over. Saved layouts, quota windows and warnings are migrated, and retired options (menu bar, glass style and tint, specified width, per-kind reminders) are cleared on the next settings change.

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

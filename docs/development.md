# Development and data semantics

This is the developer reference for the Mac app and the shared Swift Core. It records what the code does not make obvious: privacy limits, ownership and precedence rules, compatibility constraints, how third-party sources were observed to behave, and how to check changes. For what users see, read the [user guide](guide.md). Windows has its own pages, starting with [Windows engine development](windows-engine.md) and [Windows shell development](windows-shell.md). Releases follow [the release workflow](releasing.md) and [automatic updates](automatic-updates.md).

## Build, run and demo

- Use Xcode 26 or newer; the app's minimum is macOS 14.
- `make test TEST_FILTER='SuiteName|OtherSuite'` while developing, `make test` for the full suite, and `make build` when you need an app for UI checks. Sources and outputs are copied to `/private/tmp`; dependencies resolve from `Package.resolved` into a reusable per-user cache. Which checks a change needs is set by the [validation scope](releasing.md#validation-scope).
- `make build` prints the app path. Development builds are ad hoc signed. Quit the installed Pacer first: every copy shares the singleton lock in `~/Library/Application Support/CodexPacerIsland`.
- `native/Info.plist` is the version source. The executable is `CodexPacerIsland`; the product is Codex Pacer.

### Launch arguments

| Argument | Effect |
| --- | --- |
| `--demo` | Labeled sample tasks, quotas (Codex weekly-only with banked resets, Claude 5-hour and 7-day) and DeepSeek spend instead of real sources, starting expanded and pinned. Command+1/2/3/4 step through thinking, tool, reply and completion. Clicks open a labeled sample, never a conversation. Samples follow the saved module switches. Demo never records the welcome guide or What's New and does not isolate the production lock. |
| `--demo-completion`, `--demo-collapsed` | With `--demo`: start on the completion stage; start collapsed. |
| `--demo-subagents`, `--demo-claude`, `--demo-deepseek`, `--demo-cloud` | With `--demo`: one parent with three agents; a Claude task that follows the demo stage; a DeepSeek task with a turn cost; a Claude cloud Project coordinator and threads. |
| `--demo-notch` | With `--demo`: hardware-notch geometry, for screenshots on virtual displays. |
| `--expanded`, `--settings` | Start expanded; open Settings at launch (used by the language relaunch). |
| `--welcome`, `--whats-new` | Force the welcome guide or the What's New window. |

Diagnostics print counts and status names only, never credentials, account identity or task text:

| Argument | Reports |
| --- | --- |
| `--diagnose` | Codex CLI discovery and quota protocol, including whether the legacy rate-limit request shape was needed. |
| `--diagnose-events [--observe-seconds N] [--desktop-only]` | Codex Desktop IPC and SSH source counters. `--desktop-only` skips SSH helpers. |
| `--diagnose-task --thread-id UUID [--host-id ID]` | One Codex task's grouping and rate status. |
| `--diagnose-claude [--observe-seconds N] [--skip-quota] [--desktop-only]` | Claude hooks and telemetry setup with any conflict reason, quota source, and a collector summary that says per source whether exact request spans arrived. |
| `--diagnose-claude-cloud` | Claude cloud Project counts and statuses, threads reporting a speed, and whether the message stream opens. Use after a Claude update. |
| `--diagnose-claude-cache prepare\|read\|cleanup` | QA for Keychain access to a dedicated QA item, never a real credential. |

For explicitly authorized local troubleshooting, set the preference `pacerLocalRuntimeTrace` to true before launch. The process then writes at most 1 MiB to a private `/private/tmp/pacer-runtime-trace-PID.jsonl` with hashed routing identifiers, lifecycle methods, phases and timestamps, and no task text, paths, requests or token values. Delete the preference and relaunch afterwards.

## Architecture

| Target | Owns |
| --- | --- |
| `PacerCore` | Everything provider-specific that is not OS IO: quota clients and coordinators, activity readers and lifecycle, rates, transports, completion retention, presentation models, geometry and preference migration. Compiled for both Mac and Windows. |
| `PacerMacSupport` | Mac IO behind Core protocols: child processes and byte readers, file metadata and replacement, application and CLI discovery, process inspection, Keychain and Pacer-owned credential storage, URLSession factories, the singleton lock. |
| `PacerIsland` | The SwiftUI/AppKit app: island, main window, notifications, native glass and the Sparkle driver. |
| `PacerRelaunch` | A helper that waits for a normal exit and reopens the app (language change). |
| `CZstd`, `CGzip` | Decompression only: Zstandard for DeepSeek session logs; zlib 1.3.2 inflate with isolated symbols for gzip OTLP bodies. |

The root `Package.swift` builds the Windows engine from the same Core ([Windows engine development](windows-engine.md)). The shipping Mac app builds from `native/Package.swift`.

Rules that hold across the codebase:

- **Core decides, hosts supply facts.** Mac and Windows run the same monitors, coordinators and presentation models (for example `ClaudeActivityMonitor`, `RealtimeActivityMonitor`, the quota coordinators, `ActivityApplicationState`, `CompactBarPresentation`). Core owns watch limits, debounce, baselines, retries, cancellation and account isolation. Hosts supply file events, sockets, helper processes, credentials, HTTP, clocks and power events, and draw what Core presents.
- **One shutdown budget.** `ApplicationLifecycleCoordinator` owns module and source changes, sleep/wake and cleanup. Shutdown, sleep and source changes share one 650 ms deadline, including quota-history flushes; the Mac child adapter escalates to SIGKILL after 500 ms. Files use atomic replacement, so interrupted cleanup loses pending samples but keeps the last committed file.
- **Late work cannot publish.** Every source, read, scan and connection has its own identity or generation. A source change revokes publication before awaiting cleanup, so a late result cannot publish or release a replacement's slot.
- **Helpers are owned.** Helper stdout has one ordered consumer with backpressure, and closing stdin ends a helper. Pacer stops only what it started and never touches shared Codex or Claude processes.
- **File metadata does not follow symbolic links**, except DeepSeek cursor reads, which need the target's size and date.
- **Stable wire values.** Shared presentation enums keep their string values and reject unknown JSON strings. Reading Mac preferences falls back to defaults without rewriting saved values.
- **Browser scripts** for DeepSeek ship once in Core resources and run in an isolated script world; their contract test checks origin and script names, not hashes.

### Tests

- `PacerCoreTests` compiles on Mac and Windows. `PacerMacSupportTests` covers Mac/Unix IO, including singleton locking. `PacerIslandTests` covers the app's presentation models.
- `native/Tests/PresentationTables` freezes cross-platform presentation scenarios as JSON tables that shared tests read directly.
- Make test `UserDefaults` suites with `testDefaultsName` and remove them with `removeTestDefaults`. They live in a temporary folder because a reverse-DNS suite leaves an empty plist in `~/Library/Preferences`.
- Tests that supply their own events use `IslandModel(demo: true)` with `demoArguments: nil`: no built-in fixtures, but IO isolation and sample quotas remain.
- Group tests by the behavior they protect. When consolidating, keep distinct input paths and boundary assertions, especially account isolation, sanitized transport, real helper shutdown and window rounding. Test counts are not acceptance criteria.

### Manual checks

Reproduce a changed interaction in the real app and check the affected layout: anchors and reversal for geometry, persistence for settings, hover and tap for expiry details, quit for shutdown. Check reduced motion, reduced transparency and older macOS only when those paths change. Source tests do not establish live appearance, Codex deep links or every display configuration.

## Privacy rules

These apply to every provider, transport and diagnostic:

- Pacer never retains prompts, responses, reasoning, tool arguments or output, question options, reply text or Claude/Codex account attributes. Readers keep identifiers, timestamps, kinds, counts and bounded display metadata (titles, model, effort, project name) and drop everything else as early as possible.
- Pacer reads no other application's Keychain item, Safe Storage or browser cookies, and never imports a session. Web sessions live in Pacer's own WebKit data stores. Credentials and unsalted identities never enter history, presentation snapshots, settings, errors or logs.
- Remote helpers sanitize on the host, so only that bounded metadata leaves it.
- Pacer is a passive observer. It never starts or resumes a turn, answers an approval, sends a prompt, or replaces a client's connection. Opening a conversation supplies no prompt.
- Source silence, a dropped connection or a missing file makes activity unconfirmed. It never invents a completion or an interruption.

## Providers and modules

`AgentProvider` identifies Codex, Claude and DeepSeek. Activity keys are `host:UUID` for Codex, `claude:host:session` and `deepseek:local:session`; grouping never crosses provider or host. `ProviderModules` stores automatic, enabled or disabled per provider. Automatic (also for absent or malformed values) detects known application and executable locations without launching a provider or checking sign-in, and is never frozen into preferences. Turning a module off releases only that provider's collectors, work and reminder baselines.

The task header shows an app button for each enabled module whose desktop app resolves (`com.openai.codex`, `com.anthropic.claudefordesktop`). It activates or launches the app and opens no conversation. Lookups run off the main thread at start, after a Settings change or a failed open, and at most once a minute on expansion. Turning off `showAppButtons` (default on) moves them into the More menu.

### Model and reasoning effort

Rows show the executing turn's model and reasoning effort. Codex reads them from rollout `turn_context` and Desktop's `latestModel`/`latestReasoningEffort`; app-server thread settings describe configuration for a later turn and never replace them. Claude reads `message.model` with `perTurnEffort` (falling back to `effort`); `<synthetic>` never names a model. A model reported without an effort keeps the known effort only while the model is unchanged; an explicit null clears it. Efforts must match `^[a-z][a-z0-9_-]*` within 32 bytes. `ModelDisplay` shortens known Claude and GPT identifiers (`claude-opus-5-5` becomes Opus 5.5) and keeps the raw identifier in the tooltip.

## Codex

### Quota

Quota comes from a dedicated read-only app-server child (`-s read-only -a never app-server`) using `account/read` and `account/rateLimits/read`. Multiple service buckets take precedence over a legacy single bucket; credits and resets come from the service, never from API-price conversion. Missing data stays unavailable.

Each request waits up to 30 seconds (`ProviderQuotaRefreshPolicy.replyTimeout`, shared with Claude and DeepSeek); a timeout restarts the child for the next read. A slow reply is not shown as an error when the account's last reading can stay: the reading, error state, failure count and client are kept, so the next read follows the regular cadence. The client keeps the account it last verified while `auth.json` is unchanged, so a slow `account/read` on a fresh child still qualifies; a changed auth file, another verified account, or no reading to keep reports the timeout as before. Other failures keep their visible error and backoff. The reading is marked as not updated once it is ten minutes old.

Some older CLIs reject the rate-limit params object with `-32600` and `invalid type: map, expected unit`. Pacer retries that exact error once without `params` and keeps that shape until the connection closes; that shape cannot request reset-credit details. A CLI without account-routing metadata can report quota but cannot scope history.

Available banked resets are deduplicated, grouped by exact expiry and sorted earliest first. Expired and redeemed credits are excluded; a missing detail row is unknown, while an explicit null expiry means none. The service count stays authoritative when its detail list is capped.

### Activity sources

`RealtimeActivityMonitor` merges local, SSH and Remote Control results. All of them project only lifecycle, timestamps, bounded display metadata and output counters.

| Source | How it is read | Limits and rules |
| --- | --- | --- |
| Codex Desktop IPC | Native Unix-socket client in the app process; a streaming JSON reader discards transcript strings before building a metadata frame | 16 MiB of retained metadata. Sender, protocol version and consecutive revisions are checked; a gap requests a new snapshot with bounded retries. Discovery watches `.codex-global-state.json` and the Codex home; a follow without a snapshot expires after bounded retries. |
| Local rollout logs | Incremental reader over `sessions/` rollouts | 32 file plus four directory watches; 512 KiB on attach, 128 KiB per append. Fallback scans every 120 s while IPC is connected, 60 s otherwise. |
| SSH | Owned Python 3.6+ helper over existing non-interactive SSH and known host keys, with agent and port forwarding disabled | Runtime events are authoritative for SSH; Desktop views only help discovery. At most 64 rollout cursors and 32 active subscriptions (idle and review threads take none); 15-second status heartbeat. |
| Remote Control (`remote-control:`) | The Desktop owner's versioned stream, plus a read-only GET of the paired-environment directory for device names | At most eight devices. Only public client and account-user identifiers are read from the enrollment index, never signing keys or enrollment credentials; authorization stays in memory. Codex must stay open and connected: there is no remote runtime or log fallback. |
| Dot Durable Codex | Desktop IPC, with read-only Durable history when its owner has no recent runtime stream | The authenticated IPC peer identifies the local executor. Pacer checks the Windows Store package identity, or on the Mac that the bundled CLI binary is signed by OpenAI's team, before starting that CLI. The Mac check reads only the signer; macOS checks each page against the signature as the CLI runs. The current account's `thread/list` scopes both paths to Dot threads assigned to that executor. A catalog entry alone does not create activity. |

Remote Control starts disabled. Enabling it or restoring an enabled preference on launch loads the paired-device directory. Settings can refresh it on demand. Once loaded, the directory stays in memory while the account and enrollment match. Normal task events, SSH or WSL discovery, and wake with a verified directory use that copy. Enrollment metadata is parsed again when its file signature changes.

A transient directory failure retries after 30 seconds, one minute, two minutes, then every five minutes until success. On wake, Pacer tries immediately if it has no verified directory or the last refresh failed. A new route from Desktop can request one check per device every five minutes, with a shared minimum interval between reads triggered by events. Pacer keeps routes announced during a read and follows them once the directory verifies their devices. If a device loses its last live stream and snapshot recovery fails, Pacer checks whether the device is offline. Routes still unverified after a read and disconnects that occurred during it can share one follow-up. A known device can resume reporting tasks through IPC before its directory status changes.

When the account or enrollment needs revalidation, Pacer hides its Remote Control tasks and blocks navigation. Unread endings return if the same account and device are verified again. Sign-out, a confirmed account change or a device removal clears the affected endings.

The catalog poll runs every 15 seconds on one connection. It is replaced when the account, the executor or the socket changes, and renewed at most hourly, because each new connection starts the bundled CLI for a token. `thread/list` returns rows newest first, 50 per page. The first read on a connection, and one every two minutes after it, pages up to four times, so an active task with an old update is found within two minutes. Other reads stop after a page whose oldest row is older than the three-minute recent window, once every task already in the catalog has been seen.

Desktop sends a Durable snapshot only once it owns the loaded conversation. A closed chat can therefore finish with successful MCP results and no Desktop state frames. While IPC is missing or quiet, the catalog poll reads the latest turn for up to four eligible tasks per pass. For progress it checks the local reporter's latest accepted receipt for the exact thread and turn in the account's catalog. The private plugin takes those identifiers from Codex's MCP metadata. Its bounded mailbox stores only identifiers, timestamps and the percentage. If a receipt is missing, the same poll can read up to two pages of persisted tool results. Expiring a follow that never received a snapshot leaves this evidence intact. Explicit turn endings are delivered once, and completion acknowledgments stay scoped to the account.

Ordinary updates coalesce at one second expanded and five seconds collapsed; expanding flushes pending events and rereads known cursors without rediscovery. First output, turn and tool boundaries and attention bypass batching. Idle collectors block on events rather than polling.

**Known limitation: Desktop snapshot loss.** Codex Desktop can start several IPC routers on the same socket path (a startup race in Codex, reproduced without touching Codex by `node scripts/diagnostics/reproduce-codex-ipc-split.cjs`). An observer on a different router from the chat's owner connects but never receives a snapshot. Approval requests come only from that snapshot, so their reminders are missed until Codex restarts; async questions still arrive through the log fallback. A connected socket therefore does not prove that every client is observed. Pacer must not patch Codex or kill its processes to work around this.

### Lifecycle and attention

- Only explicit terminal evidence ends a turn. An owned `turn/completed` ends it even with a missing or unfamiliar status; failure (live `failed` or a rollout `task_complete` error) and interruption keep their own outcomes. Idle status, silence, orphan terminals, a final-answer item or a 100% report never complete a request.
- Live activity rejects events for the last 64 retired turn IDs, and a confirmed-idle marker stops later unload or error messages from recreating a reclaimed task. A runtime `systemError` stays unconfirmed until fresh evidence arrives.
- Subagent relationships come only from validated `parentThreadId`/source metadata and session headers; agent IDs seen elsewhere just trigger bounded discovery. A parent's running hint cannot override a child ending at the same or a later time. Tasks group under one root per host, excluding reviews.
- A goal bound to the current request keeps it open between turns, shown as paused or limited when Codex says so, and leaves the list 15 minutes after its last turn ends without a completion card.
- Ephemeral conversations are excluded before projection. `thread/name/updated` renames a task and its retained card without touching lifecycle.
- Desktop `requests` and current-turn agent-message `questions` are observed for local, Remote Control and SSH hosts, keeping only hashed identifiers and the input/approval kind. A nonblocking question raises attention without turning a running task into waiting. Questions clear on removal, a later user message or the turn ending; owner disconnection resolves nothing.
- Without a Desktop stream, the log reader detects accepted `request_user_input_async` calls by a hashed thread/turn/call key. Live Desktop input wins, and the shared key keeps one reminder when sources change.

### Rates and first output

The Codex rate is settled response throughput: authoritative output tokens for one request divided by the observed window from turn start, the previous request's accounting or the last required tool result, to the last generated item. `token_usage_record.usage.output_tokens` has priority; runtime `last.outputTokens` can settle earlier. Reasoning counts once; input and cached input do not. Request IDs deduplicate. Confirmed blocking-tool time is excluded, and tool events can close but never create a model-output window. It is observed throughput including first-output latency, not decoder speed, and provider totals are not tokenizer-normalized.

Without exact records, the older cumulative-counter estimate applies; it can overstate a request attached mid-flight.

First output (a TTFT proxy) runs from a newly observed turn start to the first nonempty model or reasoning text. A mid-turn attach never infers an unseen first output; a service-reported `time_to_first_token_ms` fills gaps.

The header total adds the available rates of running chats. Tool waits keep a chat's last rate; waiting, ended and internal-review agents are excluded; unmeasured tasks make the total partial. A number turns gray 15 seconds after its latest measurement. Late numeric accounting can enrich a matching retained card but never creates activity, replays a reminder, extends expiry or revives a dismissed card.

### Sessions from other apps

A rollout's `session_meta.originator` names its client (`source` cannot: Codex Desktop and the Zotero ACP bridge both report `vscode`). `CodexSessionOrigin` holds the official-client list, from Codex's first-party client definitions plus `Codex Desktop`. Any other originator marks the session embedded; a missing one leaves it unclassified. Only the booleans `embedded` and `ignoredSession` leave the parser, and the originator string is never stored. The newest launch record wins, so a session resumed by an official client is no longer embedded. Subagents inherit their parent's classification.

Zotero Agent runs translations through its ACP bridge, which ignores the plugin's `ephemeral` flag. An embedded session whose cwd ends in `zotero-chat/translate`, or whose last path component starts with `zotero-chat-catalog.`, is ignored with its subagents: no task, card, notice or measurement. Readers classify before choosing cursors, so ignored sessions take no slots.

To open an embedded session, Pacer finds the same-user process holding the rollout open for writing and walks up at most 32 parents to the first regular app. It never reads process arguments or environment, and start times guard against PID reuse. The Mac scan checks at most 2,048 processes and 4,096 descriptors per process. Background tracking uses the shared policy below. A click checks the current host before falling back to the saved app. Embedded sessions open only through their host. Official clients open `codex://threads/<id>`, with `hostId` for SSH and Remote Control.

`showEmbeddedCodexSessions` and `showEmbeddedClaudeSessions` (both default on) only filter what is shown and announced. Hidden turns are still collected and expire without being acknowledged.

## Claude Code

### Quota and sign-in

Quota reads try, in order (`PrioritizedClaudeQuotaConnection`):

1. A fresh status-line sample whose hashed account scope matches.
2. `ClaudeWebQuotaClient`, using the session in Pacer's own `WKWebsiteDataStore`. Connect opens Pacer's claude.ai login window, where the user signs in normally. Cookies stay in WebKit and reach requests only in memory.
3. `ClaudeQuotaClient`, a quiet compatibility fallback for Pacer's own OAuth cache item (default creator ACL) or explicitly supplied environment or file credentials.

The web adapter makes read-only GETs for account, organization and usage. It verifies the session, account and organization binding and rejects redirects, mismatched authentication and HTML challenge pages. With several organizations the user must choose one. Expiry or a challenge needs a visible sign-in action; startup and refresh never open the window. 429 and network failures are retry states with bounded `Retry-After`. Web and OAuth reads wait up to 30 seconds. A timeout for the same verified account keeps its last reading, error state and cadence, as for Codex; any other failure, or a timeout without a verified account's reading, is shown. These endpoints are private and version sensitive. Desktop history is never a quota fallback.

Claude's and DeepSeek's sign-in windows record a one-way fingerprint of the session present at open (for DeepSeek, a SHA-256 of the page token computed in the isolated script world, so Swift never sees the token). A different fingerprint means a new sign-in, which closes the window; closing it any other way also completes while a session exists. A new Claude session clears the saved organization; a new DeepSeek token starts a new balance history and replaces any outstanding read.

### Task collection

Claude tasks come from a bounded incremental transcript reader, optional hooks and a loopback-only OTLP HTTP/JSON receiver on `127.0.0.1:4319`. The same rules apply in the native reader and the SSH helper.

- **Reading.** Each line is parsed once; text is reduced to presence and kind markers. Budgets of 512 KiB on first read and 128 KiB per append are per-read limits drained in chunks, not evidence of loss. A real gap invalidates ownership and leaves the ending unconfirmed. Watches cover 32 files plus 99 parked directories.
- **Ownership.** Readers keep up to 512 ID-only prompt anchors and parent links. Desktop can write a record before its parent; descendants wait under the missing ID (bounded) and are released in file order when it arrives. A new prompt is never an ownership fallback. Records whose ancestor is missing are `unownedTurn` and cannot start, replace or revive a turn.
- **Desktop mirrors.** Claude Desktop copies SSH and WSL transcripts into the default local home. A unique validated SSH/WSL context in the active Desktop account's metadata excludes those copies before file selection; ambiguous metadata changes nothing.
- **Baselines.** Initial reads restore historical cards without replaying reminders. A baseline turn still running with evidence older than 15 minutes becomes unconfirmed.
- **Embedded sessions.** Of the launch `entrypoint`, only whether it starts with `sdk-` (an Agent SDK embedding) is kept, as `embedded`; the latest record wins.
- **Permission requests.** `PermissionRequest` and the `permission_prompt` notification carry no tool ID, so the adapter matches them to a waiting tool by a CRC32 of tool name and input (no text kept). A question's permission shows as a reply, not an approval.

### Turn endings and subagents

A turn ends only on owned, explicit evidence:

- Stop and SubagentStop hooks only record an attempted stop. A transcript `stop_hook_summary` completes the turn only with `preventedContinuation == false`, explicitly empty `hookErrors` and `hookAdditionalContext`, and ownership through the prompt/parent-UUID chain. This stops another Stop hook's continuation from retiring the turn early. Missing ownership after a gap never falls back to timing.
- Claude Desktop's next-step box ends a turn through its own tool result without `end_turn`. An owned tool result whose `mcpMeta._meta["claude/endTurn"]` is `true` completes the turn and leaves a reply reminder until the next prompt, an interruption or the session's end. Only that boolean is read. A baseline replay restores the ending but not the reminder.
- Engine interruption markers count only for the matching active prompt without human-message provenance.

Subagent runs (`ClaudeAgentNotification` and the activity state):

- A foreground Agent's typed completed result ends its owned child. A forked skill reports `forked`: in the foreground it counts as a completed result, in the background as an asynchronous launch.
- A SendMessage that revives a stopped agent (`revivedAgentId`) is a new asynchronous launch under that call; a message queued for a running agent starts no run.
- An asynchronous launch stays active until an engine-authored background notification proves a terminal status for the exact child and tool pair. An ending read before its launch waits for it, bounded.
- One call starts at most one run. A hook reads its clock only after its interpreter starts, so a background launch binds a child start up to 5 s after the launch result.
- Hooks file every subagent under the root session, while Claude Code reports a subagent's own launches in that subagent's file, so matching works anywhere within one root task.
- Two fallbacks keep a child from outliving its main conversation when its own ending can never match. The main thread's Stop hook writes `agents`, the number of in-flight background tasks other than shells, monitors, MCP tasks and Claude Code's memory and scan work; `agents: 0` ends every child run begun before it. An interrupted or failed main turn ends child runs begun before it, except background launches, which Claude Code keeps running.

### Telemetry and first output

- OTLP `llm_request` spans supply exact request duration, output tokens and TTFT. They carry no prompt ID, so a span binds to the current turn only when `llm_request.context` is `interaction` and it starts at or after the observed turn start.
- Without OTLP, an observed estimate (`observedRequest`) pairs transcript request counts with a complete output window; a matching OTLP sample outranks it. A block with a nonempty `stop_reason` ends its request. Ended requests settle in order, each once, after a read that has drained (the local reader caught up, or a helper batch marked `baselineFinal`; the helper closes a split read whose rest held no rows with an empty one), so speeds update during a turn. Settling per record, or after a read cut short by its budget, would split a request whose blocks are written together with its ending, or whose tools ran while it was still streaming. A verified stop settles the rest. A source that delivered an exact span in the last 30 minutes skips the per-request release, so an estimate does not flash before the span.
- A `MessageDisplay` callback can mark first output only with a matching prompt ID, `final == false`, `index == 0` and nonempty text. Claude holds each displayed batch until its hooks return, so Pacer registers it as an `async` hook and only when its own telemetry is off.
- Receivers accept identity or gzip bodies of at most 1 MiB compressed and expanded; a malformed body publishes nothing, and fractions, booleans or non-finite values never become token counts.
- Numeric measurements only enrich the matching turn: they create no task, replay no reminder and extend no retention.

### Hooks and status line

- Each Claude source start calls `ClaudeHookInstaller.ensureInstalled`. It skips a missing Claude home, writes nothing when current, migrates outdated Pacer entries in place, and restores missing required hooks. Optional entries the user removed stay removed. Settings shows the result as one status row with Retry.
- Saving the Claude module as explicitly disabled uninstalls Pacer-owned entries; automatic detection changes never do.
- Setup adds command hooks, a status-line wrapper that passes stdin and output through to an existing renderer, and sanitized spool and quota records under `<Claude home>/pacer`. OTLP settings follow the coexistence rules below. New Claude sessions must start to load changes.
- Commands run `python3 -S` with only the standard library, which skips `.pth` processing in conda-style installs. `-E` and `-I` are avoided because macOS's bundled Python then recompiles its standard library on every call. An unchanged status-line sample is rewritten at most every 30 seconds.

### Telemetry coexistence

Pacer's export needs five `env` keys in the home's `settings.json`: both Claude Code telemetry switches, `OTEL_TRACES_EXPORTER=otlp`, and the trace-specific protocol and endpoint (`http/json`, `http://127.0.0.1:4319/v1/traces`). `OTEL_TRACES_EXPORT_INTERVAL=1000` is added when absent; another value only delays exports. Switches accept Claude Code's truthy words and the exporter is a comma list.

`ClaudeTelemetryRules` and `claude_remote_setup.py` return the same reason, `none`, `existing` or `managed`, checked against one shared table in `ClaudeTelemetryConflictTests`. The rules follow Claude Code 2.1.300:

- Trace-specific settings win over generic ones, so a generic endpoint or protocol for metrics and logs leaves room for Pacer.
- Every OTLP header, static or from `otelHeadersHelper`, is also sent with traces. User headers or a helper are `existing`, because they would reach Pacer's receiver.
- Managed generic endpoint, protocol, headers, client key or certificate, a managed trace credential or a managed helper make Claude Code drop lower-scope trace overrides, which would send traces to the organization's collector. These, and a managed value that differs for one of Pacer's keys, are `managed`.
- `existing` also covers a different user value for one of Pacer's keys, and an exporter Pacer did not add with no trace endpoint, which already exports traces to a generic or default endpoint.
- The telemetry switch also starts metrics and logs exporters. While no source sets `CLAUDE_CODE_ENABLE_TELEMETRY`, a configured metrics or logs exporter (anything but `none`) is a conflict, `managed` or `existing` by where it is set, so Pacer never turns on an export that was waiting.

Claude Code takes each managed `env` variable from the highest-priority source that sets it, and Pacer fills them in that order (`ClaudeManagedTelemetry.fill`). OTLP routing and credentials (`OTEL_EXPORTER_OTLP_*` and a few log and beta-tracing keys) are one group: they come whole from the highest source that sets any of them or a headers helper, and empty values count as unset. Within the file source, drop-ins override `managed-settings.json` by name. A helper from any source counts, which can only over-report. Only `env` strings and whether a helper is set are kept. Sources, highest first:

1. `<Claude home>/remote-settings.json`, the cached server-managed settings.
2. MDM policy: `com.anthropic.claudecode.plist` under `/Library/Managed Preferences/<user>/`, then `/Library/Managed Preferences/` on macOS; the `Settings` JSON string under `HKLM\SOFTWARE\Policies\ClaudeCode` on Windows.
3. Files: `managed-settings.json` and `managed-settings.d/*.json` in `/Library/Application Support/ClaudeCode` (macOS), `C:\Program Files\ClaudeCode` (Windows) or `/etc/claude-code` (Linux; WSL then also reads `/mnt/c/Program Files/ClaudeCode`).
4. Windows only: the `Settings` string under `HKCU`, used only when neither HKLM nor the files hold a document.

Project `.claude/settings*.json` files and the environment of a later Claude session are not inspected. A project-level `otelHeadersHelper` can therefore still send its headers with traces to Pacer's loopback receiver, which reads only content length, type and encoding and never stores a header. The remote script also checks the environment of its own SSH login.

Every setup check reconciles the keys. With no conflict, missing keys are added and recorded in the manifest's `addedEnvironment`. While a conflict lasts, or on an automatic check after the user removed Pacer's trace endpoint, every key Pacer added that still holds Pacer's value is withdrawn, so headers never reach Pacer's port and no trace goes to another endpoint. Keys the user edited stay, keys the user removed stay recorded in `addedEnvironment`, and the switch stays while it runs the user's metrics or logs exporters. A user who pointed the endpoint elsewhere owns the whole set. Automatic checks, local and remote (`automatic` in the setup payload), add nothing while a removed key is recorded, even after a conflict ends; Retry adds everything back. Automatic checks never add the optional `MessageDisplay` observer.

Settings shows one plain line while the reason is not `none` and the source has delivered no exact span (`RuntimeStreamStatus.exactRequestSpans`), saying whether the user's own or the organization's settings were kept. SSH host rows show the same line from `claudeRemoteTelemetryConflicts`, keyed by alias. Windows shows it in the Claude setup status. Because the receiver always listens, a local collector that also forwards traces to `127.0.0.1:4319` restores exact speeds and hides the line.

### SSH and WSL

- Targets combine enabled Codex SSH hosts with Claude Desktop's `ssh_configs.json` and `sshConfigs` in the selected home's `settings.json`, both read-only. User settings override a Desktop config with the same ID. Canonical host/user/port routing deduplicates them. Routes come from `ssh -G`, cached up to five minutes and invalidated by SSH config changes. At most eight sources are monitored, existing Codex hosts first. Identity files are referenced by path only.
- A reachable host without a Claude home is a paused source, not an SSH failure; discovery retries it after 30 minutes.
- `ClaudeRemoteSetup` runs automatically for each connected host with a Claude home whose recorded adapter digest (`claudeRemoteSetupDigests`, keyed by alias) differs from the shipped one, including the progress-ring state. It never creates a Claude home, rewrites only changed files, retries a failed host after 30 minutes, and is cancelled by turning Claude or SSH off, sleep and quit. The telemetry conflict it reports is kept per alias. A current host is checked again quietly once per launch, then every 30 minutes while its setup kept telemetry off (so it recovers on its own) and every six hours otherwise; a quiet check keeps the row connected and a failure only backs off. Windows SSH and WSL hosts follow the same schedule, with conflicts kept in `setup-v1.json`. Running remote sessions need a restart to pick up new hooks.
- Remote helpers are read-only and exit on stdin EOF or broken stdout. During cold replay both the helper and the native reader drain the hook spool before transcripts, so a later hook start cannot revive an ended turn.

### Opening conversations

- Background host tracking for local Claude and embedded Codex caches the first verified app. A miss while a task is running or waiting for input gets up to two retries, due two and ten seconds after the first attempt. A provider starts scans at least two seconds apart. A newer Claude startup or resume hook record, or a newer Codex launch record, gives the session a fresh lookup. The last verified app remains available while the task or its ending is retained.
- A local Claude session opens the app that started it. On macOS, Pacer checks the live registry (`<home>/sessions/<pid>.json`) for the requested sessions. A record needs a kind and matching `procStart`, and parked interactive sessions are excluded. When two records for a session overlap during resume, Pacer takes the first regular app above the newest verified process. Windows checks the writer of the transcript. A click looks up the current host again. The `claude://code/continue` route requires the default Claude profile and a verified `local_UUID` mapping from the active Desktop account. Local sessions are never resumed in Terminal or imported into Desktop.
- SSH sessions use a verified Desktop mapping that also matches host, user and port, or else resume over `ssh` in Terminal.
- Cloud Project rows open in Claude Desktop, or on claude.ai without it.

## Claude cloud Projects

A Project is a cloud channel (`chan_…`). Its threads (`cmsg_…`) bind one or more cloud sessions, and its overview session is the coordinator. `ClaudeCloudProjectMonitor` reads them on `https://claude.ai` with the same WebKit session as quota reads:

- `GET /v1/code/channels?limit=50&scope=joined`, `/v1/code/channels/{id}/threads?limit=20`, `/v1/code/sessions/{id}` and `/v1/code/sessions/{id}/events?limit=8`, with the `ccr` client headers, an ephemeral redirect-rejecting session and a 4 MiB reply limit. Pacer sends nothing to them.
- `ClaudeCloudDecoder` keeps lifecycle fields and a finished turn's numbers. Message bodies, thread previews, tool input and event text never leave it; a pending tool is reduced to question or approval by comparing its name with `AskUserQuestion`.
- Only the app sets `IslandModel.makeClaudeCloudMonitor`, so tests and demos never reach claude.ai.

**Polling.** There is no usable push feed: `/v1/code/sessions/watch` answered 404 and `/v1/code/notifications` 501 when this was built, and `/v1/code/sessions` lists Desktop's local sessions. `ClaudeCloudPolling` looks every 20 s while something runs, 30 s while the panel is open or something changed, up to 120 s otherwise, and backs off from 30 s to 15 minutes on failure, honoring `Retry-After`. A 404 or 501 on the list means the account has no Projects: the source stays hidden and retries after 30 minutes. A rejected session pauses until a new sign-in. At most 16 projects are followed and 16 sessions read per pass, rotating candidates so waiting threads are not starved. Sleep suspends polling but keeps state, since cloud work continues.

**State mapping.** `ClaudeCloudProjectState` projects each pass through the shared activity events under the source ID `claude-cloud`, so the inbox, attention and grouping need no cloud branch. Observed against Claude's service in 2026-11 (the thread row goes quiet seconds after a run starts, so it cannot say whether work is in progress):

| Thread row | Session | Pacer |
| --- | --- | --- |
| `working` or `thread_any_session_working` | no explicit request | running, `working` stage |
| `idle` | `status_bucket` `working` on a live connection (`worker_status` reads `idle` or unspecified during a long tool call) | running |
| `idle` | stopped, no `post_turn_summary.status_category` or `blocked`/`need_input`/`waiting` | ended, "Turn finished · Reply if needed" |
| `idle` | stopped, any other category | ended, "Turn finished" |
| `resolved` | no current work or request | "Resolved" when there is evidence of an ending |
| `needs_input` | no running session or explicit request | plain question, shown if new or recently unread |
| any | a connected, nonterminal session with a current action request | waiting for a reply or approval, until answered |
| `open_decisions` not empty | | waiting, separate `decision` kind |
| `failed` | | interruption with `turnFailed` |
| `archived` | | row removed |

- Unknown statuses read as idle; a running session on a dropped connection counts as stopped. Open decisions and explicit action requests outrank a stale `needs_input`; `pending_action` counts only while the worker reports `requires_action`.
- A plain question alerts only with evidence that it is new (work seen just before it, the run ending within five minutes, or a reply close to the latest poll). It clears when Claude's unread flag clears, after 90 s if it never became unread, or after seven days.
- The first pass is a baseline: unread endings from the last seven days become quiet cards. A short run can fall between polls, so a newer `last_reply_at` on an unread or stopped thread also counts as an ending. `idle` can precede `resolved` for the same run, which only updates the label; a hashed record of up to 128 acknowledged idle endings keeps one reminder per run across relaunches. After three failed passes open rows become unconfirmed.
- **Coordinator.** A coordinator turn about threads (one is open, was created during the turn, or ended within two minutes) is dropped without an ending; other turns end with a card.
- **Read state.** A thread's `has_unread` rises at `resolved` (about 24 s after the ending) and clears when opened. An idle thread never raises it, and `session.unread` stays true on thread sessions after opening, so an idle ending's card stays until clicked or replaced. The coordinator uses `session.unread`, which does clear.
- Polls cannot date a run's start, so elapsed time counts from first sight. A thread whose sessions all match Desktop's `bridgeSessionIds` or `remoteControlSpawn.ccrSessionId` is left to the local reader. Project tools run through the Desktop bridge on the user's Mac.

**Streams.** `ClaudeCloudReplyStreams` reads the web client's SSE at `/v1/code/channels/{id}/messages/stream?from=tail&caught_up=true`. Streams only bring polls forward and estimate speed; polling decides every state. The four most active projects keep one stream each (carrying `thread_starting`, `session_activity` and the coordinator's partial replies), and each running thread gets its own `scope=thread&thread_id={id}` stream, at most six. A stream sees only replies that start after it connects; `thread_starting` arrives several seconds before the first partial reply, which is what lets the thread stream catch it. Only those three events are decoded, and partial text is reduced to a length.

**Speed.** No token count is published during a run (`external_metadata.usage` stays empty and assistant events carry stale `usage.output_tokens`). `ClaudeCloudReplyMeter` therefore estimates from the growth of `session_partial_reply` text at 1.09 tokens per CJK character and 0.3 per other character, over the last 10 s of writing; live runs read within about ±15%. After a run ends, the newest `result` event's `usage.output_tokens` over `process_wall_ms_streaming` gives one `requestUsage` sample. Never use `duration_api_ms`: it accumulates across a session's turns. The coordinator's result lacks `process_wall_*`, so it shows no speed.

## DeepSeek Harness

### Session logs and states

Harness writes `$DSH_HOME` (or `~/.dsh`) `/sessions/<workspace>/<session>/session.v4.jsonl.zstd` as concatenated checksummed Zstandard frames. `DeepSeekSessionReader`:

- follows at most 256 logs modified in the last eight days, with bounded discovery and watches;
- reads whole frames only: a torn tail waits, a frame failing its checksum is skipped whole;
- bounds compressed input per pass and decompressed output and window to 64 MiB;
- accepts only header version 4 and projects events through light paths that never materialize message text, reasoning or tool arguments;
- decides baseline versus live by each frame's compressed offset, so frames appended during catch-up keep live timing and reminders.

`DeepSeekActivityState` maps `turn/start`, `step/start` (thinking), `tool/call`, `approval/asked` without `approval/decided` (approval), an unanswered `ask_user_question` (reply) and `turn/end.reason.kind` (`completed`, `error` as failed, otherwise interrupted). Harness writes a response when its step ends, so stage, speed and cost settle per step. A running baseline turn becomes unconfirmed when no process holds the session's `session.lock` open for writing.

Owned background jobs (`job/registered`, `job/settled`, read through `JSONFieldView`) keep a request open. It completes 10 seconds after the last settlement unless a wake turn starts first; live reads count those seconds from when Pacer read the settlement.

### Cost

Cost is estimated locally from tokens and `DeepSeekPricing` (CNY per million tokens: `deepseek-flash` 0.02 cache hit, 1 miss, 4 output; `deepseek-v4-pro` 0.15, 4.5, 13.5), doubled on Beijing weekdays 09:00–12:00 and 14:00–18:00. Weekends and the 2026 public holidays are off-peak and make-up working days count as weekends; later years have no calendar yet. `web_search`, `web_fetch`, `search` and `fetch` calls add ¥0.005 each from 2026-11-01. Only Harness's own providers (`deepseek`, `deepseek-account`, `deepseek-official`, `deepseek-api-key`, or none) are priced; unknown models have no cost.

`DeepSeekSpendLedger` records each response once by ID for eight days, under its root session (following `parentSession` up to eight levels), so sub-agent spend counts toward the root task within the parent turn's observed times. `deepseekShowsTurnCost` (default on) shows the turn's estimate before the model name.

### Balance, history and budgets

- **Source.** `deepseekBalanceSource` is `automatic`, `web` or `apiKey`. Automatic follows the provider of the latest DeepSeek request, else the `provider:` lines of the profiles' `cordis.patch.yml` (`deepseek-account` means web sign-in, the others an API key). Pacer never reads `.credentials.yaml` or Harness's key.
- **Web.** Pacer's own `WKWebsiteDataStore`, separate from Claude's. Reads run `GET /api/v0/users/get_user_summary` with the page's own token inside an offscreen same-origin page and return only wallet amounts and the platform's alert line; codes 40002/40003 mean signed out.
- **API key.** Kept in the login-keychain item "Codex Pacer DeepSeek balance" and sent only to `GET https://api.deepseek.com/user/balance`.
- **Cadence.** Every 60 s while expanded or a DeepSeek turn runs, 300 s otherwise, about 20 s after a turn ends; failures back off. A sign-in or key problem stops periodic reads. A balance older than 10 minutes is stale.
- **Slow replies.** A read waits up to 30 seconds: the key request through its own timeout, the web read through the Mac reader or the Windows engine bridge, because the page's fetch has no limit. A timeout (`timedOut`) while a balance is shown keeps it, the error state and the cadence; without one it is shown. An unreachable service (`connectionFailed`, including the page's `offline`) keeps its visible error and backoff.
- **Thresholds.** Low means below `deepseekLowBalanceLine`, else the platform's alert line, else ¥10; exhausted means zero or unavailable. The 4.0 key `deepseekLowBalance` carries over as a set line unless it holds the old default ¥10.
- **History.** `deepseekBalanceHistory` keeps amounts and times for eight days. A drop is spend wherever it happened; a rise is a top-up. "Not on this Mac" is a day's charges minus the local estimate, reliable per day, not per minute. Changing the billing source, sign-in or key starts a new history.
- **Credential binding.** History stores a 128-bit HMAC-SHA256 tag of the credential, with a local 32-byte salt kept beside it. The same credential keeps history across restarts. Legacy untagged history adopts the first successful credential. A salt failure keeps the live balance but withholds history; a malformed tag rejects it.
- **Budgets.** `deepseekMode` is `balance` (default) or `budget`; `deepseekDailyBudget` and `deepseekWeeklyBudget` count only in budget mode, from local midnight and Monday 00:00. Pacer only reminds; it never blocks a request.
- **Speed and spikes.** `deepseekSpeedSource` is `local` (default) or `account` (balance drops). A spike is the last 10 minutes' spend reaching `deepseekSpikeLimit`, or else three times the 90th percentile of local 10-minute spans over the previous seven days, at least ¥5.
- **Notices.** Low and exhausted post once per crossing, a budget at 80% and when exceeded once per period. Spike and budget take a baseline on first evaluation, so a relaunch does not repeat them.

Opening a DeepSeek row brings Harness forward; it has no conversation link.

## Quota display and history

- **Pace** is remaining quota percentage divided by remaining time percentage, times 100, capped at 1000%. Below 85% is fast, above 115% has spare capacity. Stale, failed or expired windows have no pace or verdict. `QuotaWindow.projection` extends the average spend since the window opened to its reset (remainder at reset, or time until it runs out); within the first 5% of a window it reports too early.
- **Expanded quota.** `expandedQuotaStyle` is `split` (default, also for unknown values) or `classic`. Split gives each provider one ring: a 5-hour upper arc and a 7-day lower arc when a 300-minute window exists, otherwise a weekly gauge. When only Codex is enabled and its primary bucket reports none of the standard windows, bars render the actual buckets. `proOnly` describes a missing window, not a detected plan. The panel's `codexPeriods` and `claudePeriods` can keep one window; 5 hours alone falls back to the week for an account without that window (`ExpandedPanelPresentation.gauge`).
- **Expanded panel.** `expandedPanelLayout` (UTF-8 JSON Data, version 1) lists the panel's blocks: `tasks`, `codex`, `claude`, `deepseek`, `deepseekSpend`, `deepseekWeek`. Missing, damaged or newer data is the automatic layout, which reproduces the panel before blocks: tasks, every quota, and DeepSeek's spend and week only when DeepSeek is the only service and `deepseekPanelStyle` was `detailed` (its default); nothing else reads that key now. The first edit saves the layout; **Restore Automatic** removes the key. A disabled service hides its blocks without removing them, moves skip hidden blocks, and the last block the services can show cannot be removed. `ExpandedPanelPresentation.sections` turns blocks into sections: adjacent quota blocks share one (`quotaArrange` `pair`, the default) or each gets its own (`stack`); the first section's header carries the panel's buttons; DeepSeek's spend and week join a section that shows DeepSeek without a hairline; a lone DeepSeek day dial draws the spend in its own column when the spend block follows it. With no block to show, the task list stays.
- **Panel choices.** `expandedPanelOptions` (UTF-8 JSON Data) reads field by field like the collapsed bar's: `pageSize` 3–6 (default 3, also `TaskPagination`'s page), `rowStyle` `twoLine` or `oneLine` (38-point rows with the name and speed or turn time; a request for the user replaces the speed), `rowFields`, the periods, `quotaArrange`, `quotaDetails`, `paceTick`, `deepseekDial` (`budget` shows the budget dial when a budget is set), `deepseekPeak`, `spendTasks` 2 or 4, `spendElsewhere`, `weekLine` and `headerActions` (`markRead`, `pin`, `settings`). App buttons keep `showAppButtons`. Header buttons that are off, including app buttons, join Refresh and Quit in the More menu. Overview's service cards follow the drawing choices (style, windows, details, pace tick, DeepSeek dial) but not the order or which blocks show. Retention (`completedRetentionMinutes`) is chosen on the task list; Notifications links there.
- **Collapsed quota.** The value alternates between enabled providers every 4 s; independent percentages are never summed or averaged. One service's failure never replaces another's data or error state.
- **Polling.** 30 s expanded and 120 s collapsed, doubling per failure up to four failures and capped at 600 s. A Codex or Claude reply that times out while a verified account's reading stays is not a failure ([Quota](#quota)); DeepSeek follows the same rule with its own cadence.
- **Freshness.** A reading older than ten minutes (`QuotaSnapshot.staleInterval`) is not updated: the ring dims, the expanded panel shows its freshness mark without pace or verdict, and the collapsed bar's late-update warning shows as an outline mark. A failed read fills that mark.
- **History.** The seven-day curve keeps the first reading and the latest in each five-minute interval, at most 2,018 points per window, isolated by hashed account or workspace identity and reset date. Disk writes coalesce to 30 minutes, except first readings, account or home changes and new cycles; sleep, source changes and exit flush, so an abnormal exit can lose up to 30 minutes of curve. Mac keeps its existing history keys, paths and numeric encodings.

## Task progress ring and task states

Every task row draws one 28-pt status icon: a glyph for what the task is doing, inside a ring for how far its current request has got. The ring follows the user's request, not the model's turn: a request can span several turns and pause for background work. The number is always the agent's own estimate; tokens, elapsed time, tool counts and checklist steps never stand in for it.

### Reporting

The rings are on by default (`claudeProgressRing`, `codexProgressRing`, `deepseekProgressRing`; an absent value means on). Each provider reports through a tool that accepts one integer from 0 to 100; Pacer reads the successful call from the provider's own records and keeps only the integer, bounded identifiers and timestamps.

| Provider | Reporting tool | Setup Pacer owns |
| --- | --- | --- |
| Claude | Plugin `pacer@pacer` from a local marketplace in `<home>/pacer/plugin`, an MCP server with tool `report_progress`; the `PreToolUse` hook spools the integer | Switch file `pacer/progress-ring` (contents `tool`). The installer enables the plugin and pre-approves `mcp__plugin_pacer_pacer__report_progress`, recording each addition in the manifest's `progressPlugin` ledger; turning off restores only recorded values that still match. A foreign marketplace named `pacer` makes setup fail without changes. SSH and WSL hosts get the same through `ClaudeRemoteSetup`. |
| Codex | Bundled MCP server `pacer_progress` (the Mac app's `--codex-progress-mcp` mode) | One `mcp_servers.pacer_progress` entry in the selected home, written through Codex's config API, with `omit_tools_from = ["deferred"]`: otherwise tool-search models, including custom providers using OpenAI model names, only find the tool through `tool_search`. A conflicting same-name entry is left alone. A local flag stops a connected reporter after disable. |
| DeepSeek | Pacer's reporter, run by Harness's own Node runtime | An entry in the home-level `cordis.patch.yml` between `Codex Pacer DeepSeek progress` markers. A checksum in the begin marker and an ownership line in the reporter let Pacer replace its own entry but report an edited or foreign one as a conflict. Turning off restores what the entry replaced. |

Claude loads plugins at session start, so only sessions that started with it enabled get the one-line request for estimates on a typed prompt. `ProgressSetupQueue` runs Codex and DeepSeek setup one at a time off the main thread and publishes only the newest status; shutdown lets the latest setup finish within the deadline.

The Codex switch also owns a private local marketplace in the Desktop profile, with the same reporter and revocation flag. On both platforms Codex Desktop loads a plugin change the next time it registers its local executor, so the ready status asks the user to restart Codex. Pacer never signals Desktop or its executor. The plugin is best effort: if installing it fails, the switch still reports the local reporter's status and the next setup retries. A failed removal reports failure so the switch can retry the cleanup.

Request scope:

- A typed prompt starts a request and clears its estimate. Turns started by task notifications, scheduled wakes, a steer, an answer or a verified continuation continue it, keeping the estimate and its original time. Compaction and reconnect never create a request. A later, lower estimate is accepted.
- Estimates apply only to a verified current turn; an `unownedTurn` reply cannot borrow it. A child's estimate never updates its parent, and family rings never average children.
- Without proven continuation, the ring stays turn-scoped and the ending says only that the turn ended.
- Claude cloud Project threads cannot run the plugin and are identified only when a run ends, so their ring (`cloud`) stays pending while running and fills on completion.

### Waiting for background work

A turn that stops while its own background work runs keeps the request open: no completion is announced until the work ends.

| Provider | Evidence of background work | Ends when |
| --- | --- | --- |
| Claude | At `Stop`, any `background_tasks` entry other than monitors and Claude Code's memory and scan work (`monitor`, `dream`, `auto-mode scan`, `memory import`, `memory save`), or any `session_crons` entry. The adapter writes a `waiting` snapshot; a later Stop without work clears it. | A wake turn continues the request, or a later Stop with no work ends it. New output or a tool start in the same turn clears the wait. |
| Codex | A `sleep` item, a blocking agent wait, or owned dependents still running after the parent's turn ended | Matching wake or new work; an explicit ending still ends it |
| DeepSeek | An owned `job/registered` from the current request | 10 s after the last `job/settled` without a wake turn |

### State, icon and ring

Mac (`TaskStatusIconNSView`, Core Animation) and Windows (`TaskStatusIcon` and `TaskProgressRing`, WPF) draw the same icon from `TaskProgressRing.make` and `TaskSymbol`. Working glyphs sit on a soft provider-tinted orb, and their parts brighten and dim in turn without turning, scaling or moving. States that need the user or have ended fill a solid disc with a dark mark, gray once read, and hide the ring.

| State | Glyph | Ring without an estimate (`pending`) | Ring with an estimate (`reported`) |
| --- | --- | --- | --- |
| Starting, thinking, running a tool, replying | Hourglass, three stars, terminal with blinking cursor, ellipsis bubble | Comet circling clockwise every 2 s | `working`: arc from the top with a running light from its start to its head (only between 4% and 100%) |
| Claude cloud working or coordinating | Still cloud; branch with pulsing dots | Comet, marked `cloud` | Not used |
| Long step (oldest ordinary tool running 30 s or more) | Tool glyph | `longStep`: comet slows to 3.2 s with a shorter tail | Light stops; the stretch past the head breathes |
| Waiting for background work | Moon with alternating z's | `waiting`: comet stops, whole ring breathes over 4 s | Arc breathes at its current length |
| Approval or reply needed | Amber disc with raised hand or question bubble; bounces with two ripples | `attention`, ring hidden | Same; estimate kept. A Codex async question keeps the task's running stage text. |
| Codex goal paused, blocked or limited | Pause disc | `paused`, static | Static, estimate kept |
| Completed | Check disc | Fills to 100% | `done`: sweeps from the shown value to 100%, then the disc fills, the check draws and the icon pops |
| Interrupted | Pause disc | No ring | `interrupted`: no sweep; the last estimate stays in help and accessibility text |
| Failed | Cross disc; shakes | No ring | `failed`, as interrupted |
| Unconfirmed | Moon, not filled | Hidden | Hidden; the estimate can return if the same request is recovered |

- When signals conflict, the first match wins: confirmed ending, unconfirmed source, attention, goal pause, background wait, long step, working.
- Only `working` fades: 120 s without a new estimate dims the arc to 45% and stops the light.
- A 100% report while still working fills the arc but keeps the working glyph and announces nothing. Codex plays the completion pop only on a confirmed ending; Claude and DeepSeek also pop when a working arc reaches full.
- The collapsed badge draws the only active task's estimate in place of the service orbit, and `HeaderActivity.multiTaskRing` chooses segments (two to four tasks) or an average for more.

### Motion

Both renderers share these values; keep them in step (`TaskStatusIconView.swift`, `TaskProgressRing.cs`):

- Comet: 2 s per turn with a half-turn tail, 3.2 s with a quarter tail in a long step; a new request's tail grows from a point. The first estimate fades the comet out over 200 ms, then sweeps from 0.
- Increase: `300 + 300 × Δ` ms, cubic ease-out. Decrease: 500 ms sine ease-in-out with a 35% ghost fading over 600 ms.
- Running light: 2.1 s of every 2.6 s. Waiting breath: 4 s between 100% and 30% opacity. Disc fill 420 ms, check 340 ms, pop to 106%; attention bounce 550 ms with ripples 800 ms apart; failure shake 500 ms; stage change 320 ms.
- An interrupted animation continues from the value on screen; a row rebuilt by paging or reopening resumes from per-task memory. A first sight draws the final state, and arrivals play once per request.
- Loops run at most 30 fps and only while the window is visible and unoccluded; Windows leases its clocks (`AnimationLease`) so a discarded row stops them. Reduce Motion settles at the target.

### Checks

`scripts/diagnostics/test-codex-progress.py` runs the real Codex executable against a loopback model with a disposable profile and the built Mac app (`--mac-app`) or Windows engine (`--engine`). It checks registration, guidance, a lowered estimate, the terminal outcome, disable, same-name conflicts and upgrading an older entry; `--model` picks the model metadata Codex applies. The Mac run drives the Settings switch through accessibility under its own preferences domain; quit Pacer first. `TaskStatusIconViewTests` cover the Mac icon; the Windows `progress` and `settings` presentation groups cover WPF.

## Tasks, completions and notifications

- `ActivityApplicationState` merges activity, applies visibility, retains completions, tracks pending replies and notice baselines, and publishes the earliest display deadline. That wake-up refreshes presentation without starting collection or quota requests.
- Pending attention joins its task's row without changing a running phase.
- **Mark All as Read** acknowledges every displayed unread ended family through `CompletionInbox`, excluding running or waiting families, outstanding requests and hidden sessions. It never navigates or answers a request.
- **Acknowledgment.** A verified successful open dismisses the matching ending, plus terminal descendants captured at the click that still match after the open returns. Terminal dispatch, failure, expiry and source removal write nothing, because launch success alone does not prove the conversation opened. Activating a local host app counts as opened. Remote Control acknowledgment binds to the device routes published with each update.
- Completion notifications deduplicate by thread and turn and stay quiet for historical startup logs.
- **Notifications.** One switch (`systemNotifications`) covers new reply or approval requests, turn endings and interruptions, a quota window first reaching 15%, and DeepSeek's alerts while their bar warning is on. Replies, approvals and endings always show in the collapsed bar. Enabling asks for permission immediately and turns back off if refused. `completedRetentionMinutes` (default 30, 0 until clicked) sets ended-task retention.

## Island, collapsed bar and main window

### Geometry and placement

- Width always follows content. The header measures its visible components; a real notch reserves equal wings around the camera. Expanded width is 404–680 pt and never narrower than the collapsed bar. Changes use the top-anchored, quantized spring.
- `islandDisplayMode` is `notch` or `floating` (Custom); `automatic` remains the state before a choice and attaches only on a display with a notch. Custom adds `islandPosition` (`center`, `topLeft`, `bottomLeft`, `topRight`, `bottomRight`; unknown or unset reads as center). A corner docks the bar as a vertical strip; `IslandGeometry.windowFrame` quantizes around that corner, so it never moves by a rounding point.
- `islandPositionPerDisplay` (default on) keeps a place per display in `islandDisplayPlaces` (`IslandScreenMemory`: versioned JSON keyed by display UUID, at most 12), while `islandDisplayMode`, `islandPlacement` and `islandPosition` always hold the current display's place. The Display choice saves `displayUUID` beside `displayID`. Windows mirrors these rules in `IslandScreenMemory.cs`.

### Collapsed bar

- `compactIslandLayout` is schema 9: left and right lanes and the enabled warning kinds. Migrations, which run without writing during load: schema 9 adds DeepSeek's spike and budget kinds, removes the ×2 kind and adds the price clock; 8 adds low balance; 7 merges the 5h, delayed-update and SSH components into one warnings slot; 6 maps former Codex/Claude values to the rings plus the value; 5 replaces the status icon and task count with the activity badge; 1–3 read the old combined quota component as both providers. Unknown names are ignored, unsupported schemas use defaults, and an intentionally empty layout stays empty.
- `compactComponentOptions` holds every component's choices as versioned JSON whose fields decode independently; a missing or unknown field falls back alone, and data over 4 KB reads as defaults. Settings edits one field at a time and leaves fields it cannot read untouched. `CompactBarPresentation` applies them so both platforms draw the same text.
- The warnings slot shows enabled warnings whose condition holds, solid marks before outlined ones. The activity badge's orbit is a render-server animation that pauses while occluded.
- `compactBarSize` (`small`, `standard`, `large`, `extraLarge`) scales every length through `CompactBarMetrics`.
- `islandAppearance` is black, dark or light Liquid Glass, or graphite. Liquid Glass has no app-level settings and follows the system look; Reduce Transparency shows the solid surface. An island at a hardware notch draws its collapsed bar pure black whatever the material.
- Layout and visibility choices never change collection, timing or freshness.

### Main window

- Settings is Pacer's main window (`SettingsWindow`, frame `PacerMainWindow`), built from `MainWindowKit.swift`. `settingsPane` remembers the page; values from the earlier Settings window map forward (`connections` to Remote, `reminders` to Notifications, `whatsNew` and `help` to Help & Updates, whose tab is `settingsAboutTab`).
- Settings apply as they change, calling `applySettings` after a 0.25 s coalescing delay that is flushed on close. Text fields commit on Return, focus loss or close and keep the last valid value. The window releases its content on close and rebuilds from saved preferences.
- `dockIcon` (`whileOpen` default, `always`, `never`) switches the activation policy as the window opens and closes.
- Open at Login uses `SMAppService.mainApp` and stores no preference: macOS owns the record. Pacer rereads the status when Settings opens or the app activates and treats Requires Approval as on. Demo uses an in-memory record.
- The welcome guide shows once per major line (`welcomeGuideVersion`, currently 4) on a fresh install or major upgrade. Within a line, the first launch after an update shows What's New once for `WhatsNew.releases` newer than `whatsNewVersion`; that record never moves backwards, and 3.2.1's note requires a confirmed 3.2.0 baseline. A highlight can carry a switch so existing users can adopt a setting.
- Help's legend and Support & Feedback write no preferences and make no network requests.
- A found update shows in the sidebar, Overview and Help & Updates ([automatic updates](automatic-updates.md#packaging-and-ui-integration)).

## Persistence

- The production bundle identifier is `com.codexpacer.app`, and `~/Library/Application Support/CodexPacerIsland` stays the cache and lock location. A one-time allowlist migration copied unset preferences from the native preview; existing production choices win. Keep these, `SUFeedURL` and `SUPublicEDKey` stable ([automatic updates](automatic-updates.md)).
- Running tasks, completed cards and unread reminders live in memory; startup history never replays old alerts.
- Successful verified opens persist up to 512 acknowledgment hashes in an atomic, owner-only file, so a dismissed ending stays dismissed after relaunch. Hashes distinguish provider, local home, configured host home, session, explicit turn and ending state (legacy turns without an ID add normalized times). No path, account or task text is stored; corrupt or unsupported files are ignored.
- Quota history follows [Quota display and history](#quota-display-and-history); DeepSeek history and its salt follow [Balance, history and budgets](#balance-history-and-budgets).
- Retired preferences are ignored and removed on the next Settings save: `claudeSSHHosts`, `lowQuotaReminder`, `inputReminder`, `completionReminder`, `islandWidthMode`, `specifiedIslandWidth` and earlier width keys, the former refresh-interval, expanded 5h-period and glass style, tint, transparency and corner-radius preferences.

## Continuous integration

`.github/workflows/platforms.yml` tests each change once, on its pull request into develop. `.github/workflows/release.yml` builds, signs and publishes a tagged release.

- **Pull request into develop.** Only the platforms the change touches run. `scripts/ci/changed-platforms.py` decides this from the changed files:
  - Shared Core, the root package, `native/Info.plist`, the workflow and unknown files run both platforms.
  - Mac-only and Windows-only paths run only their platform.
  - Documentation runs nothing.
  - The platform contract, its tests, the shared localization check and the DeepSeek web identity check run once on Linux for every run.
  - The Mac suite runs on Apple silicon.
  - Windows x64 compiles the shared engine and runs its tests in one job. Another job builds the release engine and desktop once. Three jobs then share that build for the desktop, Claude runtime, presentation and idle checks; none of them installs the Swift toolchain. ARM64 compiles only.
  - `test-presentation.ps1 -Group` takes a list of groups. Each group that `all` runs is in exactly one of the three test jobs, and `scripts/windows/check-contract.py` checks this against the runner's `AllGroups`.
  - The release engine and its two adapters are cached per architecture. The key is the engine source snapshot from `stage-engine.py`, plus the toolchain lock and the build scripts. On a hit, `build-engine.ps1 -Products` copies them instead of compiling. GitHub limits a pull request's caches to that pull request and its base branch, so a pull request hits either an earlier run of its own with the same engine sources, or what the develop warm-up saved.
  - The Windows package smoke test and the installer and patch lifecycle run in their own job when the change touches what the installers are built from or what those checks start: the installer, maintenance, update and hook projects, the packaging scripts, the toolchain pins, the workflow, and the app's launch, single-instance, installation identity, notification and startup registration code.
  - A newer push cancels the pull request's older run.
- **Push to develop.** Only `.github/workflows/engine-cache.yml` can run, and only when the push changes what the engine cache key covers. For each architecture it looks the key up and ends there when it is cached; otherwise it builds the release engine and its adapters once and saves them, so the next pull requests start with a hit. It tests nothing. `scripts/windows/check-contract.py` keeps its path filter and key in step with the snapshot and the other caches.
- **Push to main or a promotion pull request into main.** Nothing runs.
- **Manual Platforms run.** Runs every test job, on any branch.
- **Release tag (`vVERSION`).** The code is what develop already tested, so `release.yml` tests nothing again. [The release](releasing.md) workflow:
  - builds the Windows installers: x64 with its package smoke test, and ARM64 without running it;
  - builds, signs and notarizes the universal Mac DMG, which compiles both Mac architectures;
  - signs both update feeds and publishes the GitHub Release.

  Its Windows jobs hold no secrets; only the Mac and publish jobs use the `release` environment, and `scripts/windows/check-contract.py` keeps it that way. A release run is never cancelled. A manual run does everything except publishing.

## Performance checks

The event benchmark replays identical synthetic Desktop IPC patches through two source trees and checks that projected state and emitted events match (ignoring wall-clock timestamps), alternating execution order. To compare an uncommitted change with the current commit:

```sh
task_baseline="$(mktemp -d /private/tmp/pacer-baseline.XXXXXX)"
git archive HEAD native | tar -x -C "$task_baseline"
python3 scripts/performance/benchmark-events.py \
  --baseline "$task_baseline" --candidate . \
  --output output/performance/events.json
```

Use the intended baseline ref instead of `HEAD` for committed changes. Results measure component CPU cost, not whole-app speed, memory, energy or SSH IO. Keep raw results under ignored `output/`, and profile the packaged app for UI measurements.

Live UI measurements need a verified candidate PID, an unlocked screen and fresh main-panel checks at the interval boundaries; a window with unknown lock timing or possibly stale frames is UI-unconfirmed and excluded. Record task and source changes during the run, since an active run is not idle. Per-process CPU and energy counters cover only the captured processes, not WindowServer, the GPU, remote helpers or whole-system power.

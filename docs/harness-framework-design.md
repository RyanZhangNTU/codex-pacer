# Harness modules

A Harness is the app that runs a task and keeps its conversation. Codex, Claude Code, DeepSeek Harness, WorkBuddy, WorkBuddy AI and Antigravity are modules of one framework: the same registry, module modes, activity lifecycle and settings pages on both platforms. A WorkBuddy task stays a WorkBuddy task even when it runs a DeepSeek model.

## The registry

`HarnessRegistry` (Core) holds one `HarnessDescriptor` per module, in display order. Everything that lists or draws modules reads it: the settings sidebar, the module library, onboarding, Help, the collapsed bar, the expanded panel, notifications and both hosts.

| Field | Meaning |
| --- | --- |
| `id`, `name`, `symbol` | Stable ID (also the preferences key and string family), display name, glyph when no artwork exists. |
| `defaultMode` | `automatic` for every module: on when found on this computer. |
| `brand` | Dark and light colors, plus the accent lift and light-glass luminance that keep it apart under a single accent color. |
| `website` | Where the module library sends people who don't have the app. |
| `balance` | `quotaWindows` (Codex, Claude, Antigravity), `wallet` (DeepSeek) or `accountCredits` (WorkBuddy). Code asks for a kind, never for a list of IDs. |
| `hasTaskProgress`, `hasRateDisplay`, `reportsSessionUsage`, `progressConnector` | Capabilities. |
| `accountCredits` | Sign-in sites, the bill request and the summary script, for account credits. |

`HarnessRegistry.ids(where:)` answers capability questions (`\.hasQuotaWindows`, `\.reportsAccountCredits`). `legacyIDs` remains only where the three original collectors need their own orchestration, such as `ApplicationLifecycleCoordinator`'s refresh order.

Strings follow key families by module ID, so a new module adds strings without code: `module.<id>.summary`, `welcome.module.<id>_missing`, `main.search.<id>`, `help.<id>.*`, `<id>.progress_ring_help`, `<id>.login.*`, `main.history.<id>_week` and `_empty`. Generic pages use the `harness.*` family and fall back to `help.harness.tasks` when a module has no topics of its own.

## The module library

`ModuleLibrary` combines provider modes, installation detection and the modules a host supports. It keeps registry order within each group.

- The Settings sidebar lists detected and explicitly enabled modules, followed by **Module Library** with the count of the remaining modules. Every supported page is reachable from the library and search.
- The Module Library shows both detection groups in full. Each tile has an icon, name, inline ⓘ, state and round on/off button. The body opens the module page. The ⓘ reveals a one-sentence summary inside that tile, and an undetected module with a website offers **Get** below its name. **More coming** occupies the last slot of the last visible group. Both hosts follow the [Module Library layout](windows-shell.md#module-library).
- Onboarding shows prominent modules as cards and folds the others under “N more not found on this computer”.

Local modules count as installed when the app or its data file is found in a supported location. A definition can use the data directory itself as evidence, as Antigravity does before its first conversation.

## Activity

Every module plugs into the same adapter table for start, refresh, policy, discovery, reset, sleep and shutdown. Codex, Claude and DeepSeek keep their verified collectors and submit complete snapshots. New modules use the shared local adapter:

```text
LocalHarnessDefinition(descriptor, platforms, home, dataFile, executables, conversation scheme, progress config, makeMonitor)
LocalHarnessMonitor.start(home, policy, publish) / refresh() / updatePolicy(_) / stop()
publish(HarnessActivity(activities, requests, status, scope, conversationURLs, usage))
```

`HarnessActivitySources` binds each source with a generation, orders its updates and starts an alert baseline per account scope, so historical endings never notify. An observation without an account keeps the last scope; only another account resets the module. `ActivityApplicationState` keeps a baseline for every registered module from the first reconcile, so a task first seen waiting still notifies.

Account credits are read by the host's own sign-in (a web view per module and site). The Windows host sends each reading to the engine with `setAccountCredits`; the Mac model holds it directly. From there Core draws the collapsed-bar value and ring (`CompactBarContext.Credits`), the low-credits warning, `HarnessCreditsNoticePolicy`'s notifications and the History week (`HarnessWeekPresentation`, from `HarnessUsage.daily`).

## Compatibility

- Activity IDs, read digests, notification references, remote routes and quota history keys of the original modules are unchanged.
- Preferences keep `providerModule.<id>`. Local modules add `disabledHarnessProgress`, `hiddenTurnCredits` and `harnessHomes`. A ring choice is a module ID; one this version doesn't know draws nothing instead of invalidating the bar. Layout schema 10 turns the low-credits warning on.
- The Windows engine keeps protocol version 1. Hosts that don't announce `supportsHarnessModules` see only the original three modules. The engine ignores module IDs it doesn't know, from a newer or older host, and applies the rest of the configuration; malformed IDs are still rejected.

## Adding a module

For a task source that writes local files or a database:

1. `<Name>Harness.swift` in Core: a `LocalHarnessDefinition` with its descriptor, and a monitor conforming to `LocalHarnessMonitor`. Read only what the island shows, bound every read, and test the parser with synthetic records: baseline silence, missed updates, source changes and account isolation.
2. Register it in `HarnessRegistry.localHarnesses` and add `static let <id>` to `AgentProvider`.
3. Strings for the key families above, in `en` and `zh-Hans`; then run `scripts/windows/build-localization.py` and `build-shell-resources.py`.
4. Optional artwork: `provider-<id>.png` and `provider-<id>-outline.png` in Core resources. Without it, the symbol is drawn.
5. Optional: account credits (`accountCredits` and a summary script), a progress connector (`progressConfigFile`, `progressRuleDirectory`, `progressConnection`), a conversation scheme for navigation. For an owned progress plugin or quota from a verified local service, see [Antigravity on Mac](#antigravity-on-mac).

Colors, icons, sidebar rows, the library, onboarding, Help, the collapsed bar, notifications and History follow from the descriptor on both platforms. Panel blocks are still an enumerated list in `ExpandedPanelLayout`; a module with its own panel block adds a case there.

## Antigravity on Mac

The local definition registers the app, its data folder, the Gemini and Claude/GPT quota pools, and app-only navigation. The task reader joins local SQLite and transcript metadata to typed steps from the running app. A model running inside Antigravity belongs to the Antigravity module.

- **Local host port.** `LocalHarnessIO` can supply an `AntigravityLocalHost` to verify the process and listener and send a bounded loopback request. Core owns the request allowlist, source generation and revocation.
- **Local quota coordinator.** A monitor implementing `LocalHarnessQuotaSource` publishes a coordinator factory when it verifies a session and clears it on loss. The host supplies the history store and installation credential, refreshes through `LocalHarnessQuotaCoordinator`, and rejects updates from a retired owner. A descriptor’s `quotaGroups` selects the island bucket. History and quota warnings receive the full snapshot.
- **Owned progress plugin.** A definition with `installsProgressPlugin` selects the plugin installer in `progressTarget`. Installation and cleanup use the fixed customization profile, independent of the chosen task folder. The guide opens the app and illustrates its approval card when a request identifies Pacer’s own progress tool. A completed call to the owned tool attributes progress to the calling task.

The Windows engine uses the same monitor and quota coordinator. Its installation and listener checks are described in [Windows engine development](windows-engine.md#antigravity).

## WorkBuddy and WorkBuddy AI

Tencent ships two separate apps. They run side by side, each with its own data folder, sign-in, account, site and link scheme, so each is a module. One adapter (`WorkBuddyHarness`) serves both through an edition.

| | WorkBuddy (`workbuddy`) | WorkBuddy AI (`workbuddy-ai`) |
| --- | --- | --- |
| App | `WorkBuddy.exe`; on the Mac, "WorkBuddy" | `WorkBuddyAI.exe`; on the Mac, "WorkBuddy AI" |
| Data | `~/.workbuddy` | `~/.workbuddy-ai` |
| Links | `workbuddy://` | `workbuddy-ai://` |
| Account site | www.workbuddy.cn | www.workbuddy.ai |
| Name | WorkBuddy | "WorkBuddy AI (International)" in Settings and the Module Library; "WorkBuddy AI" elsewhere |

A module not found on the computer stays in the Module Library, so most people, who have only the China build, never see the international one.

| Topic | Behavior |
| --- | --- |
| Data | `workbuddy.db` (SQLite in WAL mode, opened read-only) and `projects/<workspace>/<session>.jsonl` in the module's folder. A custom folder can be chosen in Settings. |
| Tasks | Interactive sessions, home-screen tasks and local automation runs. Normal completion and manual stop are told apart by the transcript's final reply or abort marker; a question needs a pending session and an unanswered tool call in the same turn. |
| Account | The verified `account-snapshot.json` owner scopes tasks and alerts. An unreadable copy during a rewrite is retried, not treated as a sign-out. |
| Credits | Per turn from `session_usage.credit_json`, keyed by request ID; per day from the UUIDv7 time in those IDs; the balance from the site's bill after sign-in. |
| Credit kinds | The bill's packages follow WorkBuddy's own families, keyed by package code. Plan base and plan bonus refresh every plan cycle. Rewards and top-ups never refresh and lapse at their own dates. Only the highest plan base counts, as on WorkBuddy's own page. |
| Dial | Core words it for both platforms (`HarnessCreditsPresentation`). The ring is the month's credits. Above the figure are the days to the refresh, or the extra credits lapsing within the user's window. The center shows the month's share by default, or the month's credits, or everything available. The gap holds the extra credits as an amount, or "This month" when there are none. Extra credits are never shown as a share. |
| Progress | `pacer_progress` in `mcp.json` with a rule asking tasks to report; WorkBuddy asks the user to trust it once. On by default, like the other rings. `HarnessProgressGuide` turns the setup into steps until WorkBuddy reports progress. |

Measurements and live checks are in [Harness validation](harness-validation.md).

## Prior art

Descriptor-driven providers in [CodexBar](https://github.com/steipete/CodexBar/blob/main/docs/provider.md), separate parsers and watchers in [AgentsView](https://github.com/kenn-io/agentsview), connector projections in [CASS](https://github.com/Dicklesworthstone/coding_agent_session_search) and per-source usage rules in [ccusage](https://github.com/ccusage/ccusage) informed this design.

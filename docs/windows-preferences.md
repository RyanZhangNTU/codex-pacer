# Windows preferences and quota history

Windows keeps display and source preferences in `%LOCALAPPDATA%\CodexPacer\preferences-v1.json`. The file name stays stable across upgrades. Schema 2 uses the Mac UserDefaults keys; schema 1's Windows aliases migrate on the next successful edit. Loading never rewrites a file. Unknown root keys survive edits.

Every released Windows build (4.2.2 and later) uses schema 2. Schema-1 files come only from development previews before 4.2.2, which cannot read schema 2.

`PreferencesCodec` maps the desktop record to these keys:

| Choices | Stored keys | Missing-value defaults |
| --- | --- | --- |
| Language | `appLanguage` | `system` |
| Position and attachment | `islandPlacement`, legacy `islandPosition`, `islandDisplayMode`, legacy `floatingIsland` | No explicit position; `automatic`, then the legacy floating choice |
| Display and fullscreen | `displayID`, `displayName`, `displayX`, `displayY`, `showInFullscreen` | Main Display, fullscreen off |
| Surface and quota style | `islandAppearance` (`classic`, `liquidGlass`, `liquidGlassLight`, `graphite`), `expandedQuotaStyle` | `liquidGlass`, `split`; the existing platform fallback still applies |
| Collapsed bar | `compactIslandLayout`, `compactComponentOptions`, `compactBarSize`, `compactSingleTask`, `compactMetric` | Core's standard layout, every component default, `standard`, `stage`, `remaining` |
| Quota windows and rings | `quotaWindowID`, `claudeQuotaWindowID`, `quotaRingOuter`, `quotaRingInner` | `auto`; absent ring keys mean automatic |
| DeepSeek | `deepseekPanelStyle`, `deepseekMode`, `deepseekBalanceSource`, `deepseekDailyBudget`, `deepseekWeeklyBudget`, `deepseekRingPeriod`, `deepseekSpeedSource`, `deepseekShowsTurnCost`, `deepseekLowBalanceLine`, `deepseekSpikeLimit` | `detailed`, `balance`, `automatic`, no amounts, `day`, `local`, turn cost on |
| Privacy and visible tasks | `hideProjects`, `showAppButtons`, `showEmbeddedCodexSessions`, `showClaudeCloudProjects` | `false`, `true`, `true`, `true` |
| Task progress rings | `claudeProgressRing`, `codexProgressRing`, `deepseekProgressRing` | `true`; a saved `false` is kept |
| Retention and settings pane | `completedRetentionMinutes`, `settingsPane` | `30`, `general` |
| Sources and Claude organization | `codexExecutable`, `codexHome`, `claudeHome`, `deepseekHome`, `claudeWebOrganizationID` | Empty overrides |
| Modules | `providerModule.codex`, `providerModule.claude`, `providerModule.deepseek` | `automatic` |
| Notifications | `systemNotifications` | `false` |
| Welcome and release notes | `welcomeGuideVersion`, `whatsNewVersion` | `0`, unset; only demo suppresses records when a page is explicitly opened |

The layout is the same UTF-8 JSON Data saved by the Mac, represented as base64 in this JSON file. Its warnings remain inside the layout. `compactComponentOptions` is Core's `CompactComponentOptions` JSON Data, also base64; the engine decodes it per field, so a damaged or oversized value reads as the defaults without touching other settings. `compactBarSize` is `small`, `standard`, `large` or `extraLarge`; an unknown size reads as `standard`. `compactSingleTask` adds `percent`. An explicit empty layout stays empty. Present empty or unknown ring choices mean no ring; an absent key means automatic. A saved center position is distinct from an untouched position. The desktop pane name `collapsed` is stored as the Mac value `collapsedBar`.

`islandPlacement` stores `edge` (Free, Top, Bottom, Left, or Right) and the collapsed bar's center as work-area fractions `x` and `y`. A docked edge fixes the coordinate perpendicular to that edge. Old profiles keep their center or corner until the user moves the island or resets the position. An invalid placement falls back to the old position. Notch mode leaves the last free placement saved. Moving the island to another monitor saves its placement and display in one edit. While a disconnected display is shown on Main Display, a move that stays there saves only the placement, so the island still returns to the saved display when it reconnects.

`displayID` follows Mac's main-display meaning: an absent, null or empty value, numeric `0`, and string `"0"` all select Main Display. A specified Windows display uses its device-interface path string; Mac's nonzero numeric display IDs do not identify Windows devices. `displayName` and physical desktop coordinates `displayX` / `displayY` provide a unique name-and-position fallback when an interface path changes. Disconnecting falls back to Main Display while retaining the saved choice for reconnection. `showInFullscreen` uses the Mac boolean key and defaults to false.

The picker offers one Main Display choice plus individual devices. Old `displaySelection` values `automatic` and `primary` both mean Main Display. Schema-1 profiles retain their original values and bytes when read, then migrate only on a successful edit. Schema 2 derives the selection from `displayID`; a monitor without a device path uses `displaySelection: "specified"` with its name and position. Unrelated edits preserve an existing main-display representation, including a legacy alias retained in a schema-2 file. These fields never reconfigure collectors.

Open at Login remains an OS registration managed by the startup service, as on Mac. It has no invented preference key. Appearance follows the system theme; `--theme` is a demo fixture. Credentials and browser sessions remain in their existing separate stores.

## Applying edits

DeepSeek's Balance/Budget switch retains saved daily and weekly amounts in balance mode. Switching to an empty budget uses Core's suggestion; clearing a field or entering zero disables that amount. The day/week selector, account/local speed source, Simple/Detailed panel and turn-cost choice use the same saved keys as Mac. Ring hints use Core's actual drawable rings and link to the collapsed-bar editor. Low-balance and spending-spike thresholds remain in Reminders, with automatic defaults when unset. WPF does not recalculate budgets, billing, thresholds or local day/week boundaries.

Every persisted field waits asynchronously for `validatePreferences`. The engine validates the shared compact presentation input and returns a SHA-256 acknowledgement of the complete preference payload. This read-only query has a three-second deadline and returns no source paths or organization identifiers. Collector changes also wait for the existing `configure` acknowledgement, with its fifteen-second deadline. Host-only edits do not reconfigure collectors.

The session serializes edits from all settings windows. Disk writes run off the UI thread, use a one-second named-mutex deadline, and compare the file with the version the session loaded. A stale writer fails instead of overwriting another writer. Reload or restart before editing a profile changed by another process.

Preferences are limited to 60 KiB. Writes flush a new temporary file and atomically replace the destination. Redirected paths remain rejected. A malformed or undecodable file is renamed to `<original>.damaged-<UTC timestamp>`, retaining its exact bytes; at most three backups of each original are kept. The app uses defaults and can save a new file. Settings shows the recovery notice once, with the backup filename only.

A higher schema remains protected from ordinary writes. Settings explains that a newer version wrote the file and offers **Back Up and Use Defaults**. That explicit action obtains the normal engine acknowledgement before quarantining the file and saving defaults. A failed write restores the last acknowledged fields and collector configuration and shows an error. If the collector rollback fails, settings offer a restart. Independent-writer conflicts still require reloading the profile.

## History storage

Codex and Claude retain Core's `QuotaCycleCache` envelope, home-path hash, account-scope checks and separate provider directories. Windows supplies bounded file reads and atomic replacement through `PlatformFileSystem`. The existing thirty-minute coalescing, immediate writes on context changes, shutdown flush and seven-day retention are unchanged. Old fine-grained curves load through Core's existing compaction without a write during loading.

Windows validates file bounds, envelopes, dates and percentages before projecting a curve. Damaged or oversized files are quarantined using the same backup rule and rebuilt as empty history. A valid cache for another account, or an expired reading, is not corruption and can still be replaced normally. Codex and Claude report a cache-write warning while retaining live quota readings when storage fails.

DeepSeek uses `DeepSeekBalanceHistory`, with eight days of balance/spend data and its existing seven-day display. Its file remains global to Pacer's billing source and credential fingerprint; changing the log home adds no new isolation key. The version-1 envelope, 64 KiB limit and local credential salt are unchanged. Damaged history is quarantined and rebuilt. A failed cache write keeps the live balance available; DeepSeek has no separate history-write warning.

Windows completion acknowledgements also quarantine damaged files before rebuilding, retaining their existing 64 KiB hashed format and in-memory acknowledgement behavior. History and acknowledgement recovery is silent; `storageRecoveryStatus` reports counts by store type, without file contents or directory paths. Higher history versions stay protected until the explicit Settings action backs up the observed files. Read-only diagnostics refuse that action, and demo never touches production storage. Maintenance inspection remains read-only even for damaged preferences.

The optional Core file adapters and acknowledgement protection default to the existing Mac behavior. Mac storage paths, UserDefaults values, permissions, formats and write timing are unchanged.

## Regression and demo checks

`PreferencesPersistenceChecks` submits every public preference field to a real offline engine, saves it, and reads it through a fresh store. It also covers legacy migration, key presence, unknown values, independent writers, failed acknowledgements and damaged files. Existing session and settings assertions remain in place.

`DisplaySelectionChecks` also launches a new test process to read specified displays, legacy aliases and each supported main-display representation. It checks schema-2 migration, exact key names, preserved bytes during reads, fallback metadata and fullscreen persistence.

`PersistentSettingsChecks` edits real settings controls, checks two windows and disk-failure rollback, then starts a new desktop process with the isolated saved profile. It checks English/Chinese and light/dark captures. `PreferencesResponsivenessChecks` covers silent, slow and exiting engines, dispatcher callbacks, visible errors, one-shot requests and rejection of late replies.

`WindowsHistoryPersistenceTests` covers both quota providers, home/account changes, deferred flushes, Mac-compatible bytes, corrupt/future/oversized files, extreme numeric values, DeepSeek legacy credential binding and protected read records. `QuotaStorageTests` and `PlatformStorageTests` also run on Mac and check the unchanged default behavior.

For a persistent demo launch, use `--demo --reference-fixture --demo-preferences <absolute-fixture-path>` with either a preview capture or an isolated `--activation-qa` scope. The production preference path is rejected. Ordinary demo launches keep their existing ephemeral settings. Only synthetic profiles belong in this fixture.

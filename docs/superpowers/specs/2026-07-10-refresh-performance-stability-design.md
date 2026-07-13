# Refresh performance and stability design

## Problem

Codex Pacer cannot currently guarantee that token statistics and live quota data refresh on the configured schedule. The token scanner, live quota query, tray renderer, popup snapshot builder, and frontend timers can all initiate overlapping work. Several of those paths are synchronous, and some run database or process I/O on the macOS main thread.

The scheduler starts a token scan before it starts the live quota query. It schedules the next token run from the previous completion time, so scan duration becomes part of the refresh interval. A failed scan remains due and can be retried by the five-second scheduler poll. Live and tray work use atomic running flags; a trigger that arrives while a worker is busy is discarded instead of being queued.

The presentation path amplifies the problem. Opening or polling the menu-bar popup can run a due token scan, load all usage events, build a full overview, load the events again for the seven-day quota trend, and read every historical quota sample for the selected bucket. Tray rendering performs database work inside `run_on_main_thread`, and a stale live cache can also start the Codex app-server from that path.

The production database measured during this review was 245.4 MB and contained 2,247 sessions, about 167,600 usage events, and about 419,900 quota samples. A current seven-day view needed about 4,800 usage events and 5,000 quota samples, but the existing queries loaded about 167,600 and 209,300 rows. Quota history and its indexes accounted for about 82.8 percent of the database. Within a quota window, retaining value changes instead of every repeated observation could remove about 83 percent of five-hour rows and 92 percent of seven-day rows.

Changed session files have a second source of write amplification. The incremental importer parses a changed JSONL file from the beginning, deletes every derived usage event and quota sample for the session, then rebuilds them. This is expensive for active files that grow by a few lines but are already tens of megabytes long.

## Goals

The design has six goals:

1. Token and live quota refreshes start on independent fixed schedules and cannot delay one another.
2. A trigger that arrives during active work is coalesced and eventually serviced. It is never silently lost.
3. Passive UI reads never start a scan, launch a process, or perform an unbounded database query.
4. Tray rendering performs no file, database, or process I/O on the UI thread.
5. Normal background work reads and writes only data that changed, while memory use remains bounded as history grows.
6. Failures expose stale data honestly, retry with bounded backoff, and recover after settings changes, sleep, clock changes, truncation, and database contention.

## User-visible refresh semantics

`auto_scan_enabled` remains the master automatic-refresh switch.

When automatic refresh is enabled, the token lane and live quota lane use the configured refresh interval but maintain independent deadlines. They continue to run when the dashboard and popup are hidden. Menu visibility and the selected dashboard bucket do not determine whether live quota data stays fresh.

When automatic refresh is disabled, both scheduled lanes pause. Manual token scans and manual live quota refreshes remain available. Opening a window or popup only reads the latest snapshot; it does not silently override the disabled setting.

A passive read may return stale data with explicit freshness metadata. A manual refresh may wait for the current singleflight generation for up to the fixed live-query timeout. If that generation fails, the UI keeps the prior data and shows its source timestamp instead of presenting it as fresh.

## Selected architecture

One `RefreshCoordinator` owns the scheduling state for token, live quota, and display snapshot work. Callers submit intents through a channel. Only the coordinator decides whether to start work, merge a trigger into a running generation, schedule a retry, or publish a completion.

The coordinator owns state, not the work itself. Token parsing, app-server queries, SQLite persistence, and display snapshot construction run on bounded workers. Workers send typed completion messages back to the coordinator. This keeps scheduling responsive while a scan or external process is slow.

The main units are:

- `RefreshCoordinator`: owns deadlines, lane generations, pending reasons, retry state, and configuration changes.
- `TokenRefreshExecutor`: runs incremental or full imports and reports timing, source generation, and committed usage revision.
- `LiveQuotaExecutor`: owns the only app-server singleflight and reports source time separately from cache time.
- `DisplaySnapshotStore`: keeps one small immutable snapshot with usage, quota, settings, and presentation revisions.
- `DisplaySnapshotBuilder`: uses bounded SQL queries to rebuild the snapshot off the UI thread.
- `TrayPresenter`: compares the new presentation with the last applied presentation. The main-thread closure only calls tray setters.
- Surface event bridges: notify the popup and visible dashboard that a newer revision is available.

The existing `lib.rs` command layer will become a thin adapter around these units. Refresh and presentation logic should move into focused modules instead of expanding the current file.

## Coordinator state and scheduling

Each data lane stores:

```text
interval
next_deadline
running_generation
pending_reasons
last_attempt_at
last_success_at
failure_streak
retry_at
source_generation
```

The in-process deadline uses a monotonic clock. On startup, the coordinator maps the persisted wall-clock success time to the current monotonic clock. Invalid, missing, or overdue persisted timestamps produce one immediate catch-up run.

After a scheduled run starts, the next normal deadline advances from the prior planned deadline until it lies in the future. It does not use the worker completion time. If the application misses several intervals while asleep, the coordinator records the missed count and starts one catch-up generation. It does not replay every missed interval.

Manual, startup, settings, scheduled, wake, and fallback triggers are represented as reason bits. If a lane is idle, a trigger may start it. If it is running, the coordinator merges the reason into `pending_reasons`. When the generation completes, the coordinator starts at most one follow-up generation if the pending reasons still require newer data.

The coordinator records pending or running state before a worker is spawned. The UI cannot observe a false idle state during startup.

Configuration changes wake the coordinator through its channel. Shortening the interval recalculates deadlines immediately. Changing the resolved Codex home increments `source_generation`, clears freshness for the previous source, and queues a full scan. A completion from an older source generation cannot publish freshness for the new source.

The coordinator is the only owner of refresh freshness. A settings save updates configuration fields without reading and rewriting `last_scan_*` or live success fields. This removes the race where an older settings snapshot can overwrite a newer completion.

Runtime scheduling never derives elapsed time from the wall clock after startup. A backward wall-clock change can affect display timestamps but cannot pause a monotonic deadline. An application resume signal wakes the coordinator, which recalculates overdue work and queues one catch-up per lane.

## Retry and timeout behavior

Token and live failures have separate counters. A failure schedules a retry with jittered delays based on 5, 15, 30, 60, 120, and 300 seconds. The delay is capped by the configured interval and five minutes. A successful generation resets the lane's failure counter.

Retry deadlines do not move the normal fixed-rate deadline. A retry and a scheduled trigger that become due together merge into one generation. A failure in one lane never forces or delays the other lane.

The live app-server timeout is fixed at 10 seconds. It never scales with the refresh interval. Foreground and background requests join the same generation, so at most one app-server child process is active.

Fallback data records these fields separately:

```text
source_fetched_at
cached_at
is_fallback
last_live_success_at
```

Loading a persisted fallback may update `cached_at`, but it cannot update `source_fetched_at` or `last_live_success_at`. A fallback therefore remains stale and does not suppress the next retry.

Live fallback reads the in-memory snapshot or `latest_rate_limits` only. It never starts a token scan on the caller thread. If a repair requires session-derived quota history, the fallback path submits a token intent to the coordinator and returns without waiting for it.

Fresh live data is published to the in-memory snapshot before historical persistence. SQLite persistence follows on a worker. A persistence failure records a metric and queues a bounded retry, but it does not hide a successfully fetched quota value from the tray or popup.

Usage mutations remain serialized at commit time because SQLite has one writer. Parsing can proceed before the mutation lock is available. State distinguishes queued, parsing, waiting-to-commit, and committed work instead of reporting all four as scanning. Pricing recalculation is a lower-priority mutation and cannot block the live lane.

## Versioned display snapshots

`DisplaySnapshotStore` keeps one bounded value:

```text
usage_revision
quota_revision
settings_revision
presentation_revision
generated_at
token_summary
quota_summary
quota_trend
menu_settings
freshness
```

The store does not cache all events, conversations, or quota history. Its serialized popup payload must remain at or below 64 KB.

A committed token scan increments `usage_revision`. A successful live fetch increments `quota_revision`. A relevant settings update increments `settings_revision`. The snapshot builder captures those three revisions before querying. If any source revision changes while the snapshot is being built, it publishes only the consistent result and queues one latest-wins rebuild.

Snapshot getters only clone the current bounded snapshot. They do not invoke the coordinator, query SQLite, or run the app-server. Refresh commands submit an intent and return a ticket or the current stale snapshot as appropriate.

The dashboard and popup only accept events with a higher presentation revision. This prevents an older asynchronous response from replacing newer data.

## Tray and popup behavior

The tray presentation is computed on a worker from the display snapshot. The main-thread closure receives preformatted title, tooltip, icon visibility, and tray visibility values. It compares them with the last applied values and only calls setters whose values changed.

If a new display revision arrives while tray work is active, the presenter marks itself dirty. When the current apply finishes, it performs one follow-up render using the newest revision. The final update cannot be discarded because a previous update was running.

The popup WebView is created on first tray use instead of application startup. Once created, it may remain hidden for fast subsequent opens, but it runs no periodic data timer while hidden. Its entry point uses a dynamic import so the popup bundle does not load the dashboard or Recharts code.

The popup opens with the latest in-memory snapshot. Existing content remains visible during a manual refresh. A small refreshing state may change, but the data panel and measured window height do not collapse. The backend sends a versioned snapshot event when fresh work completes.

The main dashboard also removes its independent automatic-refresh timer. When hidden, it records the newest revision without loading the dashboard. It performs one reload when shown. Search requests use a 250 ms debounce and ignore or cancel superseded work so hidden or obsolete queries do not compete with tray updates.

## Query and storage changes

Presentation queries must filter before rows enter Rust.

Menu and popup summaries use dedicated SQL for API-equivalent value, total tokens, and distinct root conversation count. Trend queries group events into the required time bins in one pass. The popup does not call the full dashboard overview builder. Dashboard overview queries use the same indexed window predicates, and the conversation list uses bounded pages instead of rebuilding every conversation for each search.

Quota history queries select the exact `(bucket, window_start, resets_at)` window through the existing composite index. A small `latest_rate_limits` table stores the newest primary and secondary values for fallback reads. The latest lookup no longer sorts an entire bucket with `julianday(sample_timestamp)`.

Indexed time comparisons use integer epoch milliseconds. New usage events and quota samples populate the epoch fields at ingest. Existing rows are backfilled in bounded batches with a durable progress marker. Foreground presentation remains usable between batches. The compatibility query includes rows without an epoch until the backfill completes.

Quota history stores step changes rather than every repeated observation. The latest table is updated for freshness. The historical table inserts a row when a window begins, when used percent changes, and when a prior window closes. Repeating the same value does not grow history. Existing redundant rows are pruned in bounded background batches. Each cleanup transaction yields before the next batch and does not begin when a refresh deadline is within 30 seconds. The migration does not run an automatic full `VACUUM`; freed pages remain available for SQLite reuse.

Database initialization and bundled pricing seed work run at startup or migration time, not on every scan. Pricing refresh compares a value-bearing catalog signature before recalculating events. An unchanged signature performs no event update. Title maintenance updates only changed values and uses one transaction.

## Append-only session import

The import-state row gains a durable append checkpoint:

```text
parsed_offset
parsed_file_size
prefix_fingerprint
checkpoint_tail_fingerprint
last_complete_line_offset
last_cumulative_usage
last_model_id
parser_schema_version
```

The fingerprint covers a fixed prefix and a small block ending at the saved offset. If the file still has the same identity, its size is at least the saved offset, and both fingerprints match, the importer seeks directly to `parsed_offset`. It parses only complete new JSONL records and appends derived usage and quota changes.

The checkpoint stops at the last complete newline. An incomplete trailing record is read again on the next scan. Derived rows and the new checkpoint commit in the same transaction, so a failure cannot advance the offset beyond persisted data.

The importer falls back to the existing full parse and session rebuild when any of these conditions holds:

- the file shrank or was replaced;
- a fingerprint does not match;
- the parser schema version changed;
- a pending historical repair requires a rebuild;
- fork or topology metadata changed in a way that invalidates the checkpoint;
- the saved checkpoint is malformed or incomplete.

New files, archived moves, and explicit repair paths may take the full path once, then establish a fresh checkpoint. The parser uses typed record envelopes and borrows fields where practical so unrelated JSON payloads do not become large generic value trees.

## Memory limits

No new cache may grow with the number of usage events, quota samples, or conversations.

Conversation details use an LRU with both count and byte limits. The default limits are 20 entries and 32 MB. The detail command returns the newest 40 turns by default; older turns require cursor pagination. Conversation lists use bounded pages instead of returning every root conversation.

Workers stream SQLite rows into aggregates where possible. They do not materialize a full usage-event vector merely to compute a tray or popup value. The display snapshot and refresh state remain small fixed-size structures.

## Power behavior

The scheduler waits on its event channel until the next real deadline or configuration message. It no longer opens SQLite every five seconds to check settings.

On macOS, process activity guards cover the actual scan or live query only. Background work uses a background-appropriate activity classification. The application does not hold a user-initiated activity for the lifetime of the scheduler thread.

## Observability

Debug logs and test probes record these fields per lane:

```text
scheduled_due_at
started_at
start_lag_ms
duration_ms
last_success_age_ms
failure_streak
retry_at
missed_deadline_count
coalesced_trigger_count
running_generation
pending_reasons
```

Live metrics also record app-server duration, timeout count, active child count, fallback age, and singleflight waiters. Token metrics record files visited, bytes read, append fast-path count, full-rebuild count, mutation-lock wait, and database busy count. Presentation metrics record snapshot build time, tray queue time, main-thread apply time, payload size, and event-to-visible lag.

Warnings are emitted when start lag exceeds five seconds, live child count exceeds one, or last success age exceeds the interval plus the active retry allowance. Metrics are bounded counters and timings, not an unbounded event history.

## Delivery slices

The work is delivered in three independently testable slices on the same development branch. Each slice receives its own implementation plan and review checkpoint so later storage work cannot obscure refresh regressions in the earlier slices.

### Slice 1: refresh correctness

Introduce the coordinator, independent token and live lanes, fixed deadlines, singleflight, pending-trigger coalescing, bounded timeout, backoff, source generations, and truthful fallback freshness. Replace frontend-driven automatic refresh with completion events.

This slice is complete when token and live work cannot block each other's scheduled start and no trigger is lost during overlap.

### Slice 2: presentation and bounded queries

Add versioned display snapshots, worker-side tray computation, lazy popup loading, dynamic bundle splitting, indexed window queries, latest quota storage, quota change points, and bounded UI caches.

This slice is complete when passive getters are bounded memory reads and tray main-thread work contains no I/O.

### Slice 3: importer and write amplification

Add append checkpoints, typed tail parsing, transactional fallback, pricing signature skips, conditional title updates, and bounded historical cleanup.

This slice is complete when a normal active-session append reads only new bytes and does not delete or rebuild the session's existing derived history.

## Acceptance budgets

All timing budgets apply while the process is awake on a supported machine. Sleep recovery has a separate catch-up allowance.

| Measure | Required result |
| --- | ---: |
| Scheduled lane start lag | p95 at or below 2 seconds, maximum 5 seconds |
| Wake catch-up start | at or below 5 seconds after resume is observed |
| Active app-server children | at most 1 |
| Live query timeout | at most 10 seconds |
| Token or quota commit to visible tray | p95 at or below 100 ms |
| Token or quota commit to visible popup | p95 at or below 150 ms |
| Snapshot memory getter | p95 below 5 ms |
| Tray main-thread apply | p95 below 2 ms, no I/O |
| Main-thread longest task from refresh work | p99 below 16 ms |
| Reused popup cached content | p95 below 100 ms |
| First lazy popup creation | p95 below 300 ms |
| Popup serialized snapshot | at or below 64 KB |
| Popup JavaScript | at or below 150 KB minified and 50 KB gzip |
| Hidden-window dashboard and popup queries | 0 during a 10-minute observation |
| Fully hidden idle CPU | average below 0.2 percent, p95 below 0.5 percent |
| Application idle wakeups | at most 2 per minute |
| Conversation detail cache | at most 20 entries and 32 MB |

An unchanged automatic cycle performs no pricing rewrite, title rewrite, full event-table load, full quota-bucket load, or historical quota insert. A typical active JSONL append reads only bytes after the saved offset. Resident memory does not grow linearly with historical row count.

## Verification

Coordinator tests use a fake monotonic clock and injected token, live, persistence, and event executors. They cover independent deadlines, fixed-rate scheduling, overlap coalescing, interval changes, retry caps, startup pending state, stale fallback behavior, source-generation invalidation, sleep catch-up, backward wall-clock changes, and one active live child.

Presentation tests cover revision ordering, a revision arriving during tray rendering, diff-only tray setters, no I/O in the main-thread closure, stable popup content during refresh, stale response rejection, hidden-window inactivity, popup bundle composition, payload size, and event-to-visible timing.

Database tests use a fixture with at least 200,000 usage events and 400,000 quota samples. Query plans must use the selected time and window indexes. Snapshot getters must stay below their budget, and repeated quota values must not add historical rows.

Importer tests cover append-only growth, incomplete trailing lines, truncation, replacement with the same path, fingerprint mismatch, parser-version changes, fork repair, archived moves, transaction rollback, and a full-rebuild fallback that produces exactly the same derived rows as a clean import.

Memory tests browse 1,000 conversation details and verify both LRU limits. Long-running tests hide both windows for ten minutes and record query count, scheduler wakeups, CPU, and resident-memory stability.

Final verification runs frontend tests, ESLint, the production frontend build, Rust tests, targeted Clippy checks for changed modules, SQLite integrity checks, query-plan assertions, a local macOS release build, and the Windows release build in CI. Existing unrelated whole-repository formatting and Clippy debt is not mixed into this work.

## Out of scope

This design does not keep a persistent app-server process, add an external telemetry service, cache the complete event history, or run an automatic full database vacuum. It also does not redesign dashboard visuals. Unrelated correctness and release-pipeline findings from the broader audit remain separate work so they do not delay the refresh and performance fixes.

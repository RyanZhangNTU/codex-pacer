# Refresh correctness implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coupled polling scheduler with independent token and live quota lanes that use fixed deadlines, singleflight, coalesced triggers, truthful freshness, and completion events.

**Architecture:** A pure state machine decides when work starts and how triggers merge. A channel runtime launches token and live workers independently, then publishes typed completion and invalidation events. Tauri commands become adapters around one coordinator; passive reads never start work.

**Tech Stack:** Rust 2021, Tauri 2.10, `std::sync::mpsc`, Chrono, Rusqlite, React 19, TypeScript 5.9, Node 22.18 test scripts.

## Global constraints

- Execute this slice first. Run its full verification and review checkpoint before starting the presentation or importer plans.
- `auto_scan_enabled` is the master switch. When enabled, token and live quota refresh on independent schedules even while windows are hidden. When disabled, scheduled work stops and manual work remains available.
- The live app-server timeout is exactly 10 seconds, and at most one live child process may run.
- A trigger received during active work produces at most one follow-up generation and is never discarded.
- Runtime deadlines use a monotonic clock. Wall time restores state after launch and displays freshness only.
- Passive getters do not scan files, query the app-server, or wait for active work.
- Frontend automatic refresh timers are removed. Existing content, focus visibility, and reduced-motion behavior remain stable during manual refresh.

---

### Task 1: Add the deterministic lane state machine

**Files:**
- Create: `src-tauri/src/refresh/mod.rs`
- Create: `src-tauri/src/refresh/schedule.rs`
- Modify: `src-tauri/src/lib.rs:1-6`
- Test: `src-tauri/src/refresh/schedule.rs`

**Interfaces:**
- Consumes: persisted success timestamps and normalized refresh settings.
- Produces: `RefreshConfig`, `RefreshLane`, `RefreshReason`, `TokenScanKind`, `CoordinatorEvent`, `CoordinatorAction`, and `CoordinatorState`.

- [ ] **Step 1: Write failing deadline and lane-independence tests**

Add `persisted_success_maps_remaining_wall_time_to_monotonic_deadline`, `missing_persisted_success_starts_one_immediate_catch_up`, `invalid_persisted_success_starts_one_immediate_catch_up`, `overdue_persisted_success_starts_one_immediate_catch_up`, `due_lanes_start_together_and_advance_from_planned_deadlines`, `token_running_does_not_block_due_live_lane`, `missed_intervals_coalesce_into_one_catch_up`, `shorter_interval_recalculates_deadline_immediately`, and `backward_wall_clock_does_not_move_runtime_deadline`.

Use this central assertion:

```rust
let base = Instant::now();
let wall = utc("2026-07-10T10:00:00Z");
let config = test_config(Duration::from_secs(300), Some(wall));
let mut state = CoordinatorState::new(config, base, wall);
let actions = state.handle(base + Duration::from_secs(300), CoordinatorEvent::Timer);
assert!(actions.iter().any(|value| matches!(value, CoordinatorAction::StartToken(_))));
assert!(actions.iter().any(|value| matches!(value, CoordinatorAction::StartLive(_))));
assert_eq!(state.token_next_deadline(), base + Duration::from_secs(600));
assert_eq!(state.live_next_deadline(), base + Duration::from_secs(600));
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::schedule::tests
```

Expected: compilation fails because the refresh module does not exist.

- [ ] **Step 3: Implement the public scheduling contracts**

Add to `refresh/mod.rs`:

```rust
pub(crate) const LIVE_QUERY_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RefreshLane { Token, Live }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RefreshReason { Startup, Scheduled, Manual, SettingsChanged, Wake, Fallback }

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum TokenScanKind { Incremental, Full }

#[derive(Clone, Debug)]
pub(crate) struct RefreshConfig {
  pub auto_scan_enabled: bool,
  pub interval: Duration,
  pub codex_home: Option<String>,
  pub token_last_success_wall: Option<DateTime<Utc>>,
  pub live_last_success_wall: Option<DateTime<Utc>>,
}
```

Keep `CoordinatorState` pure and pass `Instant` to `handle`. Advance from the planned deadline:

```rust
fn advance_fixed_deadline(mut deadline: Instant, interval: Duration, now: Instant) -> (Instant, u64) {
  let mut elapsed_intervals = 0;
  while deadline <= now {
    deadline += interval;
    elapsed_intervals += 1;
  }
  (deadline, elapsed_intervals.saturating_sub(1))
}

fn initial_deadline(
  monotonic_now: Instant,
  wall_now: DateTime<Utc>,
  last_success: Option<DateTime<Utc>>,
  interval: Duration,
) -> Instant {
  let Some(age) = last_success.and_then(|value| wall_now.signed_duration_since(value).to_std().ok()) else {
    return monotonic_now;
  };
  monotonic_now + interval.saturating_sub(age)
}
```

The settings adapter maps a malformed persisted timestamp to `None`. Missing, malformed, future, and overdue values produce one startup intent; once that generation is recorded as running they cannot enqueue a duplicate catch-up.

- [ ] **Step 4: Run the focused tests**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::schedule::tests`.

Expected: all Task 1 tests pass without real sleeps.

- [ ] **Step 5: Commit the scheduler model**

```bash
git add src-tauri/src/refresh src-tauri/src/lib.rs
git commit -m "feat: add deterministic refresh lane scheduler"
```

### Task 2: Coalesce overlap, back off independently, and guard source generations

**Files:**
- Modify: `src-tauri/src/refresh/mod.rs`
- Modify: `src-tauri/src/refresh/schedule.rs`
- Test: `src-tauri/src/refresh/schedule.rs`

**Interfaces:**
- Consumes: Task 1 lane state.
- Produces: reason sets, generation-tagged execution requests, waiter IDs, retry deadlines, and `DisplayInvalidation`.

- [ ] **Step 1: Write failing overlap and retry tests**

Add `triggers_during_run_create_one_follow_up_generation`, `multiple_triggers_merge_reason_bits`, `manual_live_waiter_joins_running_generation`, `failed_lanes_back_off_independently`, `source_change_rejects_old_completion`, and `source_change_discards_prepared_token_before_commit`.

```rust
let first = start_token_generation(&mut state, base);
state.handle(base + Duration::from_secs(1), CoordinatorEvent::RequestToken(TokenRequest::scheduled()));
state.handle(base + Duration::from_secs(2), CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)));
let actions = state.handle(base + Duration::from_secs(3), CoordinatorEvent::TokenFinished(success(first)));
assert_eq!(actions.iter().filter(|value| matches!(value, CoordinatorAction::StartToken(_))).count(), 1);
assert!(matches!(actions.last(), Some(CoordinatorAction::StartToken(request)) if request.kind == TokenScanKind::Full));
```

- [ ] **Step 2: Run tests and verify behavioral failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::schedule::tests`.

Expected: new assertions fail because pending and retry state are absent.

- [ ] **Step 3: Implement merge and retry rules**

Use a dependency-free reason set and bounded delay:

```rust
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct ReasonSet(u8);

impl ReasonSet {
  pub fn insert(&mut self, reason: RefreshReason) { self.0 |= 1 << reason as u8; }
  pub fn is_empty(self) -> bool { self.0 == 0 }
}

fn retry_delay(failure_streak: u32, interval: Duration, jitter: Duration) -> Duration {
  const STEPS: [u64; 6] = [5, 15, 30, 60, 120, 300];
  let index = failure_streak.saturating_sub(1) as usize;
  Duration::from_secs(STEPS[index.min(STEPS.len() - 1)])
    .saturating_add(jitter)
    .min(interval)
    .min(Duration::from_secs(300))
}
```

Production jitter is capped at one second; tests pass zero. Keep normal deadlines unchanged by retries. Before a prepared token refresh enters the mutation queue, recheck its source generation; discard it without database writes when the source changed. Increment revisions only when both worker generation and source generation match.

Use these generation and event contracts throughout all three slices:

```rust
#[derive(Clone, Debug)]
pub(crate) struct TokenRequest {
  pub reasons: ReasonSet,
  pub kind: TokenScanKind,
  pub codex_home: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct TokenExecutionRequest {
  pub generation: u64,
  pub source_generation: u64,
  pub request: TokenRequest,
}

#[derive(Clone, Debug)]
pub(crate) struct LiveExecutionRequest {
  pub generation: u64,
  pub source_generation: u64,
  pub reasons: ReasonSet,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct CommitMarker {
  pub sequence: u64,
  pub committed_at: Instant,
}

#[derive(Clone, Debug)]
pub(crate) struct DisplayInvalidation {
  pub usage_revision: u64,
  pub quota_revision: u64,
  pub settings_revision: u64,
  pub source_generation: u64,
  pub commit: CommitMarker,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshCompletedEvent {
  pub refresh_revision: u64,
  pub lane: RefreshLane,
  pub generation: u64,
  pub usage_revision: u64,
  pub quota_revision: u64,
  pub source_generation: u64,
  pub succeeded: bool,
  pub failure: Option<String>,
  pub completed_at: String,
}
```

- [ ] **Step 4: Run schedule tests**

Run the same focused command. Expected: one follow-up is produced, retry caps hold, and stale completions do not publish.

- [ ] **Step 5: Commit overlap handling**

```bash
git add src-tauri/src/refresh
git commit -m "feat: coalesce refresh triggers and guard source generations"
```

### Task 3: Add the channel runtime and independent workers

**Files:**
- Create: `src-tauri/src/refresh/runtime.rs`
- Create: `src-tauri/src/refresh/power.rs`
- Create: `src-tauri/src/refresh/mutation.rs`
- Modify: `src-tauri/src/refresh/mod.rs`
- Modify: `src-tauri/src/importer.rs`
- Test: `src-tauri/src/refresh/runtime.rs`
- Test: `src-tauri/src/refresh/mutation.rs`

**Interfaces:**
- Consumes: Task 2 coordinator actions.
- Produces: `RefreshCoordinatorHandle`, executor traits, `RefreshStatus`, blocking manual tickets, `RefreshEventSink`, and serialized usage-mutation arbitration.

- [ ] **Step 1: Write channel-gated concurrency tests**

Add `token_worker_does_not_delay_live_worker_start`, `concurrent_live_callers_share_one_executor_generation`, `active_live_children_never_exceeds_one`, `live_timeout_terminates_and_reaps_child`, `startup_status_is_busy_before_worker_body_runs`, `completion_services_one_pending_follow_up`, `worker_panic_becomes_failure`, `disabled_scheduler_runs_manual_requests`, `scheduled_start_lag_is_recorded`, `start_lag_above_five_seconds_warns`, `resume_starts_overdue_lanes_within_five_seconds`, `token_parse_runs_before_usage_commit_lock`, `held_usage_commit_lock_does_not_delay_live_lane`, and `pricing_waits_behind_refresh_mutation`.

- [ ] **Step 2: Run tests and verify compilation failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::runtime::tests -- --nocapture`.

Expected: runtime types are missing.

- [ ] **Step 3: Implement runtime traits and `recv_timeout` loop**

```rust
pub(crate) trait TokenRefreshExecutor: Send + Sync {
  fn parse(&self, request: TokenExecutionRequest) -> Result<PreparedTokenRefresh, String>;
  fn commit(&self, prepared: PreparedTokenRefresh) -> Result<ScanResult, String>;
}

pub(crate) struct PreparedTokenRefresh {
  pub generation: u64,
  pub source_generation: u64,
  pub started_at: DateTime<Utc>,
  pub prepared_scan: PreparedScan,
}

pub(crate) trait LiveQuotaFetcher: Send + Sync {
  fn fetch(&self, timeout: Duration) -> Result<LiveRateLimitSnapshot, String>;
  fn fallback(&self) -> Option<LiveRateLimitSnapshot>;
}

pub(crate) trait LiveQuotaPersister: Send + Sync {
  fn persist(&self, snapshot: &LiveRateLimitSnapshot) -> Result<(), String>;
}

pub(crate) trait RefreshEventSink: Send + Sync {
  fn publish_invalidation(&self, value: DisplayInvalidation);
  fn publish_completion(&self, value: RefreshCompletedEvent);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MutationPhase { Queued, Parsing, WaitingToCommit, Committed, Failed }

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum MutationPriority { Pricing, Maintenance, Refresh }

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LaneStatus {
  pub running: bool,
  pub generation: Option<u64>,
  pub pending: bool,
  pub last_success_at: Option<String>,
  pub next_due_at: Option<String>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshStatus {
  pub token: LaneStatus,
  pub live: LaneStatus,
  pub mutation_phase: Option<MutationPhase>,
  pub source_generation: u64,
}
```

The runtime calls `rx.recv_timeout(state.next_wait(clock.monotonic_now()))`, marks running state before spawn, and launches token and live actions on separate named threads. Catch worker panics and convert them into failure completions.

Refactor the importer entry point into a read-only `prepare_scan` that produces `PreparedTokenRefresh` and a transactional `commit_prepared_scan`. Preparation performs no freshness, repair, title, pricing, or derived-row write; the coordinator owns attempt state until commit. `UsageMutationCoordinator` serializes only the commit closure. Token discovery and JSON parsing run in `Parsing` before requesting the lock; the phase changes to `WaitingToCommit` only around the writer queue. Refresh commits outrank maintenance, which outranks pricing recalculation. Waiting for this queue never holds the coordinator channel or live singleflight, and live publication does not acquire the usage-mutation lock.

Add fixed-bucket histograms and counters rather than retaining per-run samples. `RefreshLaneMetrics` exposes `scheduled_due_at`, `started_at`, `start_lag_ms`, `duration_ms`, `last_success_age_ms`, `failure_streak`, `retry_at`, `missed_deadline_count`, `coalesced_trigger_count`, `running_generation`, and `pending_reasons`. Live metrics add app-server duration, timeout count, active child count, fallback age, and waiter count. Token metrics add files visited, bytes read, append fast-path count, full-rebuild count, mutation-lock wait, and database-busy count. Warn when start lag exceeds five seconds, active live children exceeds one, or success age exceeds the interval plus active retry allowance.

- [ ] **Step 4: Scope macOS activity to actual work**

Move `SchedulerActivity` to `refresh/power.rs`. Use `NSActivityOptions::Background`. Construct the guard immediately before an executor call and drop it immediately afterward. The coordinator wait loop holds no activity guard.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::runtime::tests
git add src-tauri/src/refresh src-tauri/src/importer.rs
git commit -m "feat: coordinate independent refresh workers"
```

### Task 4: Publish truthful live quota before persistence

**Files:**
- Create: `src-tauri/src/refresh/live_cache.rs`
- Modify: `src-tauri/src/refresh/mod.rs`
- Modify: `src-tauri/src/refresh/runtime.rs`
- Modify: `src-tauri/src/models.rs:215-224`
- Modify: `src-tauri/src/lib.rs:1084-1328`
- Test: `src-tauri/src/refresh/live_cache.rs`

**Interfaces:**
- Consumes: Task 3 live fetcher and persister.
- Produces: `LiveQuotaState`, `LiveQuotaCache`, fixed timeout behavior, fallback metadata, and persistence retry actions.

- [ ] **Step 1: Write failing freshness tests**

Add `fallback_never_becomes_fresh_for_ttl`, `fallback_preserves_source_and_last_success`, `fresh_value_is_visible_before_persistence_finishes`, `fetch_receives_ten_second_timeout`, `live_failure_does_not_run_token_inline`, `persistence_failure_retries_without_refetch`, `newer_live_snapshot_supersedes_pending_persistence_retry`, `persistence_retry_is_capped`, and `persistence_retry_does_not_move_live_deadline`.

```rust
let fallback = store.publish_fallback(old_snapshot(), utc("2026-07-10T10:00:00Z"));
assert!(fallback.is_fallback);
assert_eq!(fallback.source_fetched_at.as_deref(), Some("2026-07-09T10:00:00+00:00"));
assert_eq!(fallback.last_live_success_at, None);
assert!(store.needs_live_refresh(Duration::from_secs(300)));
```

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::live_cache::tests`.

Expected: cache state types are missing.

- [ ] **Step 3: Add serialized live state**

```rust
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveQuotaState {
  pub rate_limits: Option<LiveRateLimitSnapshot>,
  pub source_fetched_at: Option<String>,
  pub cached_at: String,
  pub is_fallback: bool,
  pub last_live_success_at: Option<String>,
  pub refreshing: bool,
}

pub(crate) struct LivePersistenceRetryState {
  pub latest_pending: Option<Arc<LiveRateLimitSnapshot>>,
  pub failure_streak: u32,
  pub retry_at: Option<Instant>,
  pub running: bool,
}
```

`publish_live` updates source and success time. `publish_fallback` updates cache time only and remains due for retry.

- [ ] **Step 4: Publish before persistence and remove inline fallback scans**

On live success, update cache, increment quota revision, emit an invalidation carrying a monotonic `CommitMarker`, and emit completion before starting persistence. A persistence failure stores only the latest pending snapshot and schedules `CoordinatorAction::PersistLive` with the same 5/15/30/60/120/300-second sequence, capped by the configured interval and 300 seconds. It never runs the live fetcher, increments the live fetch failure streak, or changes the normal live deadline. Only one persistence action runs; a newer live snapshot replaces an older pending retry, and success clears the independent persistence state. Replace `get_live_rate_limits_history_fallback` synchronous scanning with an asynchronous `RefreshReason::Fallback` token intent.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::live_cache::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::runtime::tests
git add src-tauri/src/refresh src-tauri/src/models.rs src-tauri/src/lib.rs
git commit -m "fix: preserve truthful live quota freshness"
```

### Task 5: Route Tauri lifecycle and settings through the coordinator

**Files:**
- Modify: `src-tauri/src/database/sync_settings.rs:407-500`
- Modify: `src-tauri/src/database.rs:10-18`
- Modify: `src-tauri/src/lib.rs:92-102`
- Modify: `src-tauri/src/lib.rs:166-466`
- Modify: `src-tauri/src/lib.rs:1919-2181`
- Modify: `src-tauri/src/models.rs`
- Test: `src-tauri/src/database/sync_settings.rs`
- Test: `src-tauri/src/lib.rs`

**Interfaces:**
- Consumes: coordinator handle and live cache.
- Produces: one coordinator in `AppState`, passive getters, manual waiters, immediate config updates, and resume forwarding.

- [ ] **Step 1: Write failing integration tests**

Add `settings_save_does_not_overwrite_newer_scan_freshness`, `settings_change_wakes_coordinator_immediately`, `codex_home_change_requests_full_scan`, `passive_live_getter_does_not_start_fetch`, `popup_snapshot_read_does_not_start_scan`, `manual_scan_uses_coordinator_generation`, and `pricing_recalculation_uses_lower_priority_mutation_ticket`.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked settings_save_does_not_overwrite_newer_scan_freshness
cargo test --manifest-path src-tauri/Cargo.toml --locked passive_live_getter_does_not_start_fetch
```

- [ ] **Step 3: Make settings saves configuration-only**

For an unchanged Codex home, stop updating `last_scan_started_at` and `last_scan_completed_at` in the conflict clause. For a changed home, clear freshness in the same transaction. `updateSyncSettings` sends the normalized config to the coordinator before returning.

- [ ] **Step 4: Replace scheduler and command paths**

Store `refresh: RefreshCoordinatorHandle` and the Task 3 mutation coordinator in `AppState`; remove scan and live atomic flags, the coarse `usage_mutation_lock`, and old spawn functions. `getScanInProgress` derives its compatibility boolean from `RefreshStatus`, while `getRefreshStatus` exposes the exact mutation phase. `getLiveRateLimits` returns cache, and manual commands request waiters. Pricing requests take a lower-priority mutation ticket and never hold the refresh coordinator. Build the app and forward resume:

```rust
let app = builder.build(tauri::generate_context!())
  .expect("error while building tauri application");
app.run(|app_handle, event| {
  if matches!(event, tauri::RunEvent::Resumed) {
    let _ = app_handle.state::<AppState>().refresh.notify_resume();
  }
});
```

Setup queues startup intents and does not call the three old scheduler entry points.

- [ ] **Step 5: Run Rust tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked
git add src-tauri/src/database.rs src-tauri/src/database/sync_settings.rs src-tauri/src/lib.rs src-tauri/src/models.rs
git commit -m "refactor: route refresh commands through coordinator"
```

### Task 6: Replace frontend polling with revision-gated events

**Files:**
- Create: `src/app/refreshEvents.ts`
- Create: `scripts/test-refresh-events.mjs`
- Modify: `src/App.tsx:1-399`
- Modify: `src/menu-bar-popup/MenuBarPopup.tsx:50-149`
- Modify: `src/app/api.ts:202-280`
- Modify: `src/app/dataFreshness.ts:87-116`
- Modify: `src/app/types.ts:82-135`
- Modify: `scripts/test-data-freshness.mjs`
- Modify: `package.json:9-18`

**Interfaces:**
- Consumes: `codex-counter://refresh-completed` and passive getters.
- Produces: `SurfaceRevisionGate`, visible reloads, hidden coalescing, and event-driven manual refresh state.

- [ ] **Step 1: Write the failing Node tests**

```javascript
const gate = new SurfaceRevisionGate()
assert.equal(gate.accept({ refreshRevision: 1, succeeded: true }, true), 'reload')
assert.equal(gate.accept({ refreshRevision: 1, succeeded: true }, true), 'ignore')
assert.equal(gate.accept({ refreshRevision: 2, succeeded: true }, false), 'defer')
assert.equal(gate.accept({ refreshRevision: 3, succeeded: true }, false), 'defer')
assert.equal(gate.onVisible(), 'reload')
assert.equal(gate.onVisible(), 'ignore')
```

The script also asserts that refresh effects in `App.tsx` and `MenuBarPopup.tsx` contain no `setInterval`, `refreshBackgroundData`, or settings-open live polling. Add `failed_completion_does_not_reload_data` and `manual_waiter_failure_clears_refreshing_and_keeps_previous_data`.

- [ ] **Step 2: Register the script and verify failure**

Add `test:refresh-events` to `package.json` and `npm test`, then run `npm run test:refresh-events`.

Expected: module import or source assertions fail.

- [ ] **Step 3: Implement the pure revision gate**

```typescript
export class SurfaceRevisionGate {
  private appliedRevision = 0
  private pendingRevision = 0

  accept(event: RefreshCompletedEvent, visible: boolean): 'reload' | 'defer' | 'ignore' {
    if (!event.succeeded || event.refreshRevision <= Math.max(this.appliedRevision, this.pendingRevision)) return 'ignore'
    if (!visible) {
      this.pendingRevision = event.refreshRevision
      return 'defer'
    }
    this.appliedRevision = event.refreshRevision
    return 'reload'
  }

  onVisible(): 'reload' | 'ignore' {
    if (this.pendingRevision <= this.appliedRevision) return 'ignore'
    this.appliedRevision = this.pendingRevision
    return 'reload'
  }
}
```

- [ ] **Step 4: Wire both surfaces without automatic timers**

As an interim Slice 1 bridge, App listens for successful completion, checks Tauri window visibility, and reloads only for `reload`. Popup removes its interval; showing it performs one passive read. A failed completion never reloads data. Manual commands await their coordinator ticket and clear `refreshing` in `finally`, so failure leaves the prior cards and source timestamp visible. Preserve Escape handling, labels, focus states, and stable height.

This raw-completion data reload is deliberately removed in presentation Task 4. In the final architecture, `refresh-completed` controls spinner/error state only; `display-snapshot-updated` is the sole trigger allowed to apply new data.

- [ ] **Step 5: Run full slice verification and commit**

```bash
npm test
npm run lint
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --locked --lib
git add package.json scripts/test-data-freshness.mjs scripts/test-refresh-events.mjs src/App.tsx src/menu-bar-popup/MenuBarPopup.tsx src/app/api.ts src/app/dataFreshness.ts src/app/refreshEvents.ts src/app/types.ts
git commit -m "perf: replace frontend refresh polling with events"
```

Expected: all tests, lint, build, and Rust tests pass. Clippy exits successfully; compare its output with the recorded 16-warning repository baseline and fix every new warning in changed files. Frontend sources have no automatic refresh timer.

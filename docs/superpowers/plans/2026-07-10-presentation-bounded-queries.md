# Presentation and bounded queries implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tray and popup reads bounded, move all tray computation off the UI thread, reduce database row materialization, split the popup bundle, and cap dashboard caches.

**Architecture:** Indexed epoch fields and compact latest-quota storage feed a versioned `DisplaySnapshotStore`. A background snapshot service consumes Slice 1 invalidations and publishes immutable presentation revisions. Tray setters receive precomputed diffs, while the popup and dashboard consume revisioned snapshots without polling.

**Tech Stack:** Rust 2021, Tauri 2.10, Rusqlite 0.37 with bundled SQLite, React 19 for the dashboard, plain TypeScript DOM for the lightweight popup, Vite 8, Node 22.18 test scripts.

## Global constraints

- Prerequisite: complete and verify the refresh-correctness plan first. This slice consumes its coordinator invalidations and completion events.
- Snapshot getters perform no source I/O and remain below 5 ms p95.
- Tray main-thread apply remains below 2 ms p95 and contains no database, file, process, or formatting work.
- Token or quota commit reaches the visible tray within 100 ms p95 and the visible popup within 150 ms p95.
- Popup payload is at most 64 KB. Popup JavaScript is at most 150 KB minified and 50 KB gzip and contains no dashboard, Recharts, React, or ReactDOM dependency.
- The popup is created on first tray use. Hidden popup and dashboard surfaces execute zero data queries during a 10-minute observation.
- Existing popup structure, colors, keyboard Escape behavior, visible focus, accessible labels, stable loading layout, and reduced-motion behavior remain intact.
- Conversation detail cache is limited to 20 entries and 32 MB. Default detail response includes the newest 40 turns.
- Existing mixed-offset timestamp and live-window correctness tests remain passing.

---

### Task 1: Add indexed epoch fields and bounded backfill

**Files:**
- Modify: `src-tauri/sql/schema.sql:29-42`
- Modify: `src-tauri/sql/schema.sql:126-140`
- Modify: `src-tauri/sql/indexes.sql`
- Create: `src-tauri/src/database/epoch_backfill.rs`
- Create: `src-tauri/src/database/usage_events.rs`
- Modify: `src-tauri/src/database.rs:1-55`
- Modify: `src-tauri/src/importer.rs:1469-1490`
- Modify: `src-tauri/src/refresh/runtime.rs`
- Test: `src-tauri/src/database/epoch_backfill.rs`
- Test: `src-tauri/src/database/usage_events.rs`
- Test: `src-tauri/src/refresh/runtime.rs`

**Interfaces:**
- Consumes: RFC3339 timestamps already stored by the importer.
- Produces: `timestamp_ms`, quota epoch columns, partial compatibility indexes, `parse_epoch_millis`, `insert_usage_events`, bounded backfill progress, and resumable maintenance dispatch.

- [ ] **Step 1: Write failing schema, parser, and batch tests**

Add `init_db_adds_epoch_columns_without_scanning_history`, `epoch_parser_orders_mixed_offsets_by_instant`, `new_usage_event_writes_timestamp_ms`, `backfill_updates_at_most_requested_batch_size`, `compatibility_query_includes_null_epoch_rows`, `integrity_check_is_ok_after_epoch_migration`, `epoch_backfill_runs_one_batch_per_maintenance_dispatch`, `epoch_backfill_resumes_from_null_rows_after_restart`, and `snapshot_getter_remains_available_while_epoch_backfill_waits`.

```rust
assert!(parse_epoch_millis("2026-07-10T10:00:00+08:00").unwrap()
  < parse_epoch_millis("2026-07-10T03:00:01Z").unwrap());
let progress = backfill_epoch_batch(&conn, 1_000).unwrap();
assert!(progress.usage_rows_updated + progress.quota_rows_updated <= 1_000);
```

- [ ] **Step 2: Run tests and verify failure**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked database::epoch_backfill::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked database::usage_events::tests
```

Expected: schema columns and modules are missing.

- [ ] **Step 3: Add nullable migration fields and partial indexes**

New installs include:

```sql
timestamp_ms INTEGER
sample_timestamp_ms INTEGER
window_start_ms INTEGER
resets_at_ms INTEGER
```

Existing installs use `ensure_epoch_schema` with `ALTER TABLE` only. Add:

```sql
CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp_ms
  ON usage_events(timestamp_ms, id) WHERE timestamp_ms IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_usage_events_missing_epoch
  ON usage_events(id) WHERE timestamp_ms IS NULL;
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_window_ms
  ON rate_limit_samples(bucket, window_start_ms, resets_at_ms, sample_timestamp_ms, id)
  WHERE window_start_ms IS NOT NULL AND resets_at_ms IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_missing_epoch
  ON rate_limit_samples(id) WHERE sample_timestamp_ms IS NULL;
```

- [ ] **Step 4: Implement bounded write and backfill helpers**

Use:

```rust
pub struct EpochBackfillProgress {
  pub usage_rows_updated: usize,
  pub quota_rows_updated: usize,
  pub complete: bool,
}

pub fn parse_epoch_millis(value: &str) -> Result<i64, String> {
  DateTime::parse_from_rfc3339(value)
    .map(|value| value.timestamp_millis())
    .map_err(|error| error.to_string())
}

pub fn backfill_epoch_batch(conn: &Connection, batch_size: usize) -> rusqlite::Result<EpochBackfillProgress>;
```

Each batch reads at most 1,000 NULL rows by ID and commits once. The remaining NULL rows are the durable progress marker; write the corresponding `data_repairs` completion row only when none remain. Change `persist_session` to call `insert_usage_events`, which always binds `timestamp_ms` for new rows.

Register `EpochBackfill` as a low-priority `BackgroundMaintenance` intent with the Slice 1 coordinator. Startup checks the repair marker without scanning source data. A maintenance worker runs exactly one batch, yields through the coordinator event channel, and queues another only when both refresh lanes are idle and the next deadline is more than 30 seconds away. NULL rows are the restart cursor, so termination between batches resumes safely. Foreground snapshot reads continue to use the compatibility branch and never wait for migration completion.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked database::epoch_backfill::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked database::usage_events::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked epoch_backfill_runs_one_batch_per_maintenance_dispatch
git add src-tauri/sql src-tauri/src/database.rs src-tauri/src/database/epoch_backfill.rs src-tauri/src/database/usage_events.rs src-tauri/src/importer.rs src-tauri/src/refresh/runtime.rs
git commit -m "perf: add indexed epoch timestamps and bounded backfill"
```

### Task 2: Store latest quota separately and compact new history

**Files:**
- Modify: `src-tauri/sql/schema.sql`
- Modify: `src-tauri/sql/indexes.sql`
- Modify: `src-tauri/src/database/rate_limit_samples.rs`
- Modify: `src-tauri/src/database.rs:8-18`
- Modify: `src-tauri/src/lib.rs:1152-1285`
- Modify: `src-tauri/src/models.rs:170-224`
- Test: `src-tauri/src/database/rate_limit_samples.rs`

**Interfaces:**
- Consumes: Task 1 epoch parser and current rate-limit records.
- Produces: `latest_rate_limits`, `RateLimitWriteStats`, exact fallback lookup, and shared append/replace writers for Slice 3.

- [ ] **Step 1: Write failing latest and change-point tests**

Add `repeated_live_percent_updates_latest_without_growing_history`, `changed_percent_adds_one_history_point`, `new_window_keeps_previous_close_and_new_start`, `session_batch_keeps_first_change_and_last`, `latest_quota_uses_epoch_order`, and `latest_lookup_does_not_scan_history`.

```rust
let first = insert_live_rate_limit_snapshot(&conn, &live_snapshot(40, "2026-07-10T10:00:00Z")).unwrap();
let repeated = insert_live_rate_limit_snapshot(&conn, &live_snapshot(40, "2026-07-10T10:05:00Z")).unwrap();
assert_eq!(first.historical_inserted, 2);
assert_eq!(repeated.historical_inserted, 0);
assert_eq!(repeated.latest_updated, 2);
```

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked database::rate_limit_samples::tests`.

Expected: latest table and write statistics are missing.

- [ ] **Step 3: Add latest table and common write contracts**

Create a two-row-per-source table keyed by `(source_kind, bucket)` with snapshot timestamp, epoch fields, limit metadata, window bounds, and percent fields. Define:

```rust
pub struct RateLimitWriteStats {
  pub observed: usize,
  pub historical_inserted: usize,
  pub latest_updated: usize,
}

pub fn append_session_rate_limit_samples(
  conn: &Connection,
  session_id: &str,
  samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<RateLimitWriteStats>;

pub fn replace_session_rate_limit_samples(
  conn: &Connection,
  session_id: &str,
  samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<RateLimitWriteStats>;
```

- [ ] **Step 4: Implement step-change writes and fallback reads**

Within one transaction, upsert latest first. Insert historical data for a window start, a percent change, and the previous window close. Repeated equal values only update latest. `load_latest_rate_limits` orders by integer epoch and combines primary and secondary only when they share a snapshot timestamp; it never runs `ORDER BY julianday(...)` over history.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked database::rate_limit_samples::tests
git add src-tauri/sql src-tauri/src/database.rs src-tauri/src/database/rate_limit_samples.rs src-tauri/src/lib.rs src-tauri/src/models.rs
git commit -m "perf: store latest quota and compact new history"
```

### Task 3: Replace full-table presentation reads with bounded window queries

**Files:**
- Create: `src-tauri/src/queries/presentation.rs`
- Create: `src-tauri/sql/queries/usage_events_window.sql`
- Create: `src-tauri/sql/queries/conversation_page.sql`
- Create: `src-tauri/sql/queries/presentation_usage_summary.sql`
- Modify: `src-tauri/sql/queries/quota_samples.sql`
- Modify: `src-tauri/sql/queries/rate_limit_windows.sql`
- Modify: `src-tauri/src/queries.rs:32-257`
- Modify: `src-tauri/src/queries.rs:1153-1207`
- Modify: `src-tauri/src/queries.rs:1324-1669`
- Test: `src-tauri/src/queries/presentation.rs`

**Interfaces:**
- Consumes: Task 1 time indexes, Task 2 quota storage, and existing `ResolvedWindow` rules.
- Produces: window summary, one-pass trend accumulation, exact quota-window reads, and bounded conversation pages.

- [ ] **Step 1: Write failing query-plan and row-visit tests**

Add `presentation_summary_filters_before_materialization`, `quota_query_selects_exact_window`, `quota_plan_uses_window_index`, `usage_plan_uses_timestamp_index`, `window_accumulator_visits_selected_rows_only`, `total_overview_streams_without_event_vector`, `mixed_offset_compatibility_matches_backfill`, and `compatibility_millisecond_boundaries_match_epoch_branch`.

- [ ] **Step 2: Run tests and verify current amplification**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked queries::presentation::tests -- --nocapture`.

Expected: new tests fail; the fixture observes full event and bucket row counts.

- [ ] **Step 3: Add bounded summary and window-event SQL**

```rust
pub struct WindowUsageSummary {
  pub api_value_usd: f64,
  pub total_tokens: i64,
  pub conversation_count: usize,
}

pub fn load_window_usage_summary(
  conn: &Connection,
  window: &ResolvedWindow,
) -> rusqlite::Result<WindowUsageSummary>;
```

The SQL uses `SUM` and `COUNT(DISTINCT sessions.root_session_id)` with `timestamp_ms >= start` and `< end`. While backfill is incomplete, a UNION branch reads only the partial NULL-epoch index and compares `unixepoch(timestamp) * 1000` with the same millisecond bounds. Add exact start-inclusive/end-exclusive boundary assertions so the compatibility and epoch branches cannot diverge by units. `total` uses aggregate `MIN/MAX` instead of loading events.

Change the existing `ResolvedWindow` visibility to `pub(super)` so `queries::presentation` can reuse the single canonical local-time and live-window resolver instead of duplicating its rules.

- [ ] **Step 4: Make trend and quota accumulation one pass**

Stream selected rows ordered by epoch and advance a bin cursor once per event. Change quota SQL to bind `(bucket, window_start_ms, resets_at_ms)`. Limit historical live windows to 512. Preserve current local-time labels and live-window correctness tests.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked queries::presentation::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked menu_bar_api_value_uses_selected_live_window
git add src-tauri/sql/queries src-tauri/src/queries.rs src-tauri/src/queries
git commit -m "perf: bound presentation and dashboard window reads"
```

### Task 4: Publish versioned display snapshots

**Files:**
- Create: `src-tauri/src/presentation.rs`
- Create: `src-tauri/src/presentation/snapshot.rs`
- Modify: `src-tauri/src/models.rs`
- Modify: `src-tauri/src/lib.rs:1-102`
- Modify: `src-tauri/src/lib.rs:268-275`
- Modify: `src-tauri/src/lib.rs:1341-1418`
- Modify: `src-tauri/src/refresh/live_cache.rs`
- Modify: `src/App.tsx`
- Modify: `src/menu-bar-popup/MenuBarPopup.tsx`
- Modify: `src/app/refreshEvents.ts`
- Modify: `src/app/types.ts`
- Modify: `src/app/api.ts`
- Test: `src-tauri/src/presentation/snapshot.rs`

**Interfaces:**
- Consumes: Slice 1 `DisplayInvalidation`, `LiveQuotaCache`, and Task 3 bounded queries.
- Produces: `DisplaySnapshotStore`, `DisplaySnapshotService`, `DisplaySnapshotEvent`, and passive memory getters.

- [ ] **Step 1: Write failing revision and getter tests**

Add `snapshot_getter_performs_no_source_io`, `builder_discards_stale_source_revisions`, `revision_during_build_queues_one_rebuild`, `presentation_revision_increases_after_publish`, `fresh_live_cache_overlays_unpersisted_quota`, `blocked_live_persistence_does_not_delay_snapshot_or_tray`, `raw_refresh_completion_does_not_reload_surface_data`, `failed_completion_clears_refreshing_without_replacing_data`, and `popup_payload_is_at_most_65536_bytes`.

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked presentation::snapshot::tests`.

- [ ] **Step 3: Add exact snapshot types**

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DisplaySourceRevisions {
  pub usage_revision: u64,
  pub quota_revision: u64,
  pub settings_revision: u64,
  pub source_generation: u64,
}

pub struct DisplaySnapshot {
  pub source_revisions: DisplaySourceRevisions,
  pub source_commit: CommitMarker,
  pub presentation_revision: u64,
  pub popup: MenuBarPopupSnapshot,
  pub tray: TraySnapshotInput,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplaySnapshotEvent {
  pub presentation_revision: u64,
  pub popup: MenuBarPopupSnapshot,
}

impl DisplaySnapshotStore {
  pub fn current(&self) -> Arc<DisplaySnapshot>;
  pub fn current_event(&self) -> DisplaySnapshotEvent;
}

impl DisplaySnapshotBuilder {
  pub fn build(
    &self,
    conn: &Connection,
    live: &LiveQuotaState,
    revisions: &DisplaySourceRevisions,
    source_commit: CommitMarker,
  ) -> Result<DisplaySnapshot, String>;
}
```

`DisplaySnapshotBuilder::build` receives a cloned `LiveQuotaState`, source revisions, and the latest `CommitMarker` alongside the database connection. It overlays the in-memory live primary/secondary values and a terminal trend point on bounded historical SQL results. The resulting snapshot carries the monotonic marker for the newest represented token/quota commit, and the builder never waits for live-history persistence.

- [ ] **Step 4: Implement latest-wins rebuild and passive commands**

Publish an empty revision-zero snapshot at startup. Capture source revisions before build; discard a result if they change and queue one latest rebuild. Replace `getMenuBarPopupSnapshot(force_refresh)` with a memory clone that has no force parameter. Manual refresh uses the Slice 1 coordinator. Emit `codex-counter://display-snapshot-updated` only after a consistent snapshot is published.

Replace the interim Slice 1 data gate on both surfaces: `codex-counter://refresh-completed` may only settle the matching manual spinner or error state, while `codex-counter://display-snapshot-updated` is the sole event that may apply data. Accept only a strictly higher `presentationRevision`; hidden surfaces retain only the highest pending revision. Remove the raw-refresh reload path and test its absence in source.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked presentation::snapshot::tests
git add src-tauri/src/presentation.rs src-tauri/src/presentation src-tauri/src/models.rs src-tauri/src/lib.rs src-tauri/src/refresh/live_cache.rs src/App.tsx src/menu-bar-popup/MenuBarPopup.tsx src/app/api.ts src/app/refreshEvents.ts src/app/types.ts
git commit -m "feat: publish versioned bounded display snapshots"
```

### Task 5: Move tray computation off the main thread

**Files:**
- Create: `src-tauri/src/presentation/tray.rs`
- Modify: `src-tauri/src/lib.rs:610-673`
- Modify: `src-tauri/src/lib.rs:1847-1908`
- Modify: `src-tauri/src/lib.rs:2132-2158`
- Test: `src-tauri/src/presentation/tray.rs`

**Interfaces:**
- Consumes: Task 4 immutable display snapshots.
- Produces: `TrayPresentation`, `TrayPresentationDiff`, and latest-wins `TrayPresenter`.

- [ ] **Step 1: Write failing diff and ordering tests**

Add `unchanged_snapshot_calls_no_setters`, `diff_contains_changed_fields_only`, `newer_revision_during_apply_runs_one_follow_up`, `older_revision_cannot_replace_newer`, and `main_thread_receives_precomputed_values`.

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked presentation::tray::tests`.

- [ ] **Step 3: Implement presentation values and diffs**

```rust
pub struct TrayPresentation {
  pub title: Option<String>,
  pub tooltip: Option<String>,
  pub show_logo: bool,
  pub visible: bool,
}

pub fn diff_tray_presentation(
  previous: Option<&TrayPresentation>,
  next: &TrayPresentation,
) -> TrayPresentationDiff;
```

Compute strings, settings, live values, and icon choice on the worker. The main-thread closure captures only the tray handle and diff, then calls the necessary setters.

- [ ] **Step 4: Replace the dropped-refresh flag**

Store `rendering_revision` and `pending_revision`. A busy presenter records the highest pending revision. Completion applies at most one follow-up using the newest snapshot. Remove `menu_bar_refresh_in_progress` and all database access from the main-thread closure.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked presentation::tray::tests
git add src-tauri/src/presentation/tray.rs src-tauri/src/lib.rs
git commit -m "perf: move tray rendering off the UI thread"
```

### Task 6: Lazy-load a lightweight popup without layout shifts

**Files:**
- Create: `src/app/bootstrap.tsx`
- Create: `src/menu-bar-popup/bootstrap.ts`
- Create: `src/menu-bar-popup/render.ts`
- Create: `src/menu-bar-popup/sevenDayChart.ts`
- Create: `src/menu-bar-popup/icons.ts`
- Delete: `src/menu-bar-popup/MenuBarPopup.tsx`
- Modify: `src/main.tsx`
- Modify: `src/styles.css:1-33`
- Modify: `src-tauri/src/lib.rs:1505-1560`
- Modify: `src-tauri/src/lib.rs:2150-2152`
- Create: `scripts/test-presentation.mjs`
- Create: `scripts/check-popup-bundle.mjs`
- Modify: `vite.config.ts`
- Modify: `package.json`

**Interfaces:**
- Consumes: Task 4 display snapshot events and passive getter.
- Produces: dynamic surface entry points, a plain DOM popup renderer, and enforced bundle budgets.

- [ ] **Step 1: Write failing behavior and bundle-source tests**

Test `popup_accepts_higher_revision_only`, `manual_refresh_keeps_snapshot_visible`, `hidden_popup_performs_no_getter`, `popup_has_no_set_interval`, `main_has_no_static_surface_import`, and `popup_keeps_escape_and_accessible_labels`.

- [ ] **Step 2: Register tests and verify failure**

Add `test:presentation` and run `npm run test:presentation`.

Expected: static imports, React popup, and polling assertions fail.

- [ ] **Step 3: Split entry points and preserve UI semantics**

`main.tsx` imports shared CSS, detects the surface, then dynamically imports `app/bootstrap.tsx` or `menu-bar-popup/bootstrap.ts`. The popup uses DOM elements with the existing CSS class names. Inline Lucide-compatible SVG paths provide dashboard and refresh icons. Buttons retain `aria-label`, keyboard focus, Escape handling, and click feedback. Existing content remains mounted while `refreshing` changes.

Replace the remote Google font import with platform UI and monospace fallback stacks to avoid network work and font layout shift. Keep current font weights and element dimensions. Respect the existing reduced-motion media rule for the refresh icon.

- [ ] **Step 4: Create popup on first tray click and enforce the bundle**

Remove popup creation from setup. `toggle_menu_bar_popup` creates it only when absent and reads enablement from the current display snapshot instead of SQLite. Configure Vite manifest output. `check-popup-bundle.mjs` follows the popup chunk imports, rejects React, ReactDOM, Recharts, and dashboard modules, then checks 150 KB minified and 50 KB gzip limits.

- [ ] **Step 5: Run tests, build, and commit**

```bash
npm run test:presentation
npm run build
node scripts/check-popup-bundle.mjs
git add package.json scripts/check-popup-bundle.mjs scripts/test-presentation.mjs src/main.tsx src/app/bootstrap.tsx src/menu-bar-popup src/styles.css src-tauri/src/lib.rs vite.config.ts
git commit -m "perf: lazy load an event-driven popup surface"
```

### Task 7: Bound conversation pages, turns, search, and detail cache

**Files:**
- Modify: `src-tauri/sql/schema.sql`
- Modify: `src-tauri/sql/indexes.sql`
- Create: `src-tauri/sql/queries/conversation_detail_summary.sql`
- Create: `src-tauri/sql/queries/conversation_detail_breakdowns.sql`
- Create: `src-tauri/sql/queries/conversation_turn_page.sql`
- Create: `src-tauri/src/database/conversation_turns.rs`
- Create: `src-tauri/src/queries/pagination.rs`
- Modify: `src-tauri/src/database.rs`
- Modify: `src-tauri/src/importer.rs`
- Modify: `src-tauri/src/refresh/runtime.rs`
- Modify: `src-tauri/src/models.rs:159-168`
- Modify: `src-tauri/src/models.rs:321-417`
- Modify: `src-tauri/src/queries.rs:195-257`
- Modify: `src-tauri/src/queries.rs:483-655`
- Modify: `src-tauri/src/lib.rs:248-349`
- Create: `src/app/sizedLru.ts`
- Create: `src/app/requestGeneration.ts`
- Create: `src/app/surfaceRevision.ts`
- Modify: `src/app/types.ts`
- Modify: `src/app/api.ts`
- Modify: `src/App.tsx:99-399`
- Modify: `scripts/test-data-freshness.mjs`

**Interfaces:**
- Consumes: Task 3 bounded query primitives and Task 4 revisions.
- Produces: indexed durable turn rows, resumable turn-index repair, `ConversationPage`, turn cursor pages, 250 ms search debounce, stale-response rejection, and a dual-limit LRU.

- [ ] **Step 1: Write failing Rust and Node tests**

Add `conversation_page_clamps_limit_to_100`, `pages_do_not_duplicate_items`, `detail_query_plan_uses_turn_cursor_index`, `detail_reads_at_most_41_turn_rows_for_newest_40`, `turn_cursor_returns_strictly_older_turns`, `legacy_turn_index_repair_runs_one_bounded_batch`, `foreground_detail_never_parses_source_jsonl`, `browsing_one_thousand_details_keeps_at_most_20_entries`, `browsing_one_thousand_details_never_exceeds_32mb`, `oversized_detail_is_not_cached`, `search_debounces_250ms`, `superseded_search_response_is_ignored`, and `superseded_detail_response_is_ignored`.

- [ ] **Step 2: Run tests and verify failure**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked queries::pagination::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked conversation_turns
npm run test:data-freshness
```

- [ ] **Step 3: Add exact page and cursor contracts**

```rust
pub struct ConversationPage {
  pub items: Vec<ConversationListItem>,
  pub offset: u32,
  pub next_offset: Option<u32>,
  pub total_count: u64,
}

pub struct ConversationTurnCursor {
  pub last_activity_at_ms: i64,
  pub session_id: String,
  pub turn_id: String,
}

pub struct ConversationTurnPage {
  pub items: Vec<ConversationTurnPoint>,
  pub next_cursor: Option<ConversationTurnCursor>,
}
```

Default conversation-list page size is 50 and maximum is 100. Add `conversation_turns` keyed by `(session_id, turn_id)`, with explicit turn/message/token columns, `root_session_id`, and `last_activity_at_ms`. Index `(root_session_id, last_activity_at_ms DESC, session_id DESC, turn_id DESC)`. The first page runs `ORDER BY` on that tuple with `LIMIT 41`, returns 40, and uses the extra row only to determine `next_cursor`; older pages add a strict tuple cursor predicate. Detail totals, per-session values, model breakdown, and composition breakdown use SQL aggregate/group queries over indexed session joins rather than an event `Vec`. The foreground path never calls `build_turns_for_session` or opens a source JSONL file.

Full and incremental imports transactionally replace or upsert derived turn rows. Add nullable `import_state.turn_index_version`; legacy rows remain queryable but report turns pending until a low-priority coordinator repair parses at most eight files or 8 MB per dispatch, then yields. The repair uses the same refresh-deadline guard as epoch backfill, persists progress per session, and emits an invalidation after each committed batch. Foreground detail commands never perform this repair.

- [ ] **Step 4: Add the dual-limit cache and visibility gate**

```typescript
const detailCache = new SizedLruCache<string, ConversationDetail>({
  maxEntries: 20,
  maxBytes: 32 * 1024 * 1024,
  sizeOf: estimateConversationDetailBytes,
})
```

Reject one entry larger than 32 MB. Use explicit 250 ms debounce rather than `useDeferredValue` as a network debounce. Hidden surfaces record the highest revision and reload once when shown.

`estimateConversationDetailBytes` walks retained strings and arrays once using their encoded/string storage lengths; it must not call `JSON.stringify`, clone the detail, or retain a second serialized copy merely to measure cache size.

Use a monotonically increasing `RequestGeneration` for conversation search, pagination, and selected-detail requests. Starting a newer request invalidates older in-flight responses; where Tauri invoke cannot be cancelled, completion checks `isCurrent(generation)` before changing rows, selection, cache, error, or loading state.

```typescript
export class RequestGeneration {
  private current = 0
  begin(): number { return ++this.current }
  isCurrent(generation: number): boolean { return generation === this.current }
  invalidate(): void { this.current += 1 }
}
```

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked queries::pagination::tests
cargo test --manifest-path src-tauri/Cargo.toml --locked conversation_turns
npm run test:data-freshness
npm run test:presentation
git add src-tauri/sql src-tauri/src/database.rs src-tauri/src/database/conversation_turns.rs src-tauri/src/importer.rs src-tauri/src/refresh/runtime.rs src-tauri/src/queries/pagination.rs src-tauri/src/queries.rs src-tauri/src/models.rs src-tauri/src/lib.rs src/app/sizedLru.ts src/app/requestGeneration.ts src/app/surfaceRevision.ts src/app/types.ts src/app/api.ts src/App.tsx scripts/test-data-freshness.mjs
git commit -m "perf: bound conversation pages and detail cache"
```

### Task 8: Enforce presentation performance budgets

**Files:**
- Create: `.github/workflows/release-build.yml`
- Create: `scripts/check-hidden-surface-activity.mjs`
- Create: `scripts/perf/assert-runtime-budgets.mjs`
- Create: `scripts/perf/measure-macos-runtime.sh`
- Create: `scripts/perf/parse-xctrace-wakeups.mjs`
- Create: `src-tauri/src/presentation/metrics.rs`
- Modify: `scripts/check-popup-bundle.mjs`
- Modify: `package.json`
- Modify: `src-tauri/src/database.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src-tauri/src/presentation.rs`
- Modify: `src-tauri/src/presentation/snapshot.rs`
- Modify: `src-tauri/src/presentation/tray.rs`
- Modify: `src/menu-bar-popup/bootstrap.ts`
- Test: changed Rust presentation modules and Node scripts.

**Interfaces:**
- Consumes: metrics exposed by snapshot, tray, and query test probes.
- Produces: repeatable CI budget checks and a local hidden-window probe.

- [ ] **Step 1: Add failing threshold assertions**

The scripts must reject payloads above 65,536 bytes, popup bundles above either size limit, any hidden data getter call, and any detail cache above either cap. Rust tests assert snapshot getter p95 below 5 ms on the 200,000-usage/400,000-quota fixture, tray main-thread apply p95 below 2 ms with no I/O, that the main-thread backend receives precomputed values only, and `PRAGMA integrity_check` returns exactly `ok` after all migrations, backfills, and cleanup fixtures.

The macOS probe enforces every awake-process runtime budget from the approved design: scheduled start lag p95 at most 2 seconds and maximum 5 seconds, resume catch-up at most 5 seconds, active app-server children at most one, live timeout at most 10 seconds, commit-to-tray p95 at most 100 ms, commit-to-popup p95 at most 150 ms, refresh-related main-thread tasks p99 below 16 ms, reused popup content p95 below 100 ms, first popup creation p95 below 300 ms, fully hidden CPU average below 0.2 percent and p95 below 0.5 percent, at most two total process wakeups per minute, zero hidden queries for ten minutes, and stable resident memory rather than growth proportional to history.

Do not calculate a percentile from one observation. Deterministic fake-clock tests execute at least 100 scheduled starts. The release-app probe requires at least 30 production-path samples for commit-to-tray, commit-to-popup, reused popup, and cold popup creation, plus at least eight real scheduled starts during the hidden run. `assert-runtime-budgets.mjs` fails on an insufficient sample count before checking percentiles.

- [ ] **Step 2: Run the budget scripts before final wiring**

Run `npm run build && node scripts/check-popup-bundle.mjs && node scripts/check-hidden-surface-activity.mjs`.

Expected: scripts fail until manifest names and probes are wired.

- [ ] **Step 3: Wire deterministic test probes**

Use counters compiled under `cfg(test)` for source row visits, snapshot getter duration, tray apply calls, and hidden getter calls. Production `PerformanceCounters` use atomics plus fixed latency buckets and never retain an accumulating sample vector:

```rust
#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PerformanceSnapshot {
  pub scheduler_wakeups: u64,
  pub scheduled_start_lag_samples: u64,
  pub scheduled_start_lag_p95_ms: f64,
  pub scheduled_start_lag_max_ms: f64,
  pub resume_catch_up_max_ms: f64,
  pub active_live_children_max: u64,
  pub live_query_duration_max_ms: f64,
  pub live_timeout_count: u64,
  pub snapshot_build_p95_ms: f64,
  pub snapshot_getter_p95_ms: f64,
  pub tray_queue_p95_ms: f64,
  pub tray_apply_p95_ms: f64,
  pub main_thread_task_p99_ms: f64,
  pub commit_to_tray_visible_p95_ms: f64,
  pub commit_to_tray_visible_samples: u64,
  pub publish_to_tray_visible_p95_ms: f64,
  pub commit_to_popup_visible_p95_ms: f64,
  pub commit_to_popup_visible_samples: u64,
  pub publish_to_popup_visible_p95_ms: f64,
  pub reused_popup_p95_ms: f64,
  pub reused_popup_samples: u64,
  pub first_popup_p95_ms: f64,
  pub first_popup_samples: u64,
  pub popup_payload_bytes_max: u64,
  pub hidden_query_count: u64,
}
```

Keep both source-commit and snapshot-publish timestamps for at most the newest 32 presentation revisions. `DisplayInvalidation` passes the monotonic source commit through the builder into `DisplaySnapshot`; coalesced rebuilds retain the newest represented commit. After a visible surface applies a revision, it sends one revision acknowledgment. The acceptance histogram measures source commit-to-visible, which includes snapshot build and event delivery; publish-to-visible remains a separate diagnostic. The backend then removes both timestamps. Duplicate, hidden, and stale acknowledgments are ignored, so observability cannot grow memory with refresh history.

When `CODEX_PACER_PERF_REPORT_PATH` is present, an opt-in diagnostic reporter writes one final JSON snapshot at shutdown; ordinary launches perform no report-file I/O. Every probe points `CODEX_PACER_DATA_DIR` at a temporary fixture directory, and diagnostic iteration mode refuses to start against the normal application data path.

`measure-macos-runtime.sh` uses separate phases and report files:

1. Launch the release binary, hide both windows, and leave it uninterrupted for 600 seconds. No popup, manual refresh, synthetic revision, or visibility action is allowed. Sample `%CPU` and RSS once per second and measure hidden queries, scheduled starts, and process wakeups. Reject an RSS increase above both 16 MB and five percent between the post-warmup and final windows.
2. Start a fresh fixture process, keep the target surfaces visible, and drive at least 30 revisions through the production commit, snapshot, tray, event, and acknowledgment path for commit-to-visible percentiles.
3. Start a fresh fixture process and recreate the popup at least 30 times for the cold-creation percentile; measure reused cached content separately without contributing to hidden-phase samples.

The script merges the phase reports only after validating their labels and sample counts, then passes them to `assert-runtime-budgets.mjs`. The fake-clock runtime test from Slice 1 enforces the resume allowance without putting the developer machine to sleep.

During the uninterrupted hidden phase only, record the target process with `xcrun xctrace record --template "Power Profiler"`. `parse-xctrace-wakeups.mjs` exports the trace, filters the Codex Pacer PID/coalition, and calculates total application wakeups per minute. The gate fails if the process-level measurement is unavailable; the coordinator's internal `scheduler_wakeups` counter is diagnostic only and cannot substitute for the acceptance measurement.

Add a GitHub Actions matrix for `macos-14` and `windows-latest` that installs Node 22.18 and the declared Rust toolchain, runs `npm ci`, frontend tests/lint/build, Rust tests, and `npm run tauri build`. Runtime CPU thresholds remain a local macOS gate because hosted-runner load is nondeterministic; Windows must complete the release build.

- [ ] **Step 4: Run full slice verification**

```bash
npm test
npm run lint
npm run build
node scripts/check-popup-bundle.mjs
node scripts/check-hidden-surface-activity.mjs
bash scripts/perf/measure-macos-runtime.sh --duration 600
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo test --manifest-path src-tauri/Cargo.toml --locked database_integrity_after_all_migrations
cargo clippy --manifest-path src-tauri/Cargo.toml --locked --lib
```

Expected: all functional tests and budgets pass. Clippy exits successfully; compare its output with the recorded 16-warning repository baseline and fix every new warning in changed files. Whole-repository pre-existing Clippy debt outside changed modules remains separately documented.

- [ ] **Step 5: Commit the performance gates**

```bash
git add .github/workflows/release-build.yml package.json scripts src-tauri/src src/menu-bar-popup/bootstrap.ts
git commit -m "test: enforce presentation resource budgets"
```

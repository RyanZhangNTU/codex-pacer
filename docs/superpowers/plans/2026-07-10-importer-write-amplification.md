# Importer and write amplification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make active JSONL imports append-only in the normal case, preserve a safe full-rebuild fallback, skip unchanged pricing and title writes, and prune redundant quota history in bounded batches.

**Architecture:** `import_state` gains a durable byte checkpoint with source fingerprints and cumulative token state. A typed parser reads complete records after that offset and persists derived rows plus the next checkpoint in one transaction. Identity, repair, topology, or parser changes select the existing full rebuild path. Pricing, title, and history maintenance use semantic no-op checks and bounded transactions.

**Tech Stack:** Rust 2021, Rusqlite 0.37, Serde, Serde JSON, SHA-256 fingerprints, Chrono, existing importer integration fixtures.

## Global constraints

- Prerequisite: complete and verify the refresh-correctness and presentation plans first. In particular, this slice reuses presentation Tasks 1 and 2 for epoch and rate-limit writers.
- Slice 2 owns usage epoch writes, latest quota, and change-point persistence. This plan calls those helpers and does not duplicate their SQL.
- A typical append reads no old JSON payload beyond two fingerprint blocks totaling at most 8 KiB, then reads only bytes after the saved offset.
- Checkpoint and derived data commit in the same SQLite transaction. A failure advances neither.
- Checkpoints stop at the last complete newline. An incomplete tail is reread on the next scan.
- File shrink, replacement, fingerprint mismatch, parser version change, repair, or topology change uses a full rebuild.
- Full fallback produces the same sessions, usage events, quota points, persisted turns, and import state as a clean full import.
- Unchanged pricing, titles, and repeated quota values cause no semantic row rewrite.
- Cleanup performs one bounded transaction per dispatch and never runs `VACUUM` automatically.

---

### Task 1: Add durable append checkpoints and validation

**Files:**
- Modify: `src-tauri/sql/schema.sql:104-111`
- Create: `src-tauri/src/database/import_state.rs`
- Modify: `src-tauri/src/database.rs:1-55`
- Modify: `src-tauri/src/importer.rs:1631-1655`
- Modify: `src-tauri/src/importer.rs:1991-1998`
- Test: `src-tauri/src/database/import_state.rs`

**Interfaces:**
- Consumes: legacy `import_state` rows.
- Produces: `ImportCheckpoint`, `ImportCheckpointState`, validated `ImportState`, schema migration, load, and transactional upsert helpers.

- [ ] **Step 1: Write failing migration and validation tests**

Add `init_db_adds_append_checkpoint_columns_to_legacy_import_state`, `legacy_row_loads_with_missing_checkpoint_state`, `partial_cumulative_checkpoint_loads_as_invalid`, `negative_or_mismatched_offsets_load_as_invalid`, and `valid_checkpoint_round_trips`.

```rust
let state = load_import_state_row(&conn, "/tmp/session.jsonl").unwrap().unwrap();
assert!(matches!(state.checkpoint, ImportCheckpointState::Missing));
conn.execute("UPDATE import_state SET parsed_offset = 20, last_complete_line_offset = 10 WHERE source_path = ?1", [state.source_path]).unwrap();
let state = load_import_state_row(&conn, "/tmp/session.jsonl").unwrap().unwrap();
assert!(matches!(state.checkpoint, ImportCheckpointState::Invalid(_)));
```

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked append_checkpoint -- --nocapture`.

Expected: migration columns and import-state module are missing.

- [ ] **Step 3: Add nullable migration columns**

Add:

```text
parsed_offset
parsed_file_size
prefix_fingerprint
checkpoint_tail_fingerprint
last_complete_line_offset
last_cumulative_input_tokens
last_cumulative_cached_input_tokens
last_cumulative_output_tokens
last_cumulative_reasoning_output_tokens
last_cumulative_total_tokens
last_model_id
parser_schema_version
```

`ensure_import_state_schema` follows the existing `PRAGMA table_info` migration pattern. It never opens or scans source files.

- [ ] **Step 4: Implement exact checkpoint contracts**

```rust
pub const SESSION_PARSER_SCHEMA_VERSION: i64 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportCheckpoint {
  pub parsed_offset: u64,
  pub parsed_file_size: u64,
  pub prefix_fingerprint: String,
  pub checkpoint_tail_fingerprint: String,
  pub last_complete_line_offset: u64,
  pub last_cumulative_usage: Option<TokenUsage>,
  pub last_model_id: Option<String>,
  pub parser_schema_version: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CheckpointValidationError {
  PartialFields,
  NegativeOffset,
  OffsetMismatch,
  OffsetBeyondFile,
  MissingFingerprint,
  UnsupportedVersion,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ImportCheckpointState {
  Missing,
  Valid(ImportCheckpoint),
  Invalid(CheckpointValidationError),
}
```

Five token columns must be all NULL or all present. Require `parsed_offset == last_complete_line_offset`, nonnegative offsets, and `parsed_offset <= parsed_file_size`. SQLite read failures still return `Err`; malformed checkpoint content returns a usable `ImportState` with `Invalid`, allowing the importer to select a safe rebuild rather than aborting the scan.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked append_checkpoint
git add src-tauri/sql/schema.sql src-tauri/src/database.rs src-tauri/src/database/import_state.rs src-tauri/src/importer.rs
git commit -m "feat: add durable session append checkpoints"
```

### Task 2: Parse typed complete records and produce full checkpoints

**Files:**
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/Cargo.lock`
- Create: `src-tauri/src/importer/session_parser.rs`
- Modify: `src-tauri/src/importer.rs:1-20`
- Modify: `src-tauri/src/importer.rs:727-992`
- Modify: `src-tauri/src/database/conversation_turns.rs`
- Test: `src-tauri/src/importer/session_parser.rs`

**Interfaces:**
- Consumes: current JSONL record formats, Slice 2 durable turn contracts, and the typed replay-envelope pattern in `importer.rs:1189-1249`.
- Produces: borrowed record envelopes, complete-line reading, stable fingerprints, `SessionImport::Full`, turn upserts, and parse-byte diagnostics.

- [ ] **Step 1: Write failing parser-equivalence tests**

Add `typed_parser_matches_existing_usage_quota_and_turn_output`, `valid_json_without_terminal_newline_does_not_advance_checkpoint`, `typed_parser_ignores_unrelated_nested_token_fields`, `typed_parser_preserves_user_and_final_assistant_messages`, `invalid_utf8_is_fatal`, and `full_parse_reports_bytes_and_checkpoint`.

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked typed_parser -- --nocapture`.

Expected: typed parser module is absent.

- [ ] **Step 3: Add SHA-256 and exact parser result types**

Add `sha2 = "0.10"` and define:

```rust
pub enum SessionImport {
  Full {
    parsed: ParsedSession,
    checkpoint: ImportCheckpoint,
    parsed_bytes: u64,
  },
  Append {
    parsed: ParsedSessionTail,
    checkpoint: ImportCheckpoint,
    parsed_bytes: u64,
  },
}

#[derive(serde::Deserialize)]
struct SessionRecordEnvelope<'a> {
  #[serde(default)]
  timestamp: Option<&'a str>,
  #[serde(rename = "type", default)]
  record_type: Option<&'a str>,
  #[serde(default, borrow)]
  payload: Option<SessionPayloadEnvelope<'a>>,
}
```

Parse detailed payloads only for the records needed by persisted derivatives: `session_meta`, `turn_context`, `event_msg/token_count`, task start/complete, user messages, agent messages, and final-answer response items. Emit the same `ConversationTurnPoint` values as the existing turn builder. Unknown records remain ignored and unrelated nested token-looking fields never affect totals.

- [ ] **Step 4: Implement complete-line reading and fingerprints**

Use `BufRead::read_until(b'\n', &mut bytes)`. Parse only buffers ending in newline. Keep the offset before an incomplete EOF buffer. SHA-256 covers at most the first 4 KiB and the 4 KiB ending at `parsed_offset`; store lowercase hex. A full parse returns the checkpoint and exact bytes passed through the JSON parser.

- [ ] **Step 5: Run equivalence tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked typed_parser
cargo test --manifest-path src-tauri/Cargo.toml --locked parent_replay_reader
git add src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/src/importer.rs src-tauri/src/importer/session_parser.rs src-tauri/src/database/conversation_turns.rs
git commit -m "refactor: parse typed complete session records"
```

### Task 3: Add the append fast path and atomic persistence

**Files:**
- Modify: `src-tauri/src/importer/session_parser.rs`
- Modify: `src-tauri/src/importer.rs:175-327`
- Modify: `src-tauri/src/importer.rs:1372-1526`
- Modify: `src-tauri/src/database/import_state.rs`
- Modify: `src-tauri/src/database/usage_events.rs`
- Modify: `src-tauri/src/database/rate_limit_samples.rs`
- Modify: `src-tauri/src/database/conversation_turns.rs`
- Modify: `src-tauri/src/models.rs:421-430`
- Modify: `src/app/types.ts:58-66`
- Modify: `src/app/api.ts:202-213`
- Test: `src-tauri/src/importer.rs`

**Interfaces:**
- Consumes: Tasks 1 and 2 checkpoints plus Slice 2 append writers.
- Produces: `ParsedSessionTail`, `parse_session_update`, `persist_session_update`, append metrics, and unchanged full rebuild behavior.

- [ ] **Step 1: Write failing append and rollback tests**

Add `append_growth_preserves_existing_usage_event_ids`, `append_growth_parses_only_new_bytes`, `append_uses_checkpoint_cumulative_usage`, `append_writes_quota_through_change_point_helper`, `append_updates_active_turn_without_rebuilding_older_turns`, and `checkpoint_rolls_back_with_usage_quota_and_turn_rows`.

```rust
let before_ids = usage_event_ids(&conn, session_id);
append_token_record(&session_path, cumulative_usage(200));
let result = perform_incremental_scan(&db_path, None).unwrap();
let after_ids = usage_event_ids(&conn, session_id);
assert_eq!(&after_ids[..before_ids.len()], before_ids.as_slice());
assert_eq!(result.append_fast_path_files, 1);
assert!(result.source_bytes_read < appended_bytes + 8_192);
```

- [ ] **Step 2: Run tests and verify current rebuild behavior**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked append_growth -- --nocapture`.

Expected: old event IDs are replaced and diagnostics are absent.

- [ ] **Step 3: Add import selection and tail contracts**

```rust
pub enum FullRebuildReason {
  MissingCheckpoint,
  InvalidCheckpoint,
  FileShrank,
  FingerprintMismatch,
  ParserSchemaChanged,
  PendingRepair,
  TopologyChanged,
  ReplacedSource,
}

pub struct TurnResumeState {
  pub active_turn: Option<ConversationTurnPoint>,
  pub next_synthetic_sequence: u64,
}

pub(super) fn parse_session_update(
  session_file: &SessionFile,
  state: Option<&ImportState>,
  turn_resume: TurnResumeState,
  titles: &HashMap<String, String>,
  force_full_rebuild: bool,
) -> Result<SessionImport, SessionParseError>;
```

`TurnResumeState` contains the last persisted active turn and next synthetic turn sequence for that session. Tail parsing begins with it, checkpoint cumulative usage, and last model. A `session_meta` record or parent/fork change returns `TopologyChanged` before any transaction begins.

- [ ] **Step 4: Append derived rows and checkpoint in one transaction**

`persist_session_update` uses Slice 2 `insert_usage_events`, `append_session_rate_limit_samples`, and `upsert_session_turns`. It updates session metadata and checkpoint in the same transaction. It never deletes existing rows on `SessionImport::Append`; the currently active turn may be updated in place while completed older turns retain their IDs. Keep the current delete-and-rebuild code for `SessionImport::Full`.

Extend the serialized Rust and TypeScript `ScanResult` contracts with `source_bytes_read`/`sourceBytesRead`, `append_fast_path_files`/`appendFastPathFiles`, and `full_rebuild_files`/`fullRebuildFiles`. Update the frontend mock to return zero for all three fields. Tests and bounded token metrics use them to verify behavior without accumulating per-file history.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked append_growth
cargo test --manifest-path src-tauri/Cargo.toml --locked checkpoint_rolls_back
git add src-tauri/src/importer.rs src-tauri/src/importer/session_parser.rs src-tauri/src/database/import_state.rs src-tauri/src/database/usage_events.rs src-tauri/src/database/rate_limit_samples.rs src-tauri/src/database/conversation_turns.rs src-tauri/src/models.rs src/app/types.ts src/app/api.ts
git commit -m "feat: append new session records transactionally"
```

### Task 4: Enforce the full-rebuild fallback matrix

**Files:**
- Modify: `src-tauri/src/importer/session_parser.rs`
- Modify: `src-tauri/src/importer.rs:128-327`
- Test: `src-tauri/src/importer.rs`

**Interfaces:**
- Consumes: Task 3 import selection and current repair, fork replay, archive, and topology logic.
- Produces: deterministic `FullRebuildReason` selection and clean-import equivalence.

- [ ] **Step 1: Write failing fallback tests**

Add `append_fallback_rebuilds_truncated_file`, `append_fallback_rebuilds_replaced_same_path`, `append_fallback_rebuilds_on_prefix_mismatch`, `append_fallback_rebuilds_on_tail_mismatch`, `append_fallback_rebuilds_on_parser_version_change`, `partial_checkpoint_selects_invalid_checkpoint_rebuild`, `malformed_checkpoint_selects_invalid_checkpoint_rebuild`, `append_fallback_rebuilds_on_topology_record`, and `append_fallback_matches_clean_full_import`.

- [ ] **Step 2: Run tests and verify missing fallback classifications**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked append_fallback -- --nocapture`.

- [ ] **Step 3: Implement identity validation before parsing the tail**

Map `ImportCheckpointState::Missing` to `MissingCheckpoint`, `Invalid(_)` to `InvalidCheckpoint`, and only `Valid` to append validation. Require current size at least `parsed_file_size` as well as `parsed_offset`, matching prefix and checkpoint-tail hashes, matching schema version, and no pending repair. Archive path changes take one full parse. Never copy a checkpoint across paths merely because session IDs match. A successful full rebuild replaces malformed fields with one valid checkpoint in the same transaction.

- [ ] **Step 4: Compare fallback output with a clean database**

The equivalence test sorts and compares all session fields, usage-event value fields, quota change points, persisted conversation turns, links, and checkpoint values. Preserve existing fork replay, archive completion, invalid UTF-8, and incomplete-tail tests.

- [ ] **Step 5: Run regression tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked append_fallback
cargo test --manifest-path src-tauri/Cargo.toml --locked fork_replay
cargo test --manifest-path src-tauri/Cargo.toml --locked archived
git add src-tauri/src/importer.rs src-tauri/src/importer/session_parser.rs
git commit -m "fix: rebuild safely when append identity changes"
```

### Task 5: Skip unchanged pricing writes and event recalculation

**Files:**
- Modify: `src-tauri/src/pricing.rs:36-230`
- Modify: `src-tauri/src/pricing.rs:452-518`
- Modify: `src-tauri/src/database.rs`
- Modify: `src-tauri/src/importer.rs:88-99`
- Modify: `src-tauri/src/lib.rs:201-224`
- Modify: `src-tauri/src/lib.rs:580-608`
- Test: `src-tauri/src/pricing.rs`
- Test: `src-tauri/src/lib.rs`

**Interfaces:**
- Consumes: existing value-bearing pricing signature and repair marker.
- Produces: `PricingCatalogChange`, one-time startup initialization, no-op upsert, and read-only scan catalog loading.

- [ ] **Step 1: Write failing no-op and rollback tests**

Add `repeated_initializer_does_not_rewrite_unchanged_rows`, `unchanged_scan_does_not_invoke_catalog_initializer`, `unchanged_signature_does_not_update_usage_events`, and `metadata_only_change_does_not_recalculate_values`. Keep existing rollback and malformed GPT-5.6 repair tests.

- [ ] **Step 2: Run tests and record current writes**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked pricing_signature -- --nocapture`.

Expected: `updated_at` and usage-event update counters change on an identical refresh.

- [ ] **Step 3: Add semantic change classification**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PricingCatalogChange { Unchanged, MetadataOnly, ValueChanged }

pub fn apply_pricing_catalog_refresh(
  conn: &Connection,
  official_entries: Option<&[PricingCatalogEntry]>,
) -> Result<PricingCatalogChange, String>;

pub fn initialize_pricing_catalog(
  conn: &Connection,
) -> Result<PricingCatalogChange, String>;

pub fn load_catalog_map(
  conn: &Connection,
) -> rusqlite::Result<HashMap<String, PricingCatalogEntry>>;
```

Upsert rows only when a semantic field differs. Ignore incoming `updated_at` when deciding equality. `initialize_pricing_catalog` seeds only when the catalog is empty or the known repair is pending, and is called from database/app startup migration wiring, never from a scan.

- [ ] **Step 4: Recalculate only value changes**

Remove `seed_pricing_catalog` and repair checks from `perform_scan_with_scope`; scans call read-only `load_catalog_map`. `refresh_pricing_catalog_atomically` recalculates all session values only for `ValueChanged` or an incomplete resolver repair. A metadata-only result updates catalog provenance in the same transaction but performs no usage-event update.

- [ ] **Step 5: Run tests and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked pricing
cargo test --manifest-path src-tauri/Cargo.toml --locked pricing_refresh_rolls_back
git add src-tauri/src/pricing.rs src-tauri/src/database.rs src-tauri/src/importer.rs src-tauri/src/lib.rs
git commit -m "perf: skip unchanged pricing and event rewrites"
```

### Task 6: Update titles only when values change

**Files:**
- Modify: `src-tauri/src/importer.rs:575-611`
- Modify: `src-tauri/src/importer.rs:215-219`
- Test: `src-tauri/src/importer.rs`

**Interfaces:**
- Consumes: current `session_index.jsonl` title map.
- Produces: one conditional title transaction and changed-row count.

- [ ] **Step 1: Write failing title-write tests**

Add `full_scan_does_not_update_unchanged_titles`, `changed_title_updates_once`, and `title_batch_rolls_back_together`. Preserve `full_scan_refreshes_title_when_only_session_index_changes`.

- [ ] **Step 2: Run tests and verify unconditional updates**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked session_titles -- --nocapture`.

- [ ] **Step 3: Implement conditional prepared updates**

Sort by session ID, open one transaction, reuse one statement, and execute:

```sql
UPDATE sessions
SET title = ?1
WHERE session_id = ?2
  AND title IS NOT ?1
```

Return the total changed rows for diagnostics.

- [ ] **Step 4: Run title tests**

Run the focused command and the existing title-only change test. Expected: unchanged scan reports zero title writes.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/importer.rs
git commit -m "perf: update only changed session titles"
```

### Task 7: Prune old quota duplicates in bounded batches

**Files:**
- Modify: `src-tauri/src/database/rate_limit_samples.rs`
- Modify: `src-tauri/src/database.rs`
- Modify: `src-tauri/src/refresh/runtime.rs`
- Test: `src-tauri/src/database/rate_limit_samples.rs`
- Test: `src-tauri/src/refresh/runtime.rs`

**Interfaces:**
- Consumes: Slice 2 epoch fields and new change-point writer.
- Produces: `QuotaCleanupBatchResult`, idempotent old-row cleanup, and coordinator deadline guard.

- [ ] **Step 1: Write failing cleanup and scheduling tests**

Add `cleanup_keeps_first_and_last_of_constant_run`, `cleanup_keeps_percent_changes`, `cleanup_deletes_at_most_batch_size`, `cleanup_resume_is_idempotent`, `cleanup_waits_for_epoch_backfill_completion`, `cleanup_never_touches_legacy_null_epoch_rows`, and `cleanup_does_not_start_within_thirty_seconds_of_refresh_deadline`.

- [ ] **Step 2: Run tests and verify failure**

Run `cargo test --manifest-path src-tauri/Cargo.toml --locked quota_cleanup -- --nocapture`.

- [ ] **Step 3: Implement one bounded batch**

```rust
pub struct QuotaCleanupBatchResult {
  pub deleted_rows: usize,
  pub complete: bool,
}

pub fn prune_redundant_rate_limit_samples_batch(
  conn: &mut Connection,
  batch_size: usize,
) -> rusqlite::Result<QuotaCleanupBatchResult>;
```

Return without mutation unless the Slice 2 epoch repair marker is complete. Select redundant IDs with `LAG` and `LEAD`, restricted by `sample_timestamp_ms IS NOT NULL AND window_start_ms IS NOT NULL AND resets_at_ms IS NOT NULL`, partitioned by `(bucket, window_start_ms, resets_at_ms)`, and ordered by `(sample_timestamp_ms, id)`. Delete at most 500 IDs in one transaction. Preserve first, last, every percent change, and every legacy NULL-epoch row. Mark `quota_history_change_point_cleanup_v1` complete only when a post-backfill batch deletes zero rows.

- [ ] **Step 4: Dispatch only in a safe idle window**

The coordinator gives epoch backfill priority and does not enqueue quota cleanup until that repair is complete. It starts one cleanup batch only when token and live are idle and the next deadline is more than 30 seconds away. Completion may queue another batch through the event channel. It never loops inside one worker and never runs `VACUUM`.

- [ ] **Step 5: Run full slice verification and commit**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --locked --lib
npm test
npm run lint
npm run build
git add src-tauri/src/database.rs src-tauri/src/database/rate_limit_samples.rs src-tauri/src/refresh/runtime.rs
git commit -m "perf: prune redundant quota history in bounded batches"
```

Expected: append tests read only new bytes, fallback equivalence holds, unchanged scans avoid pricing and title writes, cleanup remains bounded, and all existing fork, archive, freshness, and pricing tests pass. Clippy exits successfully; compare its output with the recorded 16-warning repository baseline and fix every new warning in changed files.

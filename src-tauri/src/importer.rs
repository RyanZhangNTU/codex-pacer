use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, FixedOffset, Local, LocalResult, TimeZone, Timelike};
use flate2::{read::GzDecoder, write::GzEncoder, Compression};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::de::{SeqAccess, Visitor};
use serde::ser::SerializeSeq;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use walkdir::WalkDir;

use crate::database::{
  append_session_rate_limit_samples, append_session_usage_events, bool_to_i64, now_utc_string,
  open_connection, preview_scan_freshness_for_source, replace_session_rate_limit_samples,
  replace_session_usage_events, set_last_scan_started_for_source_in_transaction,
  set_scan_completed_for_source, NewUsageEvent,
};
use crate::models::{RateLimitSampleRecord, RawSession, ScanResult, TokenUsage, UsageSnapshot};
use crate::pricing::{
  calculate_value_usd, load_catalog_map, normalize_model_id, resolve_pricing,
};
#[cfg(test)]
use crate::{database::init_db, pricing::seed_pricing_catalog};

#[derive(Debug, Clone)]
struct SessionFile {
  path: PathBuf,
  bucket: String,
  file_size: i64,
  file_mtime_ms: i64,
}

#[derive(Debug, Clone)]
struct ParsedSession {
  raw_session: RawSession,
  snapshots: Vec<UsageSnapshot>,
  rate_limit_samples: Vec<RateLimitSampleRecord>,
  explicit_forked_from_id: Option<String>,
  explicit_fork_timestamp: Option<DateTime<FixedOffset>>,
  inherited_token_snapshot_cutoff: usize,
  explicit_fast_mode: Option<bool>,
  latest_plan_type: Option<String>,
  last_model_id: Option<String>,
  mode: ParsedSessionMode,
  checkpoint: ParserCheckpoint,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum ParsedSessionMode {
  Full,
  Tail {
    previous_usage: Option<TokenUsage>,
  },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ParserCheckpoint {
  completed_offset: u64,
  prefix_signature: Vec<u8>,
  last_usage: Option<TokenUsage>,
  current_model: Option<String>,
  explicit_fast_mode: Option<bool>,
  latest_plan_type: Option<String>,
}

#[derive(Debug, Clone)]
struct SessionMetaCandidate {
  session_id: String,
  parent_session_id: Option<String>,
  explicit_forked_from_id: Option<String>,
  explicit_fork_timestamp: Option<DateTime<FixedOffset>>,
  agent_nickname: Option<String>,
  agent_role: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct ExistingSessionRelation {
  exists: bool,
  parent_session_id: Option<String>,
  child_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TopologyMaintenance {
  None,
  InsertRootLink,
  RecomputeAll,
}

enum SessionParseError {
  Fatal { message: String, bytes_read: u64 },
}

struct CountingReader<R> {
  inner: R,
  bytes_read: u64,
}

impl<R> CountingReader<R> {
  fn new(inner: R) -> Self {
    Self {
      inner,
      bytes_read: 0,
    }
  }
}

impl<R: Read> Read for CountingReader<R> {
  fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
    let bytes_read = self.inner.read(buffer)?;
    self.bytes_read = self.bytes_read.saturating_add(bytes_read as u64);
    Ok(bytes_read)
  }
}

const TOKEN_USAGE_MONOTONIC_REPAIR_KEY: &str = "token_usage_monotonic_v2";
const TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY: &str = "token_usage_fork_replay_v3";
const RATE_LIMIT_SAMPLE_BACKFILL_KEY: &str = "rate_limit_sample_backfill_v1";
const PREPARED_SPOOL_THRESHOLD_BYTES: usize = 256 * 1024;
const PARSER_PREFIX_SIGNATURE_BYTES: u64 = 128;
const PARENT_REPLAY_CACHE_MAX_ENTRIES: usize = 4;
const PARENT_REPLAY_CACHE_MAX_BYTES: usize = 256 * 1024;

struct RefreshMemoryRelief;

impl Drop for RefreshMemoryRelief {
  fn drop(&mut self) {
    release_unused_process_memory();
  }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
  fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
}

#[cfg(target_os = "macos")]
pub(crate) fn release_unused_process_memory() {
  // SAFETY: A null zone asks the macOS allocator to visit every registered zone.
  // The call only releases pages currently unused by those zones.
  unsafe {
    malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
  }
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn release_unused_process_memory() {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ScanKind {
  Full,
  Reconcile,
  Incremental,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PreparedScanStats {
  pub files_visited: usize,
  pub source_bytes_read: u64,
  pub tail_parsed_files: usize,
  pub fully_parsed_files: usize,
  pub full_rebuild: bool,
  pub used_spool: bool,
  pub parent_replay_cache_evictions: usize,
  pub parent_replay_cache_oversized_bypasses: usize,
}

pub(crate) struct PreparedScan {
  db_path: PathBuf,
  source_identity: PreparedSourceIdentity,
  scan_started_at: String,
  track_scan_freshness: bool,
  effective_kind: ScanKind,
  freshness_full_scan_required: bool,
  stats: PreparedScanStats,
  imported_sessions: usize,
  updated_sessions: usize,
  skipped_session_files: bool,
  storage: PreparedStorage,
  parse_failures: Vec<PreparedParseFailure>,
  titles: HashMap<String, String>,
  missing_plan: MissingSourcePlan,
  topology_dirty: bool,
  topology_needs_repair: bool,
  new_root_session_ids: Vec<String>,
  needs_rate_limit_backfill: bool,
  needs_token_usage_v2_repair_sweep: bool,
  needs_fork_replay_v3_repair_sweep: bool,
}

impl PreparedScan {
  #[allow(dead_code)]
  pub(crate) fn stats(&self) -> PreparedScanStats {
    self.stats
  }

  #[allow(dead_code)]
  pub(crate) fn source_key(&self) -> &PreparedScanSourceKey {
    &self.source_identity.key
  }

  #[cfg(test)]
  fn uses_spool(&self) -> bool {
    matches!(self.storage, PreparedStorage::Spool { .. })
  }

  #[cfg(test)]
  fn parent_replay_cache_evictions(&self) -> usize {
    self.stats.parent_replay_cache_evictions
  }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PreparedScanSourceKey {
  selector: Option<String>,
  resolved_home: PathBuf,
}

impl PreparedScanSourceKey {
  #[allow(dead_code)]
  pub(crate) fn selector(&self) -> Option<&str> {
    self.selector.as_deref()
  }

  #[allow(dead_code)]
  pub(crate) fn resolved_home(&self) -> &Path {
    &self.resolved_home
  }
}

struct PreparedSourceIdentity {
  key: PreparedScanSourceKey,
  scan_commit_revision: i64,
  tracked_configured_home: Option<PathBuf>,
  last_scan_codex_home: Option<String>,
  last_scan_started_at: Option<String>,
  last_scan_completed_at: Option<String>,
  last_full_scan_completed_at: Option<String>,
}

struct PreparationDatabaseSnapshot {
  scan_source_selector: Option<String>,
  scan_commit_revision: i64,
  last_scan_codex_home: Option<String>,
  last_scan_started_at: Option<String>,
  last_scan_completed_at: Option<String>,
  last_full_scan_completed_at: Option<String>,
  import_state: HashMap<String, ImportState>,
  needs_rate_limit_backfill: bool,
  pending_rate_limit_repair_paths: HashSet<String>,
  needs_token_usage_v2_repair_sweep: bool,
  pending_token_v2_repair_paths: HashSet<String>,
  needs_fork_replay_v3_repair_sweep: bool,
  pending_fork_replay_v3_repair_paths: HashSet<String>,
  session_source_paths: HashMap<String, PathBuf>,
  existing_relations: HashMap<String, ExistingSessionRelation>,
  existing_session_sources: Vec<ExistingSessionSource>,
  topology_needs_repair: bool,
}

struct ExistingSessionSource {
  session_id: String,
  source_path: String,
  source_state: String,
  source_bucket: Option<String>,
}

struct PreparedSession {
  session_file: PreparedSessionFile,
  parsed: ParsedSession,
  file_needs_rate_limit_repair: bool,
  file_needs_token_v2_repair: bool,
  file_needs_fork_replay_v3_repair: bool,
  replay_parent_unavailable: bool,
  related_pending_token_v2_paths: Vec<String>,
  related_pending_fork_replay_v3_paths: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct PreparedSessionFile {
  source_path: String,
  bucket: String,
  file_size: i64,
  file_mtime_ms: i64,
}

impl From<SessionFile> for PreparedSessionFile {
  fn from(session_file: SessionFile) -> Self {
    Self {
      source_path: session_file.path.to_string_lossy().into_owned(),
      bucket: session_file.bucket,
      file_size: session_file.file_size,
      file_mtime_ms: session_file.file_mtime_ms,
    }
  }
}

struct PreparedParseFailure {
  source_path: String,
  error: String,
  mark_rate_limit_repair: bool,
  mark_token_v2_repair: bool,
  mark_fork_replay_v3_repair: bool,
}

#[derive(Default)]
struct MissingSourcePlan {
  sessions_to_mark_missing: Vec<MissingSessionPlan>,
  import_state_paths_to_delete: Vec<String>,
}

struct MissingSessionPlan {
  session_id: String,
  expected_source_path: String,
}

enum PreparedStorage {
  Memory(Vec<PreparedSession>),
  Spool { file: File, records: usize },
}

enum PreparedStorageBuilder {
  Memory {
    entries: Vec<PreparedSession>,
    estimated_bytes: usize,
  },
  Spool {
    writer: GzEncoder<BufWriter<File>>,
    records: usize,
  },
}

#[derive(Serialize, Deserialize)]
struct SpoolPreparedSession {
  session_file: PreparedSessionFile,
  raw_session: RawSession,
  snapshots: SpoolUsageSnapshots,
  rate_limit_samples: Vec<RateLimitSampleRecord>,
  explicit_forked_from_id: Option<String>,
  explicit_fork_timestamp: Option<DateTime<FixedOffset>>,
  inherited_token_snapshot_cutoff: usize,
  explicit_fast_mode: Option<bool>,
  latest_plan_type: Option<String>,
  last_model_id: Option<String>,
  mode: ParsedSessionMode,
  checkpoint: ParserCheckpoint,
  file_needs_rate_limit_repair: bool,
  file_needs_token_v2_repair: bool,
  file_needs_fork_replay_v3_repair: bool,
  replay_parent_unavailable: bool,
  related_pending_token_v2_paths: Vec<String>,
  related_pending_fork_replay_v3_paths: Vec<String>,
}

struct SpoolUsageSnapshots(Vec<UsageSnapshot>);

#[derive(Deserialize)]
struct SpoolUsageSnapshot {
  timestamp: String,
  model_id: String,
  usage: TokenUsage,
  last_token_usage: Option<TokenUsage>,
  plan_type: Option<String>,
  limit_id: Option<String>,
  limit_name: Option<String>,
  explicit_fast_mode: Option<bool>,
}

#[derive(Serialize)]
struct SpoolUsageSnapshotRef<'a> {
  timestamp: &'a str,
  model_id: &'a str,
  usage: &'a TokenUsage,
  last_token_usage: Option<&'a TokenUsage>,
  plan_type: Option<&'a str>,
  limit_id: Option<&'a str>,
  limit_name: Option<&'a str>,
  explicit_fast_mode: Option<bool>,
}

struct ParentReplayCacheEntry {
  snapshots: Option<Vec<UsageSnapshot>>,
  estimated_bytes: usize,
}

struct ParentReplayCache {
  entries: HashMap<String, ParentReplayCacheEntry>,
  insertion_order: VecDeque<String>,
  estimated_bytes: usize,
  evictions: usize,
  oversized_bypasses: usize,
}

impl Serialize for SpoolUsageSnapshots {
  fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
  where
    S: Serializer,
  {
    let mut sequence = serializer.serialize_seq(Some(self.0.len()))?;
    for snapshot in &self.0 {
      sequence.serialize_element(&SpoolUsageSnapshotRef {
        timestamp: &snapshot.timestamp,
        model_id: &snapshot.model_id,
        usage: &snapshot.usage,
        last_token_usage: snapshot.last_token_usage.as_ref(),
        plan_type: snapshot.plan_type.as_deref(),
        limit_id: snapshot.limit_id.as_deref(),
        limit_name: snapshot.limit_name.as_deref(),
        explicit_fast_mode: snapshot.explicit_fast_mode,
      })?;
    }
    sequence.end()
  }
}

struct SpoolUsageSnapshotsVisitor;

impl<'de> Visitor<'de> for SpoolUsageSnapshotsVisitor {
  type Value = SpoolUsageSnapshots;

  fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    formatter.write_str("a sequence of prepared usage snapshots")
  }

  fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
  where
    A: SeqAccess<'de>,
  {
    let mut snapshots = Vec::with_capacity(sequence.size_hint().unwrap_or_default());
    while let Some(snapshot) = sequence.next_element::<SpoolUsageSnapshot>()? {
      snapshots.push(snapshot.into());
    }
    Ok(SpoolUsageSnapshots(snapshots))
  }
}

impl<'de> Deserialize<'de> for SpoolUsageSnapshots {
  fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    deserializer.deserialize_seq(SpoolUsageSnapshotsVisitor)
  }
}

impl From<SpoolUsageSnapshot> for UsageSnapshot {
  fn from(snapshot: SpoolUsageSnapshot) -> Self {
    Self {
      timestamp: snapshot.timestamp,
      model_id: snapshot.model_id,
      usage: snapshot.usage,
      last_token_usage: snapshot.last_token_usage,
      plan_type: snapshot.plan_type,
      limit_id: snapshot.limit_id,
      limit_name: snapshot.limit_name,
      explicit_fast_mode: snapshot.explicit_fast_mode,
    }
  }
}

impl From<PreparedSession> for SpoolPreparedSession {
  fn from(entry: PreparedSession) -> Self {
    let PreparedSession {
      session_file,
      parsed,
      file_needs_rate_limit_repair,
      file_needs_token_v2_repair,
      file_needs_fork_replay_v3_repair,
      replay_parent_unavailable,
      related_pending_token_v2_paths,
      related_pending_fork_replay_v3_paths,
    } = entry;
    let ParsedSession {
      raw_session,
      snapshots,
      rate_limit_samples,
      explicit_forked_from_id,
      explicit_fork_timestamp,
      inherited_token_snapshot_cutoff,
      explicit_fast_mode,
      latest_plan_type,
      last_model_id,
      mode,
      checkpoint,
    } = parsed;

    Self {
      session_file,
      raw_session,
      snapshots: SpoolUsageSnapshots(snapshots),
      rate_limit_samples,
      explicit_forked_from_id,
      explicit_fork_timestamp,
      inherited_token_snapshot_cutoff,
      explicit_fast_mode,
      latest_plan_type,
      last_model_id,
      mode,
      checkpoint,
      file_needs_rate_limit_repair,
      file_needs_token_v2_repair,
      file_needs_fork_replay_v3_repair,
      replay_parent_unavailable,
      related_pending_token_v2_paths,
      related_pending_fork_replay_v3_paths,
    }
  }
}

impl From<SpoolPreparedSession> for PreparedSession {
  fn from(entry: SpoolPreparedSession) -> Self {
    Self {
      session_file: entry.session_file,
      parsed: ParsedSession {
        raw_session: entry.raw_session,
        snapshots: entry.snapshots.0,
        rate_limit_samples: entry.rate_limit_samples,
        explicit_forked_from_id: entry.explicit_forked_from_id,
        explicit_fork_timestamp: entry.explicit_fork_timestamp,
        inherited_token_snapshot_cutoff: entry.inherited_token_snapshot_cutoff,
        explicit_fast_mode: entry.explicit_fast_mode,
        latest_plan_type: entry.latest_plan_type,
        last_model_id: entry.last_model_id,
        mode: entry.mode,
        checkpoint: entry.checkpoint,
      },
      file_needs_rate_limit_repair: entry.file_needs_rate_limit_repair,
      file_needs_token_v2_repair: entry.file_needs_token_v2_repair,
      file_needs_fork_replay_v3_repair: entry.file_needs_fork_replay_v3_repair,
      replay_parent_unavailable: entry.replay_parent_unavailable,
      related_pending_token_v2_paths: entry.related_pending_token_v2_paths,
      related_pending_fork_replay_v3_paths: entry.related_pending_fork_replay_v3_paths,
    }
  }
}

impl PreparedSession {
  fn estimated_bytes(&self) -> usize {
    let raw = &self.parsed.raw_session;
    let mut bytes = std::mem::size_of::<Self>()
      .saturating_add(self.session_file.source_path.capacity())
      .saturating_add(self.session_file.bucket.capacity())
      .saturating_add(raw.session_id.capacity())
      .saturating_add(option_string_capacity(&raw.parent_session_id))
      .saturating_add(raw.root_session_id.capacity())
      .saturating_add(option_string_capacity(&raw.title))
      .saturating_add(raw.source_state.capacity())
      .saturating_add(option_string_capacity(&raw.source_path))
      .saturating_add(option_string_capacity(&raw.started_at))
      .saturating_add(option_string_capacity(&raw.updated_at))
      .saturating_add(option_string_capacity(&raw.agent_nickname))
      .saturating_add(option_string_capacity(&raw.agent_role))
      .saturating_add(estimated_string_vec_bytes(&raw.model_ids))
      .saturating_add(estimated_usage_snapshots_bytes(&self.parsed.snapshots))
      .saturating_add(option_string_capacity(&self.parsed.explicit_forked_from_id))
      .saturating_add(option_string_capacity(&self.parsed.latest_plan_type))
      .saturating_add(option_string_capacity(&self.parsed.last_model_id))
      .saturating_add(
        self
          .parsed
          .rate_limit_samples
          .capacity()
          .saturating_mul(std::mem::size_of::<RateLimitSampleRecord>()),
      );

    for sample in &self.parsed.rate_limit_samples {
      bytes = bytes
        .saturating_add(sample.source_kind.capacity())
        .saturating_add(option_string_capacity(&sample.source_session_id))
        .saturating_add(sample.bucket.capacity())
        .saturating_add(sample.sample_timestamp.capacity())
        .saturating_add(option_string_capacity(&sample.limit_id))
        .saturating_add(option_string_capacity(&sample.limit_name))
        .saturating_add(option_string_capacity(&sample.plan_type))
        .saturating_add(sample.window_start.capacity())
        .saturating_add(sample.resets_at.capacity());
    }
    bytes
      .saturating_add(estimated_string_vec_bytes(
        &self.related_pending_token_v2_paths,
      ))
      .saturating_add(estimated_string_vec_bytes(
        &self.related_pending_fork_replay_v3_paths,
      ))
  }
}

impl PreparedStorageBuilder {
  fn new() -> Self {
    Self::Memory {
      entries: Vec::new(),
      estimated_bytes: 0,
    }
  }

  fn push(&mut self, entry: PreparedSession) -> Result<(), String> {
    let state = std::mem::replace(
      self,
      Self::Memory {
        entries: Vec::new(),
        estimated_bytes: 0,
      },
    );

    *self = match state {
      Self::Memory {
        mut entries,
        estimated_bytes,
      } => {
        let previous_spare_bytes = entries
          .capacity()
          .saturating_sub(entries.len())
          .saturating_mul(std::mem::size_of::<PreparedSession>());
        let entries_bytes = estimated_bytes.saturating_sub(previous_spare_bytes);
        let entry_bytes = entry.estimated_bytes();
        entries.push(entry);
        let next_spare_bytes = entries
          .capacity()
          .saturating_sub(entries.len())
          .saturating_mul(std::mem::size_of::<PreparedSession>());
        let next_bytes = entries_bytes
          .saturating_add(entry_bytes)
          .saturating_add(next_spare_bytes);
        if entries.len() == 1 || next_bytes <= PREPARED_SPOOL_THRESHOLD_BYTES {
          Self::Memory {
            entries,
            estimated_bytes: next_bytes,
          }
        } else {
          let file = tempfile::tempfile()
            .map_err(|error| format!("Failed to create prepared scan spool: {error}"))?;
          let mut writer = GzEncoder::new(BufWriter::new(file), Compression::fast());
          let mut records = 0usize;
          for buffered in entries {
            write_spool_record(&mut writer, buffered)?;
            records += 1;
          }
          Self::Spool { writer, records }
        }
      }
      Self::Spool {
        mut writer,
        mut records,
      } => {
        write_spool_record(&mut writer, entry)?;
        records += 1;
        Self::Spool { writer, records }
      }
    };
    Ok(())
  }

  fn finish(self) -> Result<PreparedStorage, String> {
    match self {
      Self::Memory { entries, .. } => Ok(PreparedStorage::Memory(entries)),
      Self::Spool {
        writer,
        records,
      } => {
        let file = writer
          .finish()
          .map_err(|error| format!("Failed to compress prepared scan spool: {error}"))?
          .into_inner()
          .map_err(|error| format!("Failed to finish prepared scan spool: {}", error.error()))?;
        Ok(PreparedStorage::Spool { file, records })
      }
    }
  }
}

fn write_spool_record(
  writer: &mut GzEncoder<BufWriter<File>>,
  entry: PreparedSession,
) -> Result<(), String> {
  let entry = SpoolPreparedSession::from(entry);
  serde_json::to_writer(&mut *writer, &entry)
    .map_err(|error| format!("Failed to write prepared scan spool: {error}"))?;
  writer
    .write_all(b"\n")
    .map_err(|error| format!("Failed to delimit prepared scan spool: {error}"))
}

impl ParentReplayCache {
  fn new() -> Self {
    Self {
      entries: HashMap::new(),
      insertion_order: VecDeque::new(),
      estimated_bytes: 0,
      evictions: 0,
      oversized_bypasses: 0,
    }
  }

  fn get(&self, session_id: &str) -> Option<&Option<Vec<UsageSnapshot>>> {
    self.entries.get(session_id).map(|entry| &entry.snapshots)
  }

  fn insert(&mut self, session_id: String, snapshots: Option<Vec<UsageSnapshot>>) {
    let insertion_order_id = session_id.clone();
    let entry_bytes = std::mem::size_of::<ParentReplayCacheEntry>()
      .saturating_add(std::mem::size_of::<String>().saturating_mul(2))
      .saturating_add(session_id.capacity())
      .saturating_add(insertion_order_id.capacity())
      .saturating_add(
        snapshots
          .as_ref()
          .map(estimated_usage_snapshots_bytes)
          .unwrap_or(1),
      );
    if entry_bytes > PARENT_REPLAY_CACHE_MAX_BYTES {
      self.oversized_bypasses += 1;
      return;
    }

    while self.entries.len() >= PARENT_REPLAY_CACHE_MAX_ENTRIES
      || self.estimated_bytes.saturating_add(entry_bytes) > PARENT_REPLAY_CACHE_MAX_BYTES
    {
      let Some(oldest_session_id) = self.insertion_order.pop_front() else {
        break;
      };
      if let Some(oldest) = self.entries.remove(&oldest_session_id) {
        self.estimated_bytes = self.estimated_bytes.saturating_sub(oldest.estimated_bytes);
        self.evictions += 1;
      }
    }

    self.estimated_bytes = self.estimated_bytes.saturating_add(entry_bytes);
    self.insertion_order.push_back(insertion_order_id);
    self.entries.insert(
      session_id,
      ParentReplayCacheEntry {
        snapshots,
        estimated_bytes: entry_bytes,
      },
    );
  }

  fn evictions(&self) -> usize {
    self.evictions
  }

  fn oversized_bypasses(&self) -> usize {
    self.oversized_bypasses
  }
}

fn option_string_capacity(value: &Option<String>) -> usize {
  value.as_ref().map(String::capacity).unwrap_or_default()
}

fn estimated_string_vec_bytes(values: &Vec<String>) -> usize {
  values
    .capacity()
    .saturating_mul(std::mem::size_of::<String>())
    .saturating_add(values.iter().fold(0usize, |bytes, value| {
      bytes.saturating_add(value.capacity())
    }))
}

fn estimated_usage_snapshots_bytes(snapshots: &Vec<UsageSnapshot>) -> usize {
  snapshots
    .capacity()
    .saturating_mul(std::mem::size_of::<UsageSnapshot>())
    .saturating_add(snapshots.iter().fold(0usize, |bytes, snapshot| {
      bytes
        .saturating_add(snapshot.timestamp.capacity())
        .saturating_add(snapshot.model_id.capacity())
        .saturating_add(option_string_capacity(&snapshot.plan_type))
        .saturating_add(option_string_capacity(&snapshot.limit_id))
        .saturating_add(option_string_capacity(&snapshot.limit_name))
    }))
}

#[cfg(test)]
pub fn perform_scan(
  db_path: &Path,
  codex_home_override: Option<String>,
) -> Result<ScanResult, String> {
  perform_scan_with_kind(db_path, codex_home_override, ScanKind::Full)
}

#[cfg(test)]
pub fn perform_incremental_scan(
  db_path: &Path,
  codex_home_override: Option<String>,
) -> Result<ScanResult, String> {
  perform_scan_with_kind(db_path, codex_home_override, ScanKind::Incremental)
}

#[cfg(test)]
fn perform_scan_with_kind(
  db_path: &Path,
  codex_home_override: Option<String>,
  requested_kind: ScanKind,
) -> Result<ScanResult, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  init_db(&conn).map_err(|error| error.to_string())?;
  seed_pricing_catalog(&conn).map_err(|error| error.to_string())?;
  drop(conn);

  let prepared = prepare_scan(db_path, codex_home_override, requested_kind)?;
  commit_prepared_scan(prepared)
}

#[cfg(test)]
pub(crate) fn prepare_scan(
  db_path: &Path,
  codex_home_override: Option<String>,
  requested_kind: ScanKind,
) -> Result<PreparedScan, String> {
  let database_snapshot = load_preparation_database_snapshot(
    db_path,
    codex_home_override.as_deref(),
    requested_kind,
  )
  .map_err(|error| error.to_string())?;
  prepare_scan_from_snapshot(
    db_path,
    codex_home_override,
    requested_kind,
    database_snapshot,
  )
}

pub(crate) fn prepare_scan_with_cached_snapshot_connection(
  db_path: &Path,
  codex_home_override: Option<String>,
  requested_kind: ScanKind,
  cached_connection: &mut Option<Connection>,
) -> Result<PreparedScan, String> {
  if cached_connection.is_none() {
    let connection = open_scan_snapshot(db_path).map_err(|error| error.to_string())?;
    connection
      .pragma_update(None, "cache_size", -16_384)
      .map_err(|error| error.to_string())?;
    *cached_connection = Some(connection);
  }
  let database_snapshot = match load_preparation_database_snapshot_from_connection(
    cached_connection.as_mut().expect("cached connection initialized"),
    codex_home_override.as_deref(),
    requested_kind,
  ) {
    Ok(snapshot) => snapshot,
    Err(error) => {
      *cached_connection = None;
      return Err(error.to_string());
    }
  };
  prepare_scan_from_snapshot(
    db_path,
    codex_home_override,
    requested_kind,
    database_snapshot,
  )
}

fn prepare_scan_from_snapshot(
  db_path: &Path,
  codex_home_override: Option<String>,
  requested_kind: ScanKind,
  database_snapshot: PreparationDatabaseSnapshot,
) -> Result<PreparedScan, String> {
  let scan_started_at = now_utc_string();
  let PreparationDatabaseSnapshot {
    scan_source_selector,
    scan_commit_revision,
    last_scan_codex_home,
    last_scan_started_at,
    last_scan_completed_at,
    last_full_scan_completed_at,
    import_state,
    needs_rate_limit_backfill,
    pending_rate_limit_repair_paths,
    needs_token_usage_v2_repair_sweep,
    pending_token_v2_repair_paths,
    needs_fork_replay_v3_repair_sweep,
    pending_fork_replay_v3_repair_paths,
    mut session_source_paths,
    mut existing_relations,
    existing_session_sources,
    topology_needs_repair,
  } = database_snapshot;

  let home_dir = dirs::home_dir();
  let configured_home =
    resolve_codex_home(scan_source_selector.as_deref(), None, home_dir.as_deref())
      .and_then(|path| expand_home_prefix(path, home_dir.as_deref()))
      .ok();
  let codex_home = validate_codex_home(
    resolve_codex_home(
      scan_source_selector.as_deref(),
      codex_home_override,
      home_dir.as_deref(),
    )?,
    home_dir.as_deref(),
  )?;
  let track_scan_freshness = freshness_source_matches(
    scan_source_selector.as_deref(),
    &codex_home,
    home_dir.as_deref(),
  );
  let resolved_codex_home = codex_home.to_string_lossy().to_string();
  let freshness_full_scan_required = track_scan_freshness
    && (last_scan_codex_home.as_deref() != Some(resolved_codex_home.as_str())
      || last_full_scan_completed_at.is_none());
  let pending_token_v2_repair_session_ids =
    pending_repair_session_ids(&import_state, &pending_token_v2_repair_paths);
  let pending_fork_replay_v3_repair_session_ids =
    pending_repair_session_ids(&import_state, &pending_fork_replay_v3_repair_paths);
  let mut pending_repair_session_ids =
    pending_repair_session_ids(&import_state, &pending_rate_limit_repair_paths);
  pending_repair_session_ids.extend(pending_token_v2_repair_session_ids.iter().cloned());
  pending_repair_session_ids.extend(pending_fork_replay_v3_repair_session_ids.iter().cloned());
  let mut pending_repair_paths = pending_rate_limit_repair_paths.clone();
  pending_repair_paths.extend(pending_token_v2_repair_paths.iter().cloned());
  pending_repair_paths.extend(pending_fork_replay_v3_repair_paths.iter().cloned());
  let needs_token_usage_repair_sweep =
    needs_token_usage_v2_repair_sweep || needs_fork_replay_v3_repair_sweep;
  let effective_kind = effective_scan_scope(
    requested_kind,
    import_state.is_empty(),
    needs_rate_limit_backfill,
    needs_token_usage_repair_sweep,
    freshness_full_scan_required,
  );

  let (session_files, active_paths_kept_for_archive_retry) = match effective_kind {
    ScanKind::Full => (collect_session_files(&codex_home), HashSet::new()),
    ScanKind::Reconcile => (collect_session_files(&codex_home), HashSet::new()),
    ScanKind::Incremental => {
      collect_incremental_session_files(
        &codex_home,
        &import_state,
        &pending_repair_session_ids,
        &pending_repair_paths,
      )
    }
  };
  let stats = PreparedScanStats {
    files_visited: session_files.len(),
    source_bytes_read: 0,
    tail_parsed_files: 0,
    fully_parsed_files: 0,
    full_rebuild: effective_kind == ScanKind::Full,
    used_spool: false,
    parent_replay_cache_evictions: 0,
    parent_replay_cache_oversized_bypasses: 0,
  };
  for session_file in &session_files {
    let Some(session_id) = fallback_session_id_from_filename(&session_file.path) else {
      continue;
    };
    session_source_paths.insert(session_id, session_file.path.clone());
  }
  let mut present_paths: HashSet<String> = session_files
    .iter()
    .map(|item| item.path.to_string_lossy().to_string())
    .collect();
  present_paths.extend(active_paths_kept_for_archive_retry);

  let mut imported_session_ids = HashSet::new();
  let mut changed_files = Vec::new();
  for session_file in &session_files {
    let source_path = session_file.path.to_string_lossy().to_string();
    let session_id = import_state
      .get(&source_path)
      .and_then(|state| state.session_id.clone())
      .or_else(|| fallback_session_id_from_filename(&session_file.path));
    let session_has_pending_token_v2_repair = session_id
      .as_ref()
      .is_some_and(|session_id| pending_token_v2_repair_session_ids.contains(session_id));
    let session_has_pending_fork_replay_v3_repair = session_id
      .as_ref()
      .is_some_and(|session_id| pending_fork_replay_v3_repair_session_ids.contains(session_id));
    if needs_rate_limit_backfill
      || pending_rate_limit_repair_paths.contains(&source_path)
      || needs_token_usage_repair_sweep
      || pending_token_v2_repair_paths.contains(&source_path)
      || pending_fork_replay_v3_repair_paths.contains(&source_path)
      || session_has_pending_token_v2_repair
      || session_has_pending_fork_replay_v3_repair
    {
      changed_files.push(session_file.clone());
      continue;
    }
    if let Some(state) = import_state.get(&source_path) {
      let session_id_mismatch = import_state_session_id_mismatch(state, session_file);
      if state.file_size == session_file.file_size
        && !session_id_mismatch
        && (state.file_mtime_ms == session_file.file_mtime_ms
          || parser_checkpoint_prefix_matches(state, session_file))
      {
        if let Some(session_id) = &state.session_id {
          imported_session_ids.insert(session_id.clone());
        }
        continue;
      }
    }

    changed_files.push(session_file.clone());
  }

  let titles = if effective_kind != ScanKind::Incremental || !changed_files.is_empty() {
    load_session_index(&codex_home)
  } else {
    HashMap::new()
  };

  let mut topology_dirty = false;
  let mut new_root_session_ids = Vec::new();
  let mut skipped_session_files = false;
  let mut parse_failures = Vec::new();
  let mut parent_snapshot_cache = ParentReplayCache::new();
  let mut storage = PreparedStorageBuilder::new();
  let mut updated_sessions = 0usize;
  let mut source_bytes_read = 0u64;
  let mut tail_parsed_files = 0usize;
  let mut fully_parsed_files = 0usize;

  for session_file in changed_files {
    let source_path = session_file.path.to_string_lossy().to_string();
    let file_needs_rate_limit_repair =
      needs_rate_limit_backfill || pending_rate_limit_repair_paths.contains(&source_path);
    let mut file_needs_token_v2_repair =
      needs_token_usage_v2_repair_sweep || pending_token_v2_repair_paths.contains(&source_path);
    let mut file_needs_fork_replay_v3_repair = needs_fork_replay_v3_repair_sweep
      || pending_fork_replay_v3_repair_paths.contains(&source_path);
    let tail_candidate = if effective_kind != ScanKind::Full
      && !file_needs_rate_limit_repair
      && !file_needs_token_v2_repair
      && !file_needs_fork_replay_v3_repair
    {
      if let Some(state) = import_state.get(&source_path) {
        try_parse_session_tail_counted(
          &session_file,
          state,
          &titles,
          state
            .session_id
            .as_ref()
            .and_then(|session_id| existing_relations.get(session_id)),
        )
      } else {
        Ok(None)
      }
    } else {
      Ok(None)
    };
    let parsed_result = match tail_candidate {
      Ok(Some(result)) => {
        tail_parsed_files += 1;
        Ok(result)
      }
      Ok(None) => {
        fully_parsed_files += 1;
        parse_session_file_counted(&session_file, &titles)
      }
      Err(error) => Err(error),
    };
    let (mut parsed, bytes_read) = match parsed_result {
      Ok(parsed) => parsed,
      Err((error, bytes_read)) => {
        source_bytes_read = source_bytes_read.saturating_add(bytes_read);
        skipped_session_files = true;
        log::warn!(
          "Skipping unreadable session file {}: {}",
          session_file.path.display(),
          error
        );
        parse_failures.push(PreparedParseFailure {
          source_path,
          error,
          mark_rate_limit_repair: file_needs_rate_limit_repair,
          mark_token_v2_repair: file_needs_token_v2_repair,
          mark_fork_replay_v3_repair: file_needs_fork_replay_v3_repair,
        });
        continue;
      }
    };
    source_bytes_read = source_bytes_read.saturating_add(bytes_read);

    ensure_replay_parent_source_path(db_path, &parsed, &mut session_source_paths)?;
    let (replay_parent_unavailable, parent_replay_bytes_read) =
      if matches!(parsed.mode, ParsedSessionMode::Full) {
        assign_inherited_token_snapshot_cutoff(
          &mut parsed,
          &session_source_paths,
          &mut parent_snapshot_cache,
        )
      } else {
        (false, 0)
      };
    source_bytes_read = source_bytes_read.saturating_add(parent_replay_bytes_read);
    let related_pending_token_v2_paths = pending_repair_paths_for_session(
      &import_state,
      &pending_token_v2_repair_paths,
      &parsed.raw_session.session_id,
    );
    let related_pending_fork_replay_v3_paths = pending_repair_paths_for_session(
      &import_state,
      &pending_fork_replay_v3_repair_paths,
      &parsed.raw_session.session_id,
    );
    file_needs_token_v2_repair |= !related_pending_token_v2_paths.is_empty();
    file_needs_fork_replay_v3_repair |=
      replay_parent_unavailable || !related_pending_fork_replay_v3_paths.is_empty();
    imported_session_ids.insert(parsed.raw_session.session_id.clone());

    ensure_existing_relation_context(
      db_path,
      &parsed.raw_session.session_id,
      &mut existing_relations,
    )?;
    match classify_topology_maintenance(
      existing_relations.get(&parsed.raw_session.session_id),
      existing_relations
        .get(&parsed.raw_session.session_id)
        .map(|item| item.child_count)
        .unwrap_or_default(),
      parsed.raw_session.parent_session_id.as_deref(),
    ) {
      TopologyMaintenance::None => {}
      TopologyMaintenance::InsertRootLink => {
        new_root_session_ids.push(parsed.raw_session.session_id.clone());
      }
      TopologyMaintenance::RecomputeAll => {
        topology_dirty = true;
      }
    }

    storage.push(PreparedSession {
      session_file: session_file.into(),
      parsed,
      file_needs_rate_limit_repair,
      file_needs_token_v2_repair,
      file_needs_fork_replay_v3_repair,
      replay_parent_unavailable,
      related_pending_token_v2_paths,
      related_pending_fork_replay_v3_paths,
    })?;
    updated_sessions += 1;
  }

  let titles = if effective_kind != ScanKind::Incremental {
    titles
  } else {
    HashMap::new()
  };

  let parent_replay_cache_evictions = parent_snapshot_cache.evictions();
  let parent_replay_cache_oversized_bypasses = parent_snapshot_cache.oversized_bypasses();
  drop(parent_snapshot_cache);
  drop(session_source_paths);
  drop(existing_relations);

  let missing_plan = prepare_missing_source_plan(
    &existing_session_sources,
    &import_state,
    &present_paths,
    effective_kind,
    freshness_full_scan_required,
  );
  let storage = storage.finish()?;
  let stats = PreparedScanStats {
    source_bytes_read,
    tail_parsed_files,
    fully_parsed_files,
    used_spool: matches!(&storage, PreparedStorage::Spool { .. }),
    parent_replay_cache_evictions,
    parent_replay_cache_oversized_bypasses,
    ..stats
  };

  Ok(PreparedScan {
    db_path: db_path.to_path_buf(),
    source_identity: PreparedSourceIdentity {
      key: PreparedScanSourceKey {
        selector: scan_source_selector,
        resolved_home: codex_home,
      },
      scan_commit_revision,
      tracked_configured_home: track_scan_freshness.then_some(configured_home).flatten(),
      last_scan_codex_home,
      last_scan_started_at,
      last_scan_completed_at,
      last_full_scan_completed_at,
    },
    scan_started_at,
    track_scan_freshness,
    effective_kind,
    freshness_full_scan_required,
    stats,
    imported_sessions: imported_session_ids.len(),
    updated_sessions,
    skipped_session_files,
    storage,
    parse_failures,
    titles,
    missing_plan,
    topology_dirty,
    topology_needs_repair,
    new_root_session_ids,
    needs_rate_limit_backfill,
    needs_token_usage_v2_repair_sweep,
    needs_fork_replay_v3_repair_sweep,
  })
}

pub(crate) fn commit_prepared_scan(prepared: PreparedScan) -> Result<ScanResult, String> {
  let _memory_relief = RefreshMemoryRelief;
  let PreparedScan {
    db_path,
    source_identity,
    scan_started_at,
    track_scan_freshness,
    effective_kind,
    freshness_full_scan_required,
    stats,
    imported_sessions,
    updated_sessions,
    skipped_session_files,
    storage,
    parse_failures,
    titles,
    missing_plan,
    topology_dirty,
    topology_needs_repair,
    new_root_session_ids,
    needs_rate_limit_backfill,
    needs_token_usage_v2_repair_sweep,
    needs_fork_replay_v3_repair_sweep,
  } = prepared;

  let mut conn = open_connection(&db_path).map_err(|error| error.to_string())?;
  let tx = conn
    .transaction_with_behavior(TransactionBehavior::Immediate)
    .map_err(|error| error.to_string())?;
  validate_prepared_source_identity(&tx, &source_identity)?;
  let catalog = load_catalog_map(&tx).map_err(|error| error.to_string())?;
  let resolved_codex_home = source_identity
    .key
    .resolved_home
    .to_string_lossy()
    .to_string();

  let scan_freshness_preview = if track_scan_freshness {
    preview_scan_freshness_for_source(
      &tx,
      source_identity.key.selector.as_deref(),
      &resolved_codex_home,
    )
    .map_err(|error| error.to_string())?
  } else {
    Default::default()
  };
  if scan_freshness_preview.recorded
    && scan_freshness_preview.full_scan_required != freshness_full_scan_required
  {
    return Err("Prepared scan freshness changed before commit.".to_string());
  }

  let scan_freshness_start = if track_scan_freshness {
    set_last_scan_started_for_source_in_transaction(
      &tx,
      &scan_started_at,
      source_identity.key.selector.as_deref(),
      &resolved_codex_home,
    )
    .map_err(|error| error.to_string())?
  } else {
    Default::default()
  };

  for failure in parse_failures {
    if failure.mark_token_v2_repair {
      mark_data_repair_file_pending(
        &tx,
        TOKEN_USAGE_MONOTONIC_REPAIR_KEY,
        &failure.source_path,
        &failure.error,
      )
      .map_err(|error| error.to_string())?;
    }
    if failure.mark_fork_replay_v3_repair {
      mark_data_repair_file_pending(
        &tx,
        TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY,
        &failure.source_path,
        &failure.error,
      )
      .map_err(|error| error.to_string())?;
    }
    if failure.mark_rate_limit_repair {
      mark_data_repair_file_pending(
        &tx,
        RATE_LIMIT_SAMPLE_BACKFILL_KEY,
        &failure.source_path,
        &failure.error,
      )
      .map_err(|error| error.to_string())?;
    }
  }

  match storage {
    PreparedStorage::Memory(entries) => {
      for entry in entries {
        commit_one_prepared_session(&tx, entry, &catalog).map_err(|error| error.to_string())?;
      }
    }
    PreparedStorage::Spool { mut file, records } => {
      file
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("Failed to rewind prepared scan spool: {error}"))?;
      let reader = GzDecoder::new(BufReader::new(file));
      let mut stream =
        serde_json::Deserializer::from_reader(reader).into_iter::<SpoolPreparedSession>();
      let mut records_read = 0usize;
      while let Some(entry) = stream.next() {
        let entry =
          entry.map_err(|error| format!("Failed to read prepared scan spool: {error}"))?;
        commit_one_prepared_session(&tx, PreparedSession::from(entry), &catalog)
          .map_err(|error| error.to_string())?;
        records_read += 1;
      }
      drop(stream);
      if records_read != records {
        return Err(format!(
          "Prepared scan spool ended early: expected {records} records, read {records_read}."
        ));
      }
    }
  }

  if effective_kind != ScanKind::Incremental {
    refresh_session_titles(&tx, &titles).map_err(|error| error.to_string())?;
  }
  apply_missing_source_plan(&tx, missing_plan).map_err(|error| error.to_string())?;

  let topology_needs_repair = topology_needs_repair
    || (effective_kind != ScanKind::Incremental
      && conversation_links_need_repair(&tx).map_err(|error| error.to_string())?);
  if topology_dirty || topology_needs_repair {
    recompute_conversation_links(&tx).map_err(|error| error.to_string())?;
  } else if !new_root_session_ids.is_empty() {
    upsert_root_conversation_links(&tx, &new_root_session_ids)
      .map_err(|error| error.to_string())?;
  }

  let missing_sessions = tx
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE source_state = 'missing'",
      [],
      |row| row.get::<_, i64>(0),
    )
    .map_err(|error| error.to_string())? as usize;

  let completed_at = now_utc_string();
  if needs_rate_limit_backfill {
    mark_data_repair_complete(&tx, RATE_LIMIT_SAMPLE_BACKFILL_KEY, &completed_at)
      .map_err(|error| error.to_string())?;
  }
  if needs_token_usage_v2_repair_sweep {
    mark_data_repair_complete(&tx, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, &completed_at)
      .map_err(|error| error.to_string())?;
  }
  if needs_fork_replay_v3_repair_sweep {
    mark_data_repair_complete(&tx, TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY, &completed_at)
      .map_err(|error| error.to_string())?;
  }
  if scan_freshness_start.recorded {
    set_scan_completed_for_source(
      &tx,
      &completed_at,
      source_identity.key.selector.as_deref(),
      &resolved_codex_home,
      effective_kind != ScanKind::Incremental && !skipped_session_files,
      effective_kind != ScanKind::Incremental && skipped_session_files,
    )
    .map_err(|error| error.to_string())?;
  }

  let revision_updated = tx
    .execute(
      "
      UPDATE sync_settings
      SET scan_commit_revision = scan_commit_revision + 1
      WHERE singleton_id = 1 AND scan_commit_revision = ?1
      ",
      params![source_identity.scan_commit_revision],
    )
    .map_err(|error| error.to_string())?;
  if revision_updated != 1 {
    return Err("Prepared scan is stale before commit.".to_string());
  }

  tx.commit().map_err(|error| error.to_string())?;

  Ok(ScanResult {
    codex_home: resolved_codex_home,
    scanned_files: stats.files_visited,
    imported_sessions,
    updated_sessions,
    missing_sessions,
    scan_kind: match effective_kind {
      ScanKind::Full => "full",
      ScanKind::Reconcile => "reconcile",
      ScanKind::Incremental => "incremental",
    }
    .to_string(),
    source_bytes_read: stats.source_bytes_read,
    tail_parsed_files: stats.tail_parsed_files,
    fully_parsed_files: stats.fully_parsed_files,
    last_completed_at: completed_at,
  })
}

fn open_scan_snapshot(db_path: &Path) -> rusqlite::Result<Connection> {
  let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
  conn.busy_timeout(Duration::from_secs(10))?;
  conn.pragma_update(None, "query_only", "ON")?;
  Ok(conn)
}

#[cfg(test)]
fn load_preparation_database_snapshot(
  db_path: &Path,
  codex_home_override: Option<&str>,
  requested_kind: ScanKind,
) -> rusqlite::Result<PreparationDatabaseSnapshot> {
  let mut conn = open_scan_snapshot(db_path)?;
  load_preparation_database_snapshot_from_connection(
    &mut conn,
    codex_home_override,
    requested_kind,
  )
}

fn load_preparation_database_snapshot_from_connection(
  conn: &mut Connection,
  codex_home_override: Option<&str>,
  requested_kind: ScanKind,
) -> rusqlite::Result<PreparationDatabaseSnapshot> {
  let tx = conn.transaction()?;
  let (
    scan_source_selector,
    scan_commit_revision,
    last_scan_codex_home,
    last_scan_started_at,
    last_scan_completed_at,
    last_full_scan_completed_at,
  ): (
    Option<String>,
    i64,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
  ) = tx.query_row(
    "
    SELECT codex_home, scan_commit_revision, last_scan_codex_home,
           last_scan_started_at, last_scan_completed_at, last_full_scan_completed_at
    FROM sync_settings
    WHERE singleton_id = 1
    ",
    [],
    |row| {
      Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
      ))
    },
  )?;
  let needs_rate_limit_backfill = needs_rate_limit_sample_backfill(&tx)?;
  let pending_rate_limit_repair_paths =
    load_pending_data_repair_paths(&tx, RATE_LIMIT_SAMPLE_BACKFILL_KEY)?;
  let needs_token_usage_v2_repair_sweep =
    data_repair_is_pending(&tx, TOKEN_USAGE_MONOTONIC_REPAIR_KEY)?;
  let pending_token_v2_repair_paths =
    load_pending_data_repair_paths(&tx, TOKEN_USAGE_MONOTONIC_REPAIR_KEY)?;
  let needs_fork_replay_v3_repair_sweep =
    data_repair_is_pending(&tx, TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY)?;
  let pending_fork_replay_v3_repair_paths =
    load_pending_data_repair_paths(&tx, TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY)?;
  let mut pending_repair_paths = pending_rate_limit_repair_paths.clone();
  pending_repair_paths.extend(pending_token_v2_repair_paths.iter().cloned());
  pending_repair_paths.extend(pending_fork_replay_v3_repair_paths.iter().cloned());
  let import_state_is_empty = tx.query_row(
    "SELECT NOT EXISTS (SELECT 1 FROM import_state LIMIT 1)",
    [],
    |row| Ok(row.get::<_, i64>(0)? != 0),
  )?;
  let home_dir = dirs::home_dir();
  let resolved_requested_home = resolve_codex_home(
    scan_source_selector.as_deref(),
    codex_home_override.map(ToString::to_string),
    home_dir.as_deref(),
  )
  .and_then(|path| expand_home_prefix(path, home_dir.as_deref()));
  let use_incremental_snapshot = requested_kind == ScanKind::Incremental
    && !import_state_is_empty
    && !needs_rate_limit_backfill
    && !needs_token_usage_v2_repair_sweep
    && !needs_fork_replay_v3_repair_sweep
    && last_full_scan_completed_at.is_some()
    && resolved_requested_home.as_ref().is_ok_and(|path| {
      last_scan_codex_home.as_deref() == Some(path.to_string_lossy().as_ref())
    });
  let import_state = if use_incremental_snapshot {
    load_incremental_import_state(&tx, &pending_repair_paths)?
  } else {
    load_import_state(&tx)?
  };
  let session_source_paths = if use_incremental_snapshot {
    import_state
      .values()
      .filter_map(|state| {
        state
          .session_id
          .as_ref()
          .map(|session_id| (session_id.clone(), PathBuf::from(&state.source_path)))
      })
      .collect()
  } else {
    load_session_source_paths(&tx, &import_state, &[])?
  };
  let existing_relations = if use_incremental_snapshot {
    load_incremental_session_relations(&tx, &import_state)?
  } else {
    load_existing_session_relations(&tx)?
  };
  let existing_session_sources = if use_incremental_snapshot {
    load_incremental_session_sources(&tx, &import_state)?
  } else {
    {
      let mut stmt = tx.prepare(
      "
      SELECT session_id, source_path, source_state, source_bucket
      FROM sessions
      WHERE source_path IS NOT NULL
      ",
      )?;
      let sources = stmt
        .query_map([], existing_session_source_from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
      sources
    }
  };
  let topology_needs_repair =
    !use_incremental_snapshot && conversation_links_need_repair(&tx)?;
  tx.commit()?;

  Ok(PreparationDatabaseSnapshot {
    scan_source_selector,
    scan_commit_revision,
    last_scan_codex_home,
    last_scan_started_at,
    last_scan_completed_at,
    last_full_scan_completed_at,
    import_state,
    needs_rate_limit_backfill,
    pending_rate_limit_repair_paths,
    needs_token_usage_v2_repair_sweep,
    pending_token_v2_repair_paths,
    needs_fork_replay_v3_repair_sweep,
    pending_fork_replay_v3_repair_paths,
    session_source_paths,
    existing_relations,
    existing_session_sources,
    topology_needs_repair,
  })
}

fn validate_prepared_source_identity(
  conn: &Connection,
  prepared: &PreparedSourceIdentity,
) -> Result<(), String> {
  let (
    selector,
    scan_commit_revision,
    last_scan_codex_home,
    last_scan_started_at,
    last_scan_completed_at,
    last_full_scan_completed_at,
  ): (
    Option<String>,
    i64,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
  ) = conn
    .query_row(
      "
      SELECT codex_home, scan_commit_revision, last_scan_codex_home,
             last_scan_started_at, last_scan_completed_at, last_full_scan_completed_at
      FROM sync_settings
      WHERE singleton_id = 1
      ",
      [],
      |row| {
        Ok((
          row.get(0)?,
          row.get(1)?,
          row.get(2)?,
          row.get(3)?,
          row.get(4)?,
          row.get(5)?,
        ))
      },
    )
    .map_err(|error| error.to_string())?;
  let home_dir = dirs::home_dir();
  let configured_home = resolve_codex_home(selector.as_deref(), None, home_dir.as_deref())
    .and_then(|path| expand_home_prefix(path, home_dir.as_deref()))
    .ok();

  if selector != prepared.key.selector
    || scan_commit_revision != prepared.scan_commit_revision
    || prepared
      .tracked_configured_home
      .as_ref()
      .is_some_and(|prepared_home| Some(prepared_home) != configured_home.as_ref())
    || last_scan_codex_home != prepared.last_scan_codex_home
    || last_scan_started_at != prepared.last_scan_started_at
    || last_scan_completed_at != prepared.last_scan_completed_at
    || last_full_scan_completed_at != prepared.last_full_scan_completed_at
  {
    return Err("Prepared scan source changed before commit.".to_string());
  }
  Ok(())
}

fn prepare_missing_source_plan(
  existing_sources: &[ExistingSessionSource],
  import_state: &HashMap<String, ImportState>,
  present_paths: &HashSet<String>,
  scan_kind: ScanKind,
  reconcile_existing_absent_sources: bool,
) -> MissingSourcePlan {
  let mut plan = MissingSourcePlan::default();

  match scan_kind {
    ScanKind::Full | ScanKind::Reconcile => {
      for source in existing_sources {
        if !present_paths.contains(&source.source_path)
          && (reconcile_existing_absent_sources || !Path::new(&source.source_path).exists())
        {
          plan.sessions_to_mark_missing.push(MissingSessionPlan {
            session_id: source.session_id.clone(),
            expected_source_path: source.source_path.clone(),
          });
        }
      }
      for source_path in import_state.keys() {
        if !present_paths.contains(source_path)
          && (reconcile_existing_absent_sources || !Path::new(source_path).exists())
        {
          plan.import_state_paths_to_delete.push(source_path.clone());
        }
      }
    }
    ScanKind::Incremental => {
      for source in existing_sources {
        if source.source_state == "active"
          && source.source_bucket.as_deref() == Some("active")
          && !present_paths.contains(&source.source_path)
          && !Path::new(&source.source_path).exists()
        {
          plan.sessions_to_mark_missing.push(MissingSessionPlan {
            session_id: source.session_id.clone(),
            expected_source_path: source.source_path.clone(),
          });
          plan
            .import_state_paths_to_delete
            .push(source.source_path.clone());
        }
      }
    }
  }

  plan
}

fn apply_missing_source_plan(conn: &Connection, plan: MissingSourcePlan) -> rusqlite::Result<()> {
  let imported_at = now_utc_string();
  for missing in plan.sessions_to_mark_missing {
    conn.execute(
      "
      UPDATE sessions
      SET source_state = 'missing', imported_at = ?1
      WHERE session_id = ?2 AND source_path = ?3
      ",
      params![
        imported_at,
        missing.session_id,
        missing.expected_source_path
      ],
    )?;
  }
  for source_path in plan.import_state_paths_to_delete {
    conn.execute(
      "DELETE FROM import_state WHERE source_path = ?1",
      params![source_path],
    )?;
  }
  Ok(())
}

fn commit_one_prepared_session(
  conn: &Connection,
  entry: PreparedSession,
  catalog: &HashMap<String, crate::models::PricingCatalogEntry>,
) -> rusqlite::Result<()> {
  let PreparedSession {
    session_file,
    parsed,
    file_needs_rate_limit_repair,
    file_needs_token_v2_repair,
    file_needs_fork_replay_v3_repair,
    replay_parent_unavailable,
    related_pending_token_v2_paths,
    related_pending_fork_replay_v3_paths,
  } = entry;
  let source_path = &session_file.source_path;

  persist_session(conn, &session_file, &parsed, catalog)?;
  if file_needs_rate_limit_repair {
    clear_pending_data_repair_file(conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY, source_path)?;
  }
  if file_needs_token_v2_repair {
    clear_pending_data_repair_file(conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, source_path)?;
    for related_source_path in related_pending_token_v2_paths {
      clear_pending_data_repair_file(conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, &related_source_path)?;
    }
  }
  if file_needs_fork_replay_v3_repair {
    if replay_parent_unavailable {
      mark_data_repair_file_pending(
        conn,
        TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY,
        source_path,
        "fork replay parent unavailable",
      )?;
    } else {
      clear_pending_data_repair_file(conn, TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY, source_path)?;
      for related_source_path in related_pending_fork_replay_v3_paths {
        clear_pending_data_repair_file(
          conn,
          TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY,
          &related_source_path,
        )?;
      }
    }
  }

  Ok(())
}

fn effective_scan_scope(
  requested_scope: ScanKind,
  import_state_is_empty: bool,
  needs_rate_limit_backfill: bool,
  needs_token_usage_repair_sweep: bool,
  resolved_source_requires_full_scan: bool,
) -> ScanKind {
  if requested_scope == ScanKind::Full
    || import_state_is_empty
    || needs_rate_limit_backfill
    || needs_token_usage_repair_sweep
    || resolved_source_requires_full_scan
  {
    ScanKind::Full
  } else {
    requested_scope
  }
}

fn import_state_session_id_mismatch(state: &ImportState, session_file: &SessionFile) -> bool {
  let Some(expected_session_id) = fallback_session_id_from_filename(&session_file.path) else {
    return false;
  };
  state
    .session_id
    .as_deref()
    .map(|session_id| session_id != expected_session_id)
    .unwrap_or(false)
}

pub fn recalculate_session_values(conn: &Connection, session_id: &str) -> rusqlite::Result<()> {
  let catalog = load_catalog_map(conn)?;

  let mut stmt = conn.prepare(
    "
    SELECT id, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens
    FROM usage_events
    WHERE session_id = ?1
    ORDER BY timestamp ASC, id ASC
    ",
  )?;

  let events = stmt.query_map(params![session_id], |row| {
    Ok((
      row.get::<_, i64>(0)?,
      row.get::<_, String>(1)?,
      TokenUsage {
        input_tokens: row.get(2)?,
        cached_input_tokens: row.get(3)?,
        output_tokens: row.get(4)?,
        reasoning_output_tokens: row.get(5)?,
        total_tokens: row.get(6)?,
      },
    ))
  })?;

  for item in events {
    let (id, model_id, usage) = item?;
    let value_usd = calculate_value_usd(&usage, resolve_pricing(&catalog, &model_id).as_ref());
    conn.execute(
      "
      UPDATE usage_events
      SET value_usd = ?1, fast_mode_auto = 0, fast_mode_effective = 0
      WHERE id = ?2
      ",
      params![value_usd, id],
    )?;
  }

  Ok(())
}

fn classify_topology_maintenance(
  existing_relation: Option<&ExistingSessionRelation>,
  existing_child_count: usize,
  parent_session_id: Option<&str>,
) -> TopologyMaintenance {
  match (
    existing_relation.filter(|item| item.exists),
    parent_session_id,
  ) {
    (Some(existing_relation), next_parent_session_id) => {
      if existing_relation.parent_session_id.as_deref() == next_parent_session_id {
        TopologyMaintenance::None
      } else {
        TopologyMaintenance::RecomputeAll
      }
    }
    (None, Some(_)) => TopologyMaintenance::RecomputeAll,
    (None, None) => {
      if existing_child_count > 0 {
        TopologyMaintenance::RecomputeAll
      } else {
        TopologyMaintenance::InsertRootLink
      }
    }
  }
}

pub fn recalculate_all_session_values(conn: &Connection) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare("SELECT session_id FROM sessions ORDER BY session_id")?;
  let session_ids = stmt
    .query_map([], |row| row.get::<_, String>(0))?
    .collect::<rusqlite::Result<Vec<_>>>()?;

  for session_id in session_ids {
    recalculate_session_values(conn, &session_id)?;
  }

  Ok(())
}

fn resolve_codex_home(
  persisted_codex_home: Option<&str>,
  override_value: Option<String>,
  home_dir: Option<&Path>,
) -> Result<PathBuf, String> {
  if let Some(path) = override_value {
    return Ok(PathBuf::from(path));
  }

  if let Some(path) = persisted_codex_home {
    if !path.trim().is_empty() {
      return Ok(PathBuf::from(path));
    }
  }

  if let Ok(path) = std::env::var("CODEX_HOME") {
    if !path.trim().is_empty() {
      return Ok(PathBuf::from(path));
    }
  }

  let Some(home_dir) = home_dir else {
    return Err("Unable to resolve home directory for CODEX_HOME fallback.".to_string());
  };

  Ok(home_dir.join(".codex"))
}

fn freshness_source_matches(
  persisted_codex_home: Option<&str>,
  scanned_codex_home: &Path,
  home_dir: Option<&Path>,
) -> bool {
  resolve_codex_home(persisted_codex_home, None, home_dir)
    .and_then(|path| expand_home_prefix(path, home_dir))
    .map(|path| path == scanned_codex_home)
    .unwrap_or(false)
}

fn validate_codex_home(path: PathBuf, home_dir: Option<&Path>) -> Result<PathBuf, String> {
  let expanded = expand_home_prefix(path, home_dir)?;
  if !expanded.is_dir() {
    return Err(format!(
      "Codex home is not an existing directory: {}",
      expanded.display()
    ));
  }
  Ok(expanded)
}

fn expand_home_prefix(path: PathBuf, home_dir: Option<&Path>) -> Result<PathBuf, String> {
  let Ok(suffix) = path.strip_prefix(Path::new("~")) else {
    return Ok(path);
  };
  let Some(home_dir) = home_dir else {
    return Err(format!(
      "Unable to resolve home directory for Codex home path: {}",
      path.display()
    ));
  };
  Ok(home_dir.join(suffix))
}

fn load_session_index(codex_home: &Path) -> HashMap<String, String> {
  let mut titles = HashMap::new();
  let path = codex_home.join("session_index.jsonl");
  let Ok(file) = File::open(path) else {
    return titles;
  };

  for line in BufReader::new(file).lines().map_while(Result::ok) {
    let Ok(value) = serde_json::from_str::<Value>(&line) else {
      continue;
    };
    let Some(id) = value.get("id").and_then(Value::as_str) else {
      continue;
    };
    let title = value
      .get("thread_name")
      .and_then(Value::as_str)
      .unwrap_or("")
      .trim()
      .to_string();
    if !title.is_empty() {
      titles.insert(id.to_string(), title);
    }
  }

  titles
}

fn refresh_session_titles(
  conn: &Connection,
  titles: &HashMap<String, String>,
) -> rusqlite::Result<()> {
  for (session_id, title) in titles {
    conn.execute(
      "UPDATE sessions SET title = ?1 WHERE session_id = ?2",
      params![title, session_id],
    )?;
  }
  Ok(())
}

fn collect_session_files(codex_home: &Path) -> Vec<SessionFile> {
  let mut files = Vec::new();
  for (folder_name, bucket) in [("sessions", "active"), ("archived_sessions", "archived")] {
    let base = codex_home.join(folder_name);
    if !base.exists() {
      continue;
    }
    for entry in WalkDir::new(base).into_iter().filter_map(Result::ok) {
      if let Some(session_file) = session_file_from_path(entry.path().to_path_buf(), bucket) {
        files.push(session_file);
      }
    }
  }
  files.sort_by(|left, right| left.path.cmp(&right.path));
  files
}

fn collect_recent_active_session_files(codex_home: &Path) -> Vec<SessionFile> {
  let sessions_root = codex_home.join("sessions");
  let mut files = Vec::new();
  let mut collect_directory = |directory: &Path| {
    let Ok(entries) = std::fs::read_dir(directory) else {
      return;
    };
    for entry in entries.filter_map(Result::ok) {
      if let Some(session_file) = session_file_from_path(entry.path(), "active") {
        files.push(session_file);
      }
    }
  };

  // Legacy clients may place session files directly under `sessions`.
  collect_directory(&sessions_root);
  let today = Local::now().date_naive();
  for days_ago in 0..=2 {
    let date = today - chrono::Duration::days(days_ago);
    collect_directory(
      &sessions_root
        .join(date.format("%Y").to_string())
        .join(date.format("%m").to_string())
        .join(date.format("%d").to_string()),
    );
  }
  files.sort_by(|left, right| left.path.cmp(&right.path));
  files
}

fn collect_incremental_session_files(
  codex_home: &Path,
  import_state: &HashMap<String, ImportState>,
  pending_repair_session_ids: &HashSet<String>,
  pending_repair_paths: &HashSet<String>,
) -> (Vec<SessionFile>, HashSet<String>) {
  let mut files = collect_recent_active_session_files(codex_home);
  let mut collected_paths = files
    .iter()
    .map(|session_file| session_file.path.to_string_lossy().to_string())
    .collect::<HashSet<_>>();
  let mut active_paths_kept_for_archive_retry = HashSet::new();

  for state in import_state.values().filter(|state| state.source_bucket == "active") {
    if collected_paths.contains(&state.source_path) {
      continue;
    }
    let Some(session_file) = session_file_from_path(PathBuf::from(&state.source_path), "active") else {
      continue;
    };
    collected_paths.insert(state.source_path.clone());
    files.push(session_file);
  }

  let active_root = codex_home.join("sessions");
  let archived_root = codex_home.join("archived_sessions");
  for source_path in pending_repair_paths {
    if collected_paths.contains(source_path) {
      continue;
    }
    let path = PathBuf::from(source_path);
    let bucket = if path.starts_with(&archived_root) {
      "archived"
    } else if path.starts_with(&active_root) {
      "active"
    } else {
      continue;
    };
    let Some(session_file) = session_file_from_path(path, bucket) else {
      continue;
    };
    collected_paths.insert(source_path.clone());
    files.push(session_file);
  }

  for state in import_state.values() {
    if state.source_bucket == "archived" {
      let session_has_pending_repair = state
        .session_id
        .as_ref()
        .is_some_and(|session_id| pending_repair_session_ids.contains(session_id));
      let needs_tail_retry = state
        .parser_checkpoint
        .as_ref()
        .is_some_and(|checkpoint| checkpoint.completed_offset < state.file_size.max(0) as u64);
      if !session_has_pending_repair
        && !pending_repair_paths.contains(&state.source_path)
        && !needs_tail_retry
      {
        continue;
      }
      let Some(session_file) =
        session_file_from_path(PathBuf::from(&state.source_path), "archived")
      else {
        continue;
      };
      if state.file_size == session_file.file_size
        && state.file_mtime_ms == session_file.file_mtime_ms
        && !session_has_pending_repair
      {
        continue;
      }
      if collected_paths.insert(session_file.path.to_string_lossy().to_string()) {
        files.push(session_file);
      }
      continue;
    }
    if state.source_bucket != "active" || collected_paths.contains(&state.source_path) {
      continue;
    }
    let Some(filename) = Path::new(&state.source_path).file_name() else {
      continue;
    };
    let archived_path = codex_home.join("archived_sessions").join(filename);
    let Some(session_file) = session_file_from_path(archived_path, "archived") else {
      continue;
    };
    active_paths_kept_for_archive_retry.insert(state.source_path.clone());
    if collected_paths.insert(session_file.path.to_string_lossy().to_string()) {
      files.push(session_file);
    }
  }

  files.sort_by(|left, right| left.path.cmp(&right.path));
  (files, active_paths_kept_for_archive_retry)
}

fn session_file_from_path(path: PathBuf, bucket: &str) -> Option<SessionFile> {
  if path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
    return None;
  }

  let metadata = std::fs::metadata(&path).ok()?;
  if !metadata.is_file() {
    return None;
  }

  let file_size = metadata.len() as i64;
  let file_mtime_ms = metadata
    .modified()
    .ok()
    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
    .map(|duration| duration.as_millis() as i64)
    .unwrap_or_default();

  Some(SessionFile {
    path,
    bucket: bucket.to_string(),
    file_size,
    file_mtime_ms,
  })
}

fn parser_checkpoint_prefix_matches(state: &ImportState, session_file: &SessionFile) -> bool {
  let Some(checkpoint) = state.parser_checkpoint.as_ref() else {
    return false;
  };
  checkpoint.completed_offset == session_file.file_size.max(0) as u64
    && read_prefix_signature(&session_file.path, checkpoint.completed_offset)
      .is_ok_and(|signature| signature == checkpoint.prefix_signature)
}

fn parse_session_file_counted(
  session_file: &SessionFile,
  titles: &HashMap<String, String>,
) -> Result<(ParsedSession, u64), (String, u64)> {
  parse_session_file_once(session_file, titles).map_err(|error| match error {
    SessionParseError::Fatal {
      message,
      bytes_read,
    } => (message, bytes_read),
  })
}

fn try_parse_session_tail_counted(
  session_file: &SessionFile,
  state: &ImportState,
  titles: &HashMap<String, String>,
  existing_relation: Option<&ExistingSessionRelation>,
) -> Result<Option<(ParsedSession, u64)>, (String, u64)> {
  let Some(session_id) = state.session_id.as_ref() else {
    return Ok(None);
  };
  let Some(checkpoint) = state.parser_checkpoint.as_ref() else {
    return Ok(None);
  };
  if state.source_bucket != "active"
    || session_file.bucket != "active"
    || session_file.file_size <= state.file_size
    || checkpoint.completed_offset > session_file.file_size.max(0) as u64
    || import_state_session_id_mismatch(state, session_file)
  {
    return Ok(None);
  }
  let current_signature = read_prefix_signature(&session_file.path, checkpoint.completed_offset)
    .map_err(|error| {
      (
        format!(
          "Failed to validate parser checkpoint for {}: {error}",
          session_file.path.display()
        ),
        0,
      )
    })?;
  if current_signature != checkpoint.prefix_signature {
    return Ok(None);
  }

  let mut file = File::open(&session_file.path).map_err(|error| {
    (
      format!("Failed to open {}: {error}", session_file.path.display()),
      0,
    )
  })?;
  file
    .seek(SeekFrom::Start(checkpoint.completed_offset))
    .map_err(|error| {
      (
        format!(
          "Failed to seek {} to parser checkpoint: {error}",
          session_file.path.display()
        ),
        0,
      )
    })?;
  let mut reader = BufReader::new(CountingReader::new(file));
  let mut completed_offset = checkpoint.completed_offset;
  let mut current_model = checkpoint.current_model.clone();
  let mut explicit_fast_mode = checkpoint.explicit_fast_mode;
  let mut latest_plan_type = checkpoint.latest_plan_type.clone();
  let mut updated_at = None;
  let mut snapshots = Vec::new();
  let mut rate_limit_samples = Vec::new();
  let mut seen_models = HashSet::new();
  if let Some(model) = current_model.as_ref() {
    seen_models.insert(model.clone());
  }

  let mut line = String::new();
  loop {
    line.clear();
    let line_bytes = reader.read_line(&mut line).map_err(|error| {
      (
        format!("Failed to read {}: {error}", session_file.path.display()),
        reader.get_ref().bytes_read,
      )
    })?;
    if line_bytes == 0 {
      break;
    }
    let has_trailing_newline = line.ends_with('\n');
    let value = match serde_json::from_str::<Value>(&line) {
      Ok(value) => value,
      Err(_) if !has_trailing_newline => break,
      Err(_) => {
        completed_offset = completed_offset.saturating_add(line_bytes as u64);
        continue;
      }
    };
    completed_offset = completed_offset.saturating_add(line_bytes as u64);
    if line.contains("\"fast_mode\":true") || line.contains("\"quick_mode\":true") {
      explicit_fast_mode = Some(true);
    }
    if line.contains("\"fast_mode\":false") || line.contains("\"quick_mode\":false") {
      explicit_fast_mode = Some(false);
    }
    let timestamp = value
      .get("timestamp")
      .and_then(Value::as_str)
      .map(ToString::to_string);
    if timestamp.is_some() {
      updated_at = timestamp.clone();
    }
    match value
      .get("type")
      .and_then(Value::as_str)
      .unwrap_or_default()
    {
      "session_meta" => return Ok(None),
      "turn_context" => {
        if let Some(model) = value
          .get("payload")
          .and_then(|payload| payload.get("model"))
          .and_then(Value::as_str)
        {
          let model = normalize_model_id(model);
          seen_models.insert(model.clone());
          current_model = Some(model);
        }
      }
      "event_msg" => {
        let payload = value.get("payload").unwrap_or(&Value::Null);
        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
          continue;
        }
        let info = payload.get("info").unwrap_or(&Value::Null);
        let total_usage = info.get("total_token_usage").unwrap_or(&Value::Null);
        if total_usage.is_null() {
          continue;
        }
        let usage = TokenUsage {
          input_tokens: read_i64(total_usage, "input_tokens"),
          cached_input_tokens: read_i64(total_usage, "cached_input_tokens"),
          output_tokens: read_i64(total_usage, "output_tokens"),
          reasoning_output_tokens: read_i64(total_usage, "reasoning_output_tokens"),
          total_tokens: read_total_tokens(total_usage),
        };
        let last_token_usage = info
          .get("last_token_usage")
          .filter(|last_usage| !last_usage.is_null())
          .map(|last_usage| TokenUsage {
            input_tokens: read_i64(last_usage, "input_tokens"),
            cached_input_tokens: read_i64(last_usage, "cached_input_tokens"),
            output_tokens: read_i64(last_usage, "output_tokens"),
            reasoning_output_tokens: read_i64(last_usage, "reasoning_output_tokens"),
            total_tokens: read_total_tokens(last_usage),
          });
        let plan_type = payload
          .get("rate_limits")
          .and_then(|rate_limits| rate_limits.get("plan_type"))
          .and_then(Value::as_str)
          .map(ToString::to_string);
        if plan_type.is_some() {
          latest_plan_type = plan_type.clone();
        }
        let limit_id = nested_str(payload, &["rate_limits", "limit_id"])
          .or_else(|| nested_str(payload, &["rate_limits", "primary", "limit_id"]));
        let limit_name = nested_str(payload, &["rate_limits", "limit_name"])
          .or_else(|| nested_str(payload, &["rate_limits", "primary", "limit_name"]));
        let sample_timestamp = timestamp.unwrap_or_else(now_utc_string);
        rate_limit_samples.extend(extract_rate_limit_samples(&sample_timestamp, payload));
        let model_id = current_model
          .clone()
          .unwrap_or_else(|| "unknown".to_string());
        seen_models.insert(model_id.clone());
        snapshots.push(UsageSnapshot {
          timestamp: sample_timestamp,
          model_id,
          usage,
          last_token_usage,
          plan_type,
          limit_id,
          limit_name,
          explicit_fast_mode,
        });
      }
      _ => {}
    }
  }
  let bytes_read = reader.get_ref().bytes_read;
  for sample in &mut rate_limit_samples {
    sample.source_session_id = Some(session_id.clone());
  }
  let new_checkpoint = ParserCheckpoint {
    completed_offset,
    prefix_signature: read_prefix_signature(&session_file.path, completed_offset).map_err(
      |error| {
        (
          format!(
            "Failed to checkpoint {}: {error}",
            session_file.path.display()
          ),
          bytes_read,
        )
      },
    )?,
    last_usage: monotonic_usage_high_water(checkpoint.last_usage.clone(), &snapshots),
    current_model: current_model.clone(),
    explicit_fast_mode,
    latest_plan_type: latest_plan_type.clone(),
  };
  let parent_session_id = existing_relation.and_then(|relation| relation.parent_session_id.clone());
  Ok(Some((
    ParsedSession {
      raw_session: RawSession {
        session_id: session_id.clone(),
        parent_session_id,
        root_session_id: session_id.clone(),
        title: titles.get(session_id).cloned(),
        source_state: session_file.bucket.clone(),
        source_path: Some(session_file.path.to_string_lossy().to_string()),
        started_at: None,
        updated_at,
        model_ids: seen_models.into_iter().collect(),
        contains_subagents: false,
        agent_nickname: None,
        agent_role: None,
      },
      snapshots,
      rate_limit_samples,
      explicit_forked_from_id: None,
      explicit_fork_timestamp: None,
      inherited_token_snapshot_cutoff: 0,
      explicit_fast_mode,
      latest_plan_type,
      last_model_id: current_model.or_else(|| Some("unknown".to_string())),
      mode: ParsedSessionMode::Tail {
        previous_usage: checkpoint.last_usage.clone(),
      },
      checkpoint: new_checkpoint,
    },
    bytes_read,
  )))
}

#[cfg(test)]
fn parse_session_file(
  session_file: &SessionFile,
  titles: &HashMap<String, String>,
) -> Result<ParsedSession, String> {
  parse_session_file_counted(session_file, titles)
    .map(|(parsed, _)| parsed)
    .map_err(|(error, _)| error)
}

fn parse_session_file_once(
  session_file: &SessionFile,
  titles: &HashMap<String, String>,
) -> Result<(ParsedSession, u64), SessionParseError> {
  let file = File::open(&session_file.path).map_err(|error| SessionParseError::Fatal {
    message: format!("Failed to open {}: {error}", session_file.path.display()),
    bytes_read: 0,
  })?;
  let mut reader = BufReader::new(CountingReader::new(file));
  let expected_session_id = fallback_session_id_from_filename(&session_file.path);

  let mut session_id = String::new();
  let mut parent_session_id: Option<String> = None;
  let mut started_at: Option<String> = None;
  let mut updated_at: Option<String> = None;
  let mut current_model: Option<String> = None;
  let mut agent_nickname: Option<String> = None;
  let mut agent_role: Option<String> = None;
  let mut explicit_forked_from_id: Option<String> = None;
  let mut explicit_fork_timestamp: Option<DateTime<FixedOffset>> = None;
  let mut explicit_fast_mode: Option<bool> = None;
  let mut latest_plan_type: Option<String> = None;
  let mut snapshots = Vec::new();
  let mut rate_limit_samples = Vec::new();
  let mut seen_models = HashSet::new();
  let mut first_session_meta: Option<SessionMetaCandidate> = None;
  let mut matching_session_meta: Option<SessionMetaCandidate> = None;
  let mut completed_offset = 0u64;

  let mut line = String::new();
  loop {
    line.clear();
    let line_bytes = reader
      .read_line(&mut line)
      .map_err(|error| SessionParseError::Fatal {
        message: format!("Failed to read {}: {error}", session_file.path.display()),
        bytes_read: reader.get_ref().bytes_read,
      })?;
    if line_bytes == 0 {
      break;
    }
    let has_trailing_newline = line.ends_with('\n');
    let value = match serde_json::from_str::<Value>(&line) {
      Ok(value) => value,
      Err(_) if !has_trailing_newline => break,
      Err(_) => {
        completed_offset = completed_offset.saturating_add(line_bytes as u64);
        continue;
      }
    };
    completed_offset = completed_offset.saturating_add(line_bytes as u64);
    if line.contains("\"fast_mode\":true") || line.contains("\"quick_mode\":true") {
      explicit_fast_mode = Some(true);
    }
    if line.contains("\"fast_mode\":false") || line.contains("\"quick_mode\":false") {
      explicit_fast_mode = Some(false);
    }

    if session_id.is_empty() {
      if let Some(id) = value.get("id").and_then(Value::as_str) {
        session_id = id.to_string();
      }
    }

    let timestamp = value
      .get("timestamp")
      .and_then(Value::as_str)
      .map(ToString::to_string);

    if started_at.is_none() {
      started_at = timestamp.clone();
    }
    if timestamp.is_some() {
      updated_at = timestamp.clone();
    }

    match value
      .get("type")
      .and_then(Value::as_str)
      .unwrap_or_default()
    {
      "session_meta" => {
        let payload = value.get("payload").unwrap_or(&Value::Null);
        let candidate_explicit_forked_from_id = payload
          .get("forked_from_id")
          .and_then(Value::as_str)
          .map(ToString::to_string);
        let parent = candidate_explicit_forked_from_id.clone().or_else(|| {
          payload
            .get("source")
            .and_then(|source| source.get("subagent"))
            .and_then(|subagent| subagent.get("thread_spawn"))
            .and_then(|thread_spawn| thread_spawn.get("parent_thread_id"))
            .and_then(Value::as_str)
            .map(ToString::to_string)
        });
        let candidate_explicit_fork_timestamp = candidate_explicit_forked_from_id
          .as_ref()
          .and_then(|_| timestamp.as_deref())
          .and_then(|timestamp| DateTime::parse_from_rfc3339(timestamp).ok());

        let nickname = payload
          .get("agent_nickname")
          .and_then(Value::as_str)
          .map(ToString::to_string)
          .or_else(|| {
            payload
              .get("source")
              .and_then(|source| source.get("subagent"))
              .and_then(|subagent| subagent.get("thread_spawn"))
              .and_then(|thread_spawn| thread_spawn.get("agent_nickname"))
              .and_then(Value::as_str)
              .map(ToString::to_string)
          });

        let role = payload
          .get("agent_role")
          .and_then(Value::as_str)
          .map(ToString::to_string)
          .or_else(|| {
            payload
              .get("source")
              .and_then(|source| source.get("subagent"))
              .and_then(|subagent| subagent.get("thread_spawn"))
              .and_then(|thread_spawn| thread_spawn.get("agent_role"))
              .and_then(Value::as_str)
              .map(ToString::to_string)
          });

        if let Some(id) = payload.get("id").and_then(Value::as_str) {
          let candidate = SessionMetaCandidate {
            session_id: id.to_string(),
            parent_session_id: parent,
            explicit_forked_from_id: candidate_explicit_forked_from_id,
            explicit_fork_timestamp: candidate_explicit_fork_timestamp,
            agent_nickname: nickname,
            agent_role: role,
          };

          if first_session_meta.is_none() {
            first_session_meta = Some(candidate.clone());
          }

          if expected_session_id.as_deref() == Some(id) {
            matching_session_meta = Some(candidate);
          }
        }
      }
      "turn_context" => {
        if let Some(model) = value
          .get("payload")
          .and_then(|payload| payload.get("model"))
          .and_then(Value::as_str)
        {
          let model = normalize_model_id(model);
          seen_models.insert(model.clone());
          current_model = Some(model);
        }
      }
      "event_msg" => {
        let payload = value.get("payload").unwrap_or(&Value::Null);
        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
          continue;
        }

        let info = payload.get("info").unwrap_or(&Value::Null);
        let total_usage = info.get("total_token_usage").unwrap_or(&Value::Null);
        if total_usage.is_null() {
          continue;
        }

        let usage = TokenUsage {
          input_tokens: read_i64(total_usage, "input_tokens"),
          cached_input_tokens: read_i64(total_usage, "cached_input_tokens"),
          output_tokens: read_i64(total_usage, "output_tokens"),
          reasoning_output_tokens: read_i64(total_usage, "reasoning_output_tokens"),
          total_tokens: read_total_tokens(total_usage),
        };
        let last_token_usage = info
          .get("last_token_usage")
          .filter(|last_usage| !last_usage.is_null())
          .map(|last_usage| TokenUsage {
            input_tokens: read_i64(last_usage, "input_tokens"),
            cached_input_tokens: read_i64(last_usage, "cached_input_tokens"),
            output_tokens: read_i64(last_usage, "output_tokens"),
            reasoning_output_tokens: read_i64(last_usage, "reasoning_output_tokens"),
            total_tokens: read_total_tokens(last_usage),
          });

        let plan_type = payload
          .get("rate_limits")
          .and_then(|rate_limits| rate_limits.get("plan_type"))
          .and_then(Value::as_str)
          .map(ToString::to_string);
        if plan_type.is_some() {
          latest_plan_type = plan_type.clone();
        }

        let limit_id = nested_str(payload, &["rate_limits", "limit_id"])
          .or_else(|| nested_str(payload, &["rate_limits", "primary", "limit_id"]));
        let limit_name = nested_str(payload, &["rate_limits", "limit_name"])
          .or_else(|| nested_str(payload, &["rate_limits", "primary", "limit_name"]));
        let sample_timestamp = timestamp.unwrap_or_else(now_utc_string);
        rate_limit_samples.extend(extract_rate_limit_samples(&sample_timestamp, payload));

        let model_id = current_model
          .clone()
          .unwrap_or_else(|| "unknown".to_string());
        seen_models.insert(model_id.clone());

        snapshots.push(UsageSnapshot {
          timestamp: sample_timestamp,
          model_id,
          usage,
          last_token_usage,
          plan_type,
          limit_id,
          limit_name,
          explicit_fast_mode,
        });
      }
      _ => {}
    }
  }

  let bytes_read = reader.get_ref().bytes_read;
  if let Some(candidate) = matching_session_meta.or(first_session_meta) {
    session_id = candidate.session_id;
    parent_session_id = candidate.parent_session_id.or(parent_session_id);
    explicit_forked_from_id = candidate.explicit_forked_from_id;
    explicit_fork_timestamp = candidate.explicit_fork_timestamp;
    agent_nickname = candidate.agent_nickname.or(agent_nickname);
    agent_role = candidate.agent_role.or(agent_role);
  }

  if session_id.is_empty() {
    if let Some(fallback) = fallback_session_id_from_filename(&session_file.path) {
      session_id = fallback;
    }
  }

  if session_id.is_empty() {
    return Err(SessionParseError::Fatal {
      message: format!(
        "Could not determine session id for {}",
        session_file.path.display()
      ),
      bytes_read,
    });
  }

  let title = titles.get(&session_id).cloned();
  let last_model_id = current_model.clone();
  let checkpoint = ParserCheckpoint {
    completed_offset,
    prefix_signature: read_prefix_signature(&session_file.path, completed_offset).map_err(|error| {
      SessionParseError::Fatal {
        message: format!(
          "Failed to checkpoint {}: {error}",
          session_file.path.display()
        ),
        bytes_read,
      }
    })?,
    last_usage: monotonic_usage_high_water(None, &snapshots),
    current_model: current_model.clone(),
    explicit_fast_mode,
    latest_plan_type: latest_plan_type.clone(),
  };
  let mut rate_limit_samples = rate_limit_samples;
  for sample in &mut rate_limit_samples {
    sample.source_session_id = Some(session_id.clone());
  }

  Ok((
    ParsedSession {
      raw_session: RawSession {
        session_id: session_id.clone(),
        parent_session_id,
        root_session_id: session_id,
        title,
        source_state: session_file.bucket.clone(),
        source_path: Some(session_file.path.to_string_lossy().to_string()),
        started_at,
        updated_at,
        model_ids: seen_models.into_iter().collect(),
        contains_subagents: false,
        agent_nickname,
        agent_role,
      },
      snapshots,
      rate_limit_samples,
      explicit_forked_from_id,
      explicit_fork_timestamp,
      inherited_token_snapshot_cutoff: 0,
      explicit_fast_mode,
      latest_plan_type,
      last_model_id: last_model_id.or_else(|| Some("unknown".to_string())),
      mode: ParsedSessionMode::Full,
      checkpoint,
    },
    bytes_read,
  ))
}

fn read_prefix_signature(path: &Path, completed_offset: u64) -> std::io::Result<Vec<u8>> {
  let signature_start = completed_offset.saturating_sub(PARSER_PREFIX_SIGNATURE_BYTES);
  let signature_len = completed_offset.saturating_sub(signature_start) as usize;
  let mut file = File::open(path)?;
  file.seek(SeekFrom::Start(signature_start))?;
  let mut signature = vec![0u8; signature_len];
  file.read_exact(&mut signature)?;
  Ok(signature)
}

fn monotonic_usage_high_water(
  mut high_water: Option<TokenUsage>,
  snapshots: &[UsageSnapshot],
) -> Option<TokenUsage> {
  for snapshot in snapshots {
    if high_water
      .as_ref()
      .is_none_or(|previous| snapshot.usage.total_tokens > previous.total_tokens)
    {
      high_water = Some(snapshot.usage.clone());
    }
  }
  high_water
}

fn fallback_session_id_from_filename(path: &Path) -> Option<String> {
  let stem = path.file_stem()?.to_str()?;
  let parts = stem.split('-').collect::<Vec<_>>();
  if parts.len() < 5 {
    return None;
  }

  let candidate = parts[parts.len().saturating_sub(5)..].join("-");
  if looks_like_session_id(&candidate) {
    Some(candidate)
  } else {
    None
  }
}

fn looks_like_session_id(value: &str) -> bool {
  let segments = value.split('-').collect::<Vec<_>>();
  if segments.len() != 5 {
    return false;
  }

  let expected_lengths = [8usize, 4, 4, 4, 12];
  segments
    .iter()
    .zip(expected_lengths.iter())
    .all(|(segment, expected_len)| {
      segment.len() == *expected_len
        && segment
          .chars()
          .all(|character| character.is_ascii_hexdigit())
    })
}

fn load_session_source_paths(
  conn: &Connection,
  import_state: &HashMap<String, ImportState>,
  session_files: &[SessionFile],
) -> rusqlite::Result<HashMap<String, PathBuf>> {
  let mut source_paths = HashMap::new();
  let mut stmt =
    conn.prepare("SELECT session_id, source_path FROM sessions WHERE source_path IS NOT NULL")?;
  let rows = stmt.query_map([], |row| {
    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
  })?;

  for row in rows {
    let (session_id, source_path) = row?;
    source_paths.insert(session_id, PathBuf::from(source_path));
  }
  drop(stmt);

  for state in import_state.values() {
    let Some(session_id) = state.session_id.as_ref() else {
      continue;
    };
    source_paths.insert(session_id.clone(), PathBuf::from(&state.source_path));
  }

  for session_file in session_files {
    let Some(session_id) = fallback_session_id_from_filename(&session_file.path) else {
      continue;
    };
    source_paths.insert(session_id, session_file.path.clone());
  }

  Ok(source_paths)
}

fn assign_inherited_token_snapshot_cutoff(
  parsed: &mut ParsedSession,
  session_source_paths: &HashMap<String, PathBuf>,
  parent_snapshot_cache: &mut ParentReplayCache,
) -> (bool, u64) {
  let Some(parent_session_id) = parsed
    .explicit_forked_from_id
    .as_deref()
    .filter(|session_id| !session_id.trim().is_empty())
    .map(ToString::to_string)
  else {
    return (false, 0);
  };
  let Some(fork_timestamp) = parsed.explicit_fork_timestamp else {
    return (false, 0);
  };

  if let Some(cached) = parent_snapshot_cache.get(&parent_session_id) {
    let Some(parent_snapshots) = cached.as_deref() else {
      return (true, 0);
    };
    parsed.inherited_token_snapshot_cutoff =
      replayed_child_snapshot_cutoff(parent_snapshots, &parsed.snapshots, Some(fork_timestamp));
    return (false, 0);
  }

  let (parent_snapshots, bytes_read) = match session_source_paths.get(&parent_session_id) {
    Some(source_path) => {
      match read_parent_replay_snapshots_counted(source_path, &parent_session_id) {
        Ok((snapshots, bytes_read)) => (Some(snapshots), bytes_read),
        Err(bytes_read) => {
          log::warn!(
            "Replay parent unavailable: child_id={}, parent_id={}, source_path={}",
            parsed.raw_session.session_id,
            parent_session_id,
            source_path.display()
          );
          (None, bytes_read)
        }
      }
    }
    None => {
      log::warn!(
        "Replay parent unavailable: child_id={}, parent_id={}",
        parsed.raw_session.session_id,
        parent_session_id
      );
      (None, 0)
    }
  };
  let replay_parent_unavailable = parent_snapshots.is_none();
  if let Some(parent_snapshots) = parent_snapshots.as_deref() {
    parsed.inherited_token_snapshot_cutoff =
      replayed_child_snapshot_cutoff(parent_snapshots, &parsed.snapshots, Some(fork_timestamp));
  }
  parent_snapshot_cache.insert(parent_session_id, parent_snapshots);
  (replay_parent_unavailable, bytes_read)
}

#[cfg(test)]
fn read_parent_replay_snapshots(
  source_path: &Path,
  requested_parent_id: &str,
) -> Result<Vec<UsageSnapshot>, ()> {
  read_parent_replay_snapshots_counted(source_path, requested_parent_id)
    .map(|(snapshots, _)| snapshots)
    .map_err(|_| ())
}

fn read_parent_replay_snapshots_counted(
  source_path: &Path,
  requested_parent_id: &str,
) -> Result<(Vec<UsageSnapshot>, u64), u64> {
  let filename_session_id = fallback_session_id_from_filename(source_path);
  if filename_session_id
    .as_deref()
    .is_some_and(|session_id| session_id != requested_parent_id)
  {
    return Err(0);
  }

  let file = File::open(source_path).map_err(|_| 0u64)?;
  let mut reader = BufReader::new(CountingReader::new(file));
  let mut first_session_meta_id: Option<String> = None;
  let mut snapshots = Vec::new();
  let mut line = String::new();

  loop {
    line.clear();
    match reader.read_line(&mut line) {
      Ok(0) => break,
      Ok(_) => {}
      Err(_) => return Err(reader.get_ref().bytes_read),
    }
    if !line.contains("\"session_meta\"") && !line.contains("\"token_count\"") {
      continue;
    }

    let envelope = serde_json::from_str::<ReplayParentLineEnvelope<'_>>(&line)
      .map_err(|_| reader.get_ref().bytes_read)?;
    match envelope.record_type {
      Some("session_meta") if first_session_meta_id.is_none() => {
        let Some(session_id) = envelope.payload.as_ref().and_then(|payload| payload.id) else {
          continue;
        };
        if filename_session_id.is_none() && session_id != requested_parent_id {
          return Err(reader.get_ref().bytes_read);
        }
        first_session_meta_id = Some(session_id.to_string());
      }
      Some("event_msg")
        if envelope
          .payload
          .as_ref()
          .and_then(|payload| payload.record_type)
          == Some("token_count") =>
      {
        let timestamp = envelope.timestamp.ok_or(reader.get_ref().bytes_read)?;
        let details = serde_json::from_str::<ReplayParentTokenDetails>(&line)
          .map_err(|_| reader.get_ref().bytes_read)?;

        snapshots.push(UsageSnapshot {
          timestamp: timestamp.to_string(),
          model_id: String::new(),
          usage: details.payload.info.total_token_usage.into_token_usage(),
          last_token_usage: details
            .payload
            .info
            .last_token_usage
            .map(ReplayParentTokenUsage::into_token_usage),
          plan_type: None,
          limit_id: None,
          limit_name: None,
          explicit_fast_mode: None,
        });
      }
      _ => {}
    }
  }

  let bytes_read = reader.get_ref().bytes_read;
  if filename_session_id.is_none() && first_session_meta_id.is_none() {
    return Err(bytes_read);
  }
  if snapshots.is_empty() {
    return Err(bytes_read);
  }

  Ok((snapshots, bytes_read))
}

#[derive(Deserialize)]
struct ReplayParentLineEnvelope<'a> {
  #[serde(default)]
  timestamp: Option<&'a str>,
  #[serde(rename = "type", default)]
  record_type: Option<&'a str>,
  #[serde(default, borrow)]
  payload: Option<ReplayParentPayloadEnvelope<'a>>,
}

#[derive(Deserialize)]
struct ReplayParentPayloadEnvelope<'a> {
  #[serde(default)]
  id: Option<&'a str>,
  #[serde(rename = "type", default)]
  record_type: Option<&'a str>,
}

#[derive(Deserialize)]
struct ReplayParentTokenDetails {
  payload: ReplayParentTokenPayload,
}

#[derive(Deserialize)]
struct ReplayParentTokenPayload {
  info: ReplayParentTokenInfo,
}

#[derive(Deserialize)]
struct ReplayParentTokenInfo {
  total_token_usage: ReplayParentTokenUsage,
  #[serde(default)]
  last_token_usage: Option<ReplayParentTokenUsage>,
}

#[derive(Deserialize)]
struct ReplayParentTokenUsage {
  #[serde(default)]
  input_tokens: i64,
  #[serde(default)]
  cached_input_tokens: i64,
  #[serde(default)]
  output_tokens: i64,
  #[serde(default)]
  reasoning_output_tokens: i64,
  #[serde(default)]
  total_tokens: Option<i64>,
}

impl ReplayParentTokenUsage {
  fn into_token_usage(self) -> TokenUsage {
    TokenUsage {
      input_tokens: self.input_tokens,
      cached_input_tokens: self.cached_input_tokens,
      output_tokens: self.output_tokens,
      reasoning_output_tokens: self.reasoning_output_tokens,
      total_tokens: self
        .total_tokens
        .unwrap_or_else(|| self.input_tokens + self.output_tokens),
    }
  }
}

fn ensure_replay_parent_source_path(
  db_path: &Path,
  parsed: &ParsedSession,
  session_source_paths: &mut HashMap<String, PathBuf>,
) -> Result<(), String> {
  if !matches!(parsed.mode, ParsedSessionMode::Full) {
    return Ok(());
  }
  let Some(parent_session_id) = parsed
    .explicit_forked_from_id
    .as_deref()
    .filter(|session_id| !session_id.trim().is_empty())
  else {
    return Ok(());
  };
  if session_source_paths.contains_key(parent_session_id) {
    return Ok(());
  }

  let conn = open_scan_snapshot(db_path).map_err(|error| error.to_string())?;
  let source_path = conn
    .query_row(
      "SELECT source_path FROM sessions WHERE session_id = ?1 AND source_path IS NOT NULL",
      params![parent_session_id],
      |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(|error| error.to_string())?;
  if let Some(source_path) = source_path {
    session_source_paths.insert(parent_session_id.to_string(), PathBuf::from(source_path));
  }
  Ok(())
}

fn ensure_existing_relation_context(
  db_path: &Path,
  session_id: &str,
  existing_relations: &mut HashMap<String, ExistingSessionRelation>,
) -> Result<(), String> {
  if existing_relations.contains_key(session_id) {
    return Ok(());
  }
  let conn = open_scan_snapshot(db_path).map_err(|error| error.to_string())?;
  let existing_parent = conn
    .query_row(
      "SELECT parent_session_id FROM sessions WHERE session_id = ?1",
      params![session_id],
      |row| row.get::<_, Option<String>>(0),
    )
    .optional()
    .map_err(|error| error.to_string())?;
  let child_count = conn
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE parent_session_id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0),
    )
    .map_err(|error| error.to_string())?
    .max(0) as usize;
  existing_relations.insert(
    session_id.to_string(),
    ExistingSessionRelation {
      exists: existing_parent.is_some(),
      parent_session_id: existing_parent.flatten(),
      child_count,
    },
  );
  Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ReplayKey {
  total_token_usage: TokenUsage,
  last_token_usage: TokenUsage,
}

#[derive(Debug, Clone, Copy)]
struct CanonicalReplaySnapshot<'a> {
  raw_index: usize,
  snapshot: &'a UsageSnapshot,
}

impl CanonicalReplaySnapshot<'_> {
  fn replay_key(&self) -> Option<ReplayKey> {
    Some(ReplayKey {
      total_token_usage: self.snapshot.usage.clone(),
      last_token_usage: self.snapshot.last_token_usage.clone()?,
    })
  }
}

fn canonical_replay_snapshots(snapshots: &[UsageSnapshot]) -> Vec<CanonicalReplaySnapshot<'_>> {
  let mut high_water: Option<i64> = None;
  let mut canonical = Vec::new();

  for (raw_index, snapshot) in snapshots.iter().enumerate() {
    if high_water.is_some_and(|total| snapshot.usage.total_tokens <= total) {
      continue;
    }

    high_water = Some(snapshot.usage.total_tokens);
    canonical.push(CanonicalReplaySnapshot {
      raw_index,
      snapshot,
    });
  }

  canonical
}

fn kmp_prefix_table(pattern: &[ReplayKey]) -> Vec<usize> {
  let mut table = vec![0; pattern.len()];

  for index in 1..pattern.len() {
    let mut prefix_len = table[index - 1];
    while prefix_len > 0 && pattern[index] != pattern[prefix_len] {
      prefix_len = table[prefix_len - 1];
    }
    if pattern[index] == pattern[prefix_len] {
      prefix_len += 1;
    }
    table[index] = prefix_len;
  }

  table
}

fn replayed_child_snapshot_cutoff(
  parent_snapshots: &[UsageSnapshot],
  child_snapshots: &[UsageSnapshot],
  explicit_fork_timestamp: Option<DateTime<FixedOffset>>,
) -> usize {
  let Some(explicit_fork_timestamp) = explicit_fork_timestamp else {
    return 0;
  };

  let child_canonical = canonical_replay_snapshots(child_snapshots);
  let mut child_pattern = Vec::new();
  for snapshot in &child_canonical {
    let Some(key) = snapshot.replay_key() else {
      break;
    };
    child_pattern.push(key);
  }
  let parent_canonical = canonical_replay_snapshots(parent_snapshots);
  let eligible_parent_snapshot_count = parent_canonical
    .iter()
    .filter(|parent| {
      DateTime::parse_from_rfc3339(&parent.snapshot.timestamp)
        .is_ok_and(|timestamp| timestamp <= explicit_fork_timestamp)
    })
    .count();
  let minimum_match_length = if eligible_parent_snapshot_count == 1 {
    1
  } else {
    2
  };
  if child_pattern.len() < minimum_match_length {
    return 0;
  }

  let prefix_table = kmp_prefix_table(&child_pattern);
  let mut matched = 0;
  let mut longest_match = 0;

  for parent in parent_canonical {
    let Ok(parent_timestamp) = DateTime::parse_from_rfc3339(&parent.snapshot.timestamp) else {
      continue;
    };
    if parent_timestamp > explicit_fork_timestamp {
      continue;
    }

    let Some(parent_key) = parent.replay_key() else {
      matched = 0;
      continue;
    };

    while matched > 0 && child_pattern[matched] != parent_key {
      matched = prefix_table[matched - 1];
    }
    if child_pattern[matched] == parent_key {
      matched += 1;
      longest_match = longest_match.max(matched);
      if matched == child_pattern.len() {
        break;
      }
    }
  }

  if longest_match < minimum_match_length {
    0
  } else {
    child_canonical[longest_match - 1].raw_index + 1
  }
}

fn persist_session(
  conn: &Connection,
  session_file: &PreparedSessionFile,
  parsed: &ParsedSession,
  catalog: &HashMap<String, crate::models::PricingCatalogEntry>,
) -> rusqlite::Result<()> {
  let created_at = now_utc_string();
  let imported_at = created_at.clone();
  let fast_mode_default = false;

  conn.execute(
    "
    INSERT INTO sessions (
      session_id, root_session_id, parent_session_id, title, source_state, source_path,
      source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
      fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 0, ?16, ?17)
    ON CONFLICT(session_id) DO UPDATE SET
      root_session_id = sessions.root_session_id,
      parent_session_id = excluded.parent_session_id,
      title = COALESCE(excluded.title, sessions.title),
      source_state = excluded.source_state,
      source_path = excluded.source_path,
      source_bucket = excluded.source_bucket,
      started_at = COALESCE(sessions.started_at, excluded.started_at),
      updated_at = COALESCE(excluded.updated_at, sessions.updated_at),
      agent_nickname = COALESCE(excluded.agent_nickname, sessions.agent_nickname),
      agent_role = COALESCE(excluded.agent_role, sessions.agent_role),
      explicit_fast_mode = excluded.explicit_fast_mode,
      fast_mode_default = excluded.fast_mode_default,
      latest_plan_type = COALESCE(excluded.latest_plan_type, sessions.latest_plan_type),
      last_model_id = COALESCE(excluded.last_model_id, sessions.last_model_id),
      imported_at = excluded.imported_at
    ",
    params![
      parsed.raw_session.session_id,
      parsed.raw_session.root_session_id,
      parsed.raw_session.parent_session_id,
      parsed.raw_session.title,
      parsed.raw_session.source_state,
      parsed.raw_session.source_path,
      session_file.bucket,
      parsed.raw_session.started_at,
      parsed.raw_session.updated_at,
      parsed.raw_session.agent_nickname,
      parsed.raw_session.agent_role,
      parsed.explicit_fast_mode.map(bool_to_i64),
      bool_to_i64(fast_mode_default),
      parsed.latest_plan_type,
      parsed.last_model_id,
      created_at,
      imported_at,
    ],
  )?;

  match &parsed.mode {
    ParsedSessionMode::Full => replace_session_rate_limit_samples(
      conn,
      &parsed.raw_session.session_id,
      &parsed.rate_limit_samples,
    )?,
    ParsedSessionMode::Tail { .. } => append_session_rate_limit_samples(
      conn,
      &parsed.raw_session.session_id,
      &parsed.rate_limit_samples,
    )?,
  };

  let (snapshot_cutoff, mut previous_usage) = match &parsed.mode {
    ParsedSessionMode::Full => {
      let snapshot_cutoff = parsed.inherited_token_snapshot_cutoff;
      let previous_usage = snapshot_cutoff
        .checked_sub(1)
        .and_then(|index| parsed.snapshots.get(index))
        .map(|snapshot| snapshot.usage.clone());
      (snapshot_cutoff, previous_usage)
    }
    ParsedSessionMode::Tail { previous_usage } => (0, previous_usage.clone()),
  };

  let mut usage_event_plan = Vec::new();
  for (snapshot_index, snapshot) in parsed.snapshots.iter().enumerate().skip(snapshot_cutoff) {
    if previous_usage.as_ref() == Some(&snapshot.usage) {
      continue;
    }

    let delta = if let Some(previous) = previous_usage.as_ref() {
      if snapshot.usage.total_tokens <= previous.total_tokens {
        continue;
      }
      diff_usage(previous, &snapshot.usage)
    } else if parsed.explicit_forked_from_id.is_some() {
      snapshot
        .last_token_usage
        .clone()
        .unwrap_or_else(|| snapshot.usage.clone())
    } else {
      snapshot.usage.clone()
    };

    previous_usage = Some(snapshot.usage.clone());
    if is_zero_delta(&delta) {
      continue;
    }
    usage_event_plan.push((snapshot_index, delta));
  }

  let timestamps = usage_event_plan
    .iter()
    .map(|(snapshot_index, _)| parsed.snapshots[*snapshot_index].timestamp.as_str());
  let event_at = |index: usize| {
      let (snapshot_index, delta) = &usage_event_plan[index];
      let snapshot = &parsed.snapshots[*snapshot_index];
      let resolved_pricing = resolve_pricing(catalog, &snapshot.model_id);
      let value_usd = calculate_value_usd(delta, resolved_pricing.as_ref());
      Some(NewUsageEvent {
        session_id: &parsed.raw_session.session_id,
        model_id: normalize_model_id(&snapshot.model_id),
        input_tokens: delta.input_tokens,
        cached_input_tokens: delta.cached_input_tokens,
        output_tokens: delta.output_tokens,
        reasoning_output_tokens: delta.reasoning_output_tokens,
        total_tokens: delta.total_tokens,
        value_usd,
        fast_mode_auto: false,
        fast_mode_effective: false,
      })
    };
  match &parsed.mode {
    ParsedSessionMode::Full => replace_session_usage_events(
      conn,
      &parsed.raw_session.session_id,
      timestamps,
      event_at,
    )?,
    ParsedSessionMode::Tail { .. } => append_session_usage_events(
      conn,
      &parsed.raw_session.session_id,
      timestamps,
      event_at,
    )?,
  };

  let parser_checkpoint = serde_json::to_string(&parsed.checkpoint)
    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;

  conn.execute(
    "
    INSERT INTO import_state (
      source_path, session_id, source_bucket, file_size, file_mtime_ms,
      parser_checkpoint, parser_completed_offset, last_imported_at
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    ON CONFLICT(source_path) DO UPDATE SET
      session_id = excluded.session_id,
      source_bucket = excluded.source_bucket,
      file_size = excluded.file_size,
      file_mtime_ms = excluded.file_mtime_ms,
      parser_checkpoint = excluded.parser_checkpoint,
      parser_completed_offset = excluded.parser_completed_offset,
      last_imported_at = excluded.last_imported_at
    ",
    params![
      session_file.source_path,
      parsed.raw_session.session_id,
      session_file.bucket,
      session_file.file_size,
      session_file.file_mtime_ms,
      parser_checkpoint,
      parsed.checkpoint.completed_offset as i64,
      now_utc_string(),
    ],
  )?;

  conn.execute(
    "
    DELETE FROM import_state
    WHERE session_id = ?1 AND source_path <> ?2
    ",
    params![parsed.raw_session.session_id, session_file.source_path,],
  )?;

  Ok(())
}

fn diff_usage(previous: &TokenUsage, current: &TokenUsage) -> TokenUsage {
  if current.total_tokens <= previous.total_tokens {
    return TokenUsage::default();
  }

  TokenUsage {
    input_tokens: non_negative_delta(current.input_tokens, previous.input_tokens),
    cached_input_tokens: non_negative_delta(
      current.cached_input_tokens,
      previous.cached_input_tokens,
    ),
    output_tokens: non_negative_delta(current.output_tokens, previous.output_tokens),
    reasoning_output_tokens: non_negative_delta(
      current.reasoning_output_tokens,
      previous.reasoning_output_tokens,
    ),
    total_tokens: current.total_tokens - previous.total_tokens,
  }
}

fn non_negative_delta(current: i64, previous: i64) -> i64 {
  current.saturating_sub(previous).max(0)
}

fn is_zero_delta(delta: &TokenUsage) -> bool {
  delta.total_tokens == 0
    && delta.input_tokens == 0
    && delta.cached_input_tokens == 0
    && delta.output_tokens == 0
    && delta.reasoning_output_tokens == 0
}

fn extract_rate_limit_samples(timestamp: &str, payload: &Value) -> Vec<RateLimitSampleRecord> {
  let Some(rate_limits) = payload.get("rate_limits") else {
    return Vec::new();
  };
  if rate_limits.is_null() {
    return Vec::new();
  }

  let limit_id = nested_str(rate_limits, &["limit_id"]);
  let limit_name = nested_str(rate_limits, &["limit_name"]);
  let plan_type = rate_limits
    .get("plan_type")
    .and_then(Value::as_str)
    .map(ToString::to_string);

  let mut samples = Vec::new();
  for (default_bucket, window_key) in [("five_hour", "primary"), ("seven_day", "secondary")] {
    let Some(rate_window) = rate_limits.get(window_key) else {
      continue;
    };
    let Some(used_percent) = read_percent(rate_window, "used_percent") else {
      continue;
    };
    let Some(window_duration_mins) = rate_window
      .get("window_duration_mins")
      .and_then(Value::as_i64)
      .or_else(|| rate_window.get("window_minutes").and_then(Value::as_i64))
    else {
      continue;
    };
    let bucket = if window_duration_mins == 7 * 24 * 60 {
      "seven_day"
    } else {
      default_bucket
    };
    let Some(resets_at_seconds) = rate_window.get("resets_at").and_then(Value::as_i64) else {
      continue;
    };
    let Some(resets_at) = unix_seconds_to_rfc3339_local(resets_at_seconds) else {
      continue;
    };
    let Some(window_start) =
      unix_seconds_to_rfc3339_local(resets_at_seconds - window_duration_mins * 60)
    else {
      continue;
    };

    samples.push(RateLimitSampleRecord {
      source_kind: "session".to_string(),
      source_session_id: None,
      bucket: bucket.to_string(),
      sample_timestamp: timestamp.to_string(),
      limit_id: limit_id
        .clone()
        .or_else(|| nested_str(rate_window, &["limit_id"])),
      limit_name: limit_name
        .clone()
        .or_else(|| nested_str(rate_window, &["limit_name"])),
      plan_type: plan_type.clone(),
      window_start,
      resets_at,
      used_percent: used_percent.clamp(0, 100),
      remaining_percent: (100 - used_percent).clamp(0, 100),
    });
  }

  samples
}

fn unix_seconds_to_rfc3339_local(value: i64) -> Option<String> {
  match Local.timestamp_opt(value, 0) {
    LocalResult::Single(timestamp) => Some(normalize_local_timestamp(timestamp).to_rfc3339()),
    LocalResult::Ambiguous(timestamp, _) => Some(normalize_local_timestamp(timestamp).to_rfc3339()),
    LocalResult::None => None,
  }
}

fn normalize_local_timestamp(timestamp: chrono::DateTime<Local>) -> chrono::DateTime<Local> {
  timestamp
    .with_second(0)
    .and_then(|value| value.with_nanosecond(0))
    .unwrap_or(timestamp)
}

fn load_import_state(conn: &Connection) -> rusqlite::Result<HashMap<String, ImportState>> {
  let mut stmt = conn.prepare(
    "
    SELECT source_path, session_id, source_bucket, file_size, file_mtime_ms, parser_checkpoint
    FROM import_state
    ",
  )?;

  let rows = stmt.query_map([], |row| {
    Ok(ImportState {
      source_path: row.get(0)?,
      session_id: row.get(1)?,
      source_bucket: row.get(2)?,
      file_size: row.get(3)?,
      file_mtime_ms: row.get(4)?,
      parser_checkpoint: row
        .get::<_, Option<String>>(5)?
        .and_then(|checkpoint| serde_json::from_str(&checkpoint).ok()),
    })
  })?;

  let mut result = HashMap::new();
  for row in rows {
    let state = row?;
    result.insert(state.source_path.clone(), state);
  }
  Ok(result)
}

fn load_incremental_import_state(
  conn: &Connection,
  pending_repair_paths: &HashSet<String>,
) -> rusqlite::Result<HashMap<String, ImportState>> {
  let mut stmt = conn.prepare(
    "
    SELECT source_path, session_id, source_bucket, file_size, file_mtime_ms, parser_checkpoint
    FROM import_state
    WHERE source_bucket = 'active'
    UNION ALL
    SELECT source_path, session_id, source_bucket, file_size, file_mtime_ms, parser_checkpoint
    FROM import_state INDEXED BY idx_import_state_incomplete_archived_tail
    WHERE source_bucket = 'archived'
      AND parser_completed_offset < file_size
    ",
  )?;
  let rows = stmt.query_map([], import_state_from_row)?;

  let mut result = HashMap::new();
  for row in rows {
    let state = row?;
    result.insert(state.source_path.clone(), state);
  }
  drop(stmt);
  for source_path in pending_repair_paths {
    let state = conn
      .query_row(
        "
        SELECT source_path, session_id, source_bucket, file_size, file_mtime_ms, parser_checkpoint
        FROM import_state
        WHERE source_path = ?1
        ",
        params![source_path],
        import_state_from_row,
      )
      .optional()?;
    if let Some(state) = state {
      result.insert(state.source_path.clone(), state);
    }
  }
  Ok(result)
}

fn import_state_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ImportState> {
  Ok(ImportState {
    source_path: row.get(0)?,
    session_id: row.get(1)?,
    source_bucket: row.get(2)?,
    file_size: row.get(3)?,
    file_mtime_ms: row.get(4)?,
    parser_checkpoint: row
      .get::<_, Option<String>>(5)?
      .and_then(|checkpoint| serde_json::from_str(&checkpoint).ok()),
  })
}

fn needs_rate_limit_sample_backfill(conn: &Connection) -> rusqlite::Result<bool> {
  data_repair_is_pending(conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY)
}

fn data_repair_is_pending(conn: &Connection, repair_key: &str) -> rusqlite::Result<bool> {
  let completed = conn
    .query_row(
      "SELECT 1 FROM data_repairs WHERE repair_key = ?1",
      params![repair_key],
      |row| row.get::<_, i64>(0),
    )
    .optional()?;
  Ok(completed.is_none())
}

fn mark_data_repair_complete(
  conn: &Connection,
  repair_key: &str,
  completed_at: &str,
) -> rusqlite::Result<()> {
  conn.execute(
    "
    INSERT INTO data_repairs (repair_key, completed_at)
    VALUES (?1, ?2)
    ON CONFLICT(repair_key) DO UPDATE SET completed_at = excluded.completed_at
    ",
    params![repair_key, completed_at],
  )?;
  Ok(())
}

fn load_pending_data_repair_paths(
  conn: &Connection,
  repair_key: &str,
) -> rusqlite::Result<HashSet<String>> {
  let mut stmt = conn.prepare(
    "
    SELECT source_path
    FROM data_repair_pending_files
    WHERE repair_key = ?1
    ",
  )?;
  let rows = stmt.query_map(params![repair_key], |row| row.get::<_, String>(0))?;

  let mut paths = HashSet::new();
  for row in rows {
    paths.insert(row?);
  }
  Ok(paths)
}

fn pending_repair_paths_for_session(
  import_state: &HashMap<String, ImportState>,
  pending_paths: &HashSet<String>,
  session_id: &str,
) -> Vec<String> {
  pending_paths
    .iter()
    .filter(|source_path| {
      let import_state_session_id = import_state
        .get(*source_path)
        .and_then(|state| state.session_id.as_deref());
      import_state_session_id == Some(session_id)
        || (import_state_session_id.is_none()
          && fallback_session_id_from_filename(Path::new(source_path)).as_deref()
            == Some(session_id))
    })
    .cloned()
    .collect()
}

fn pending_repair_session_ids(
  import_state: &HashMap<String, ImportState>,
  pending_paths: &HashSet<String>,
) -> HashSet<String> {
  pending_paths
    .iter()
    .filter_map(|source_path| {
      import_state
        .get(source_path)
        .and_then(|state| state.session_id.clone())
        .or_else(|| fallback_session_id_from_filename(Path::new(source_path)))
    })
    .collect()
}

fn mark_data_repair_file_pending(
  conn: &Connection,
  repair_key: &str,
  source_path: &str,
  last_error: &str,
) -> rusqlite::Result<()> {
  conn.execute(
    "
    INSERT INTO data_repair_pending_files (repair_key, source_path, last_error, updated_at)
    VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(repair_key, source_path) DO UPDATE SET
      last_error = excluded.last_error,
      updated_at = excluded.updated_at
    ",
    params![repair_key, source_path, last_error, now_utc_string()],
  )?;
  Ok(())
}

fn clear_pending_data_repair_file(
  conn: &Connection,
  repair_key: &str,
  source_path: &str,
) -> rusqlite::Result<()> {
  conn.execute(
    "
    DELETE FROM data_repair_pending_files
    WHERE repair_key = ?1 AND source_path = ?2
    ",
    params![repair_key, source_path],
  )?;
  Ok(())
}

fn load_existing_session_relations(
  conn: &Connection,
) -> rusqlite::Result<HashMap<String, ExistingSessionRelation>> {
  let mut stmt = conn.prepare("SELECT session_id, parent_session_id FROM sessions")?;
  let rows = stmt.query_map([], |row| {
    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
  })?;

  let mut relations: HashMap<String, ExistingSessionRelation> = HashMap::new();
  for row in rows {
    let (session_id, parent_session_id) = row?;
    let relation = relations.entry(session_id.clone()).or_default();
    relation.exists = true;
    relation.parent_session_id = parent_session_id.clone();
    if let Some(parent_session_id) = parent_session_id {
      relations.entry(parent_session_id).or_default().child_count += 1;
    }
  }

  Ok(relations)
}

fn load_incremental_session_relations(
  conn: &Connection,
  import_state: &HashMap<String, ImportState>,
) -> rusqlite::Result<HashMap<String, ExistingSessionRelation>> {
  let mut stmt = conn.prepare(
    "
    SELECT session_id, parent_session_id
    FROM sessions
    WHERE source_state = 'active'
    ",
  )?;
  let rows = stmt.query_map([], |row| {
    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
  })?;

  let mut relations = HashMap::new();
  for row in rows {
    let (session_id, parent_session_id) = row?;
    relations.insert(
      session_id,
      ExistingSessionRelation {
        exists: true,
        parent_session_id,
        child_count: 0,
      },
    );
  }
  drop(stmt);
  for state in import_state
    .values()
    .filter(|state| state.source_bucket != "active")
  {
    let Some(session_id) = state.session_id.as_deref() else {
      continue;
    };
    let parent_session_id = conn
      .query_row(
        "SELECT parent_session_id FROM sessions WHERE session_id = ?1",
        params![session_id],
        |row| row.get::<_, Option<String>>(0),
      )
      .optional()?;
    if let Some(parent_session_id) = parent_session_id {
      relations.insert(
        session_id.to_string(),
        ExistingSessionRelation {
          exists: true,
          parent_session_id,
          child_count: 0,
        },
      );
    }
  }
  Ok(relations)
}

fn existing_session_source_from_row(
  row: &rusqlite::Row<'_>,
) -> rusqlite::Result<ExistingSessionSource> {
  Ok(ExistingSessionSource {
    session_id: row.get(0)?,
    source_path: row.get(1)?,
    source_state: row.get(2)?,
    source_bucket: row.get(3)?,
  })
}

fn load_incremental_session_sources(
  conn: &Connection,
  import_state: &HashMap<String, ImportState>,
) -> rusqlite::Result<Vec<ExistingSessionSource>> {
  let mut stmt = conn.prepare(
    "
    SELECT session_id, source_path, source_state, source_bucket
    FROM sessions
    WHERE source_path IS NOT NULL AND source_state = 'active'
    ",
  )?;
  let rows = stmt.query_map([], existing_session_source_from_row)?;
  let mut sources = rows.collect::<rusqlite::Result<Vec<_>>>()?;
  drop(stmt);
  for state in import_state
    .values()
    .filter(|state| state.source_bucket != "active")
  {
    let Some(session_id) = state.session_id.as_deref() else {
      continue;
    };
    let source = conn
      .query_row(
        "
        SELECT session_id, source_path, source_state, source_bucket
        FROM sessions
        WHERE session_id = ?1 AND source_path IS NOT NULL
        ",
        params![session_id],
        existing_session_source_from_row,
      )
      .optional()?;
    if let Some(source) = source {
      sources.push(source);
    }
  }
  Ok(sources)
}

fn upsert_root_conversation_links(
  conn: &Connection,
  session_ids: &[String],
) -> rusqlite::Result<()> {
  for session_id in session_ids {
    conn.execute(
      "
      INSERT INTO conversation_links (session_id, root_session_id, parent_session_id, depth)
      VALUES (?1, ?1, NULL, 0)
      ON CONFLICT(session_id) DO UPDATE SET
        root_session_id = excluded.root_session_id,
        parent_session_id = excluded.parent_session_id,
        depth = excluded.depth
      ",
      params![session_id],
    )?;
  }

  Ok(())
}

fn conversation_links_need_repair(conn: &Connection) -> rusqlite::Result<bool> {
  conn.query_row(
    "
    SELECT EXISTS (
      SELECT 1
      FROM sessions AS session
      LEFT JOIN conversation_links AS link ON link.session_id = session.session_id
      WHERE link.session_id IS NULL
         OR link.parent_session_id IS NOT session.parent_session_id
    )
    ",
    [],
    |row| Ok(row.get::<_, i64>(0)? != 0),
  )
}

fn recompute_conversation_links(conn: &Connection) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare("SELECT session_id, parent_session_id FROM sessions")?;
  let rows = stmt.query_map([], |row| {
    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
  })?;

  let mut parents = HashMap::new();
  for row in rows {
    let (session_id, parent_session_id) = row?;
    parents.insert(session_id, parent_session_id);
  }

  let mut child_counts: HashMap<String, usize> = HashMap::new();
  for parent_session_id in parents.values().flatten() {
    *child_counts.entry(parent_session_id.clone()).or_default() += 1;
  }

  for session_id in parents.keys() {
    let (root_session_id, depth) = resolve_root(session_id, &parents);
    conn.execute(
      "
      INSERT INTO conversation_links (session_id, root_session_id, parent_session_id, depth)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(session_id) DO UPDATE SET
        root_session_id = excluded.root_session_id,
        parent_session_id = excluded.parent_session_id,
        depth = excluded.depth
      ",
      params![
        session_id,
        root_session_id,
        parents.get(session_id).cloned().flatten(),
        depth as i64
      ],
    )?;

    conn.execute(
      "
      UPDATE sessions
      SET root_session_id = ?1, contains_subagents = ?2
      WHERE session_id = ?3
      ",
      params![
        root_session_id,
        bool_to_i64(child_counts.get(session_id).copied().unwrap_or(0) > 0),
        session_id,
      ],
    )?;
  }

  Ok(())
}

fn resolve_root(
  start_session_id: &str,
  parents: &HashMap<String, Option<String>>,
) -> (String, usize) {
  let mut current = start_session_id.to_string();
  let mut depth = 0usize;
  let mut seen = HashSet::new();

  while let Some(Some(parent)) = parents.get(&current) {
    if !seen.insert(current.clone()) {
      break;
    }
    if !parents.contains_key(parent) {
      return (parent.clone(), depth + 1);
    }
    current = parent.clone();
    depth += 1;
  }

  (current, depth)
}

fn nested_str(value: &Value, keys: &[&str]) -> Option<String> {
  let mut current = value;
  for key in keys {
    current = current.get(*key)?;
  }
  current.as_str().map(ToString::to_string)
}

fn read_i64(value: &Value, key: &str) -> i64 {
  value.get(key).and_then(Value::as_i64).unwrap_or_default()
}

fn read_total_tokens(value: &Value) -> i64 {
  value
    .get("total_tokens")
    .and_then(Value::as_i64)
    .unwrap_or_else(|| read_i64(value, "input_tokens") + read_i64(value, "output_tokens"))
}

fn read_percent(value: &Value, key: &str) -> Option<i64> {
  value.get(key).and_then(|field| {
    field
      .as_i64()
      .or_else(|| field.as_f64().map(|number| number.round() as i64))
  })
}

#[derive(Debug, Clone)]
struct ImportState {
  source_path: String,
  session_id: Option<String>,
  source_bucket: String,
  file_size: i64,
  file_mtime_ms: i64,
  parser_checkpoint: Option<ParserCheckpoint>,
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::database::{
    get_last_full_scan_completed, get_sync_settings, init_db, now_utc_string, open_connection,
    save_sync_settings,
  };
  use rusqlite::OptionalExtension;
  use std::ffi::OsString;
  use std::sync::Mutex;
  use tempfile::tempdir;

  static CODEX_HOME_ENV_LOCK: Mutex<()> = Mutex::new(());

  struct CodexHomeEnvGuard {
    previous: Option<OsString>,
  }

  impl CodexHomeEnvGuard {
    fn set(path: &Path) -> Self {
      let previous = std::env::var_os("CODEX_HOME");
      std::env::set_var("CODEX_HOME", path);
      Self { previous }
    }
  }

  impl Drop for CodexHomeEnvGuard {
    fn drop(&mut self) {
      if let Some(previous) = self.previous.take() {
        std::env::set_var("CODEX_HOME", previous);
      } else {
        std::env::remove_var("CODEX_HOME");
      }
    }
  }

  fn replay_usage(values: (i64, i64, i64, i64, i64)) -> TokenUsage {
    TokenUsage {
      input_tokens: values.0,
      cached_input_tokens: values.1,
      output_tokens: values.2,
      reasoning_output_tokens: values.3,
      total_tokens: values.4,
    }
  }

  fn replay_snapshot(
    timestamp: &str,
    model_id: &str,
    total: (i64, i64, i64, i64, i64),
    last: Option<(i64, i64, i64, i64, i64)>,
  ) -> UsageSnapshot {
    UsageSnapshot {
      timestamp: timestamp.to_string(),
      model_id: model_id.to_string(),
      usage: replay_usage(total),
      last_token_usage: last.map(replay_usage),
      plan_type: None,
      limit_id: None,
      limit_name: None,
      explicit_fast_mode: None,
    }
  }

  fn fork_instant(timestamp: &str) -> chrono::DateTime<chrono::FixedOffset> {
    chrono::DateTime::parse_from_rfc3339(timestamp).expect("valid fork instant")
  }

  #[derive(Debug, PartialEq, Eq)]
  struct DatabaseMutationFingerprint {
    sessions: i64,
    conversation_links: i64,
    usage_events: i64,
    import_state: i64,
    data_repairs: i64,
    pending_repairs: i64,
    rate_limit_samples: i64,
    freshness: (
      Option<String>,
      Option<String>,
      Option<String>,
      Option<String>,
      Option<String>,
      String,
      i64,
    ),
  }

  fn database_mutation_fingerprint(conn: &Connection) -> DatabaseMutationFingerprint {
    let count = |table: &str| {
      conn
        .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
          row.get(0)
        })
        .expect("count table")
    };
    let freshness = conn
      .query_row(
        "
        SELECT codex_home, last_scan_codex_home, last_scan_started_at,
               last_scan_completed_at, last_full_scan_completed_at, updated_at,
               scan_commit_revision
        FROM sync_settings
        WHERE singleton_id = 1
        ",
        [],
        |row| {
          Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
            row.get(5)?,
            row.get(6)?,
          ))
        },
      )
      .expect("load freshness fingerprint");

    DatabaseMutationFingerprint {
      sessions: count("sessions"),
      conversation_links: count("conversation_links"),
      usage_events: count("usage_events"),
      import_state: count("import_state"),
      data_repairs: count("data_repairs"),
      pending_repairs: count("data_repair_pending_files"),
      rate_limit_samples: count("rate_limit_samples"),
      freshness,
    }
  }

  fn initialize_scan_database(db_path: &Path) {
    let conn = open_connection(db_path).expect("open database");
    init_db(&conn).expect("init database");
    seed_pricing_catalog(&conn).expect("seed pricing");
  }

  fn configure_codex_home(db_path: &Path, codex_home: &Path) {
    let conn = open_connection(db_path).expect("open database");
    let mut settings = get_sync_settings(&conn).expect("load settings");
    settings.codex_home = Some(codex_home.to_string_lossy().to_string());
    save_sync_settings(&conn, &settings).expect("save source");
  }

  fn write_session_with_rate_limit_sample(path: &Path, session_id: &str, total_tokens: i64) {
    let body = format!(
      concat!(
        "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}\n",
        "{{\"timestamp\":\"2026-07-10T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{{",
        "\"type\":\"token_count\",\"info\":{{\"total_token_usage\":{{",
        "\"input_tokens\":{},\"cached_input_tokens\":0,\"output_tokens\":0,",
        "\"reasoning_output_tokens\":0,\"total_tokens\":{}}}}},",
        "\"rate_limits\":{{\"plan_type\":\"pro\",\"primary\":{{",
        "\"used_percent\":25,\"window_duration_mins\":300,\"resets_at\":1783648800",
        "}}}}}}}}\n"
      ),
      session_id, total_tokens, total_tokens,
    );
    std::fs::write(path, body).expect("write session with rate limit sample");
  }

  fn write_replay_cache_pair(
    sessions: &Path,
    prefix: usize,
    parent_session_id: &str,
    child_session_id: &str,
  ) {
    let timestamp = "2026-07-10T00:00:00Z";
    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      timestamp, parent_session_id, timestamp,
    );
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      timestamp, child_session_id, parent_session_id, timestamp,
    );
    for total in [10, 20, 30] {
      let line = token_count_line(TokenFixture {
        timestamp,
        total: (total, 0, 0, total),
        last: (10, 0, 0, 10),
      });
      parent_body.push_str(&line);
      child_body.push_str(&line);
    }
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp,
      total: (40, 0, 0, 40),
      last: (10, 0, 0, 10),
    }));

    std::fs::write(
      sessions.join(format!("{prefix:02}-parent-{parent_session_id}.jsonl")),
      parent_body,
    )
    .expect("write replay parent");
    std::fs::write(
      sessions.join(format!("{prefix:02}-child-{child_session_id}.jsonl")),
      child_body,
    )
    .expect("write replay child");
  }

  fn assert_scan_results_equivalent(left: &ScanResult, right: &ScanResult) {
    assert_eq!(left.codex_home, right.codex_home);
    assert_eq!(left.scanned_files, right.scanned_files);
    assert_eq!(left.imported_sessions, right.imported_sessions);
    assert_eq!(left.updated_sessions, right.updated_sessions);
    assert_eq!(left.missing_sessions, right.missing_sessions);
    assert!(!left.last_completed_at.is_empty());
    assert!(!right.last_completed_at.is_empty());
  }

  #[cfg(unix)]
  fn prepared_session_fixture(
    source_path: PathBuf,
    session_id: &str,
    model_id_bytes: usize,
  ) -> PreparedSession {
    let model_id = "x".repeat(model_id_bytes.max(1));
    let persisted_source_path = source_path.to_string_lossy().to_string();
    PreparedSession {
      session_file: PreparedSessionFile::from(SessionFile {
        path: source_path,
        bucket: "active".to_string(),
        file_size: 1,
        file_mtime_ms: 1,
      }),
      parsed: ParsedSession {
        raw_session: RawSession {
          session_id: session_id.to_string(),
          root_session_id: session_id.to_string(),
          source_state: "active".to_string(),
          source_path: Some(persisted_source_path),
          model_ids: vec![model_id.clone()],
          ..Default::default()
        },
        snapshots: vec![UsageSnapshot {
          timestamp: "2026-07-10T00:00:00Z".to_string(),
          model_id,
          usage: replay_usage((10, 0, 0, 0, 10)),
          last_token_usage: Some(replay_usage((10, 0, 0, 0, 10))),
          plan_type: None,
          limit_id: None,
          limit_name: None,
          explicit_fast_mode: None,
        }],
        rate_limit_samples: Vec::new(),
        explicit_forked_from_id: None,
        explicit_fork_timestamp: None,
        inherited_token_snapshot_cutoff: 0,
        explicit_fast_mode: None,
        latest_plan_type: None,
        last_model_id: None,
        mode: ParsedSessionMode::Full,
        checkpoint: ParserCheckpoint::default(),
      },
      file_needs_rate_limit_repair: false,
      file_needs_token_v2_repair: false,
      file_needs_fork_replay_v3_repair: false,
      replay_parent_unavailable: false,
      related_pending_token_v2_paths: Vec::new(),
      related_pending_fork_replay_v3_paths: Vec::new(),
    }
  }

  #[test]
  fn prepare_scan_is_read_only() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    write_session_file(
      &sessions.join("read-only.jsonl"),
      "10101010-1010-1010-1010-101010101010",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);

    let conn = open_connection(&db_path).expect("open database");
    let before = database_mutation_fingerprint(&conn);
    drop(conn);

    let prepared = prepare_scan(&db_path, None, ScanKind::Full).expect("prepare scan");

    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(database_mutation_fingerprint(&conn), before);
    drop(prepared);

    let read_only = open_scan_snapshot(&db_path).expect("open read-only snapshot");
    let error = read_only
      .execute(
        "UPDATE sync_settings SET updated_at = 'forbidden' WHERE singleton_id = 1",
        [],
      )
      .expect_err("read-only snapshot must reject writes");
    assert!(matches!(
      error,
      rusqlite::Error::SqliteFailure(ref sqlite_error, _)
        if sqlite_error.code == rusqlite::ErrorCode::ReadOnly
    ));
  }

  #[test]
  fn prepared_scan_exposes_read_only_runtime_metadata_and_is_send() {
    fn assert_send_static<T: Send + 'static>() {}
    assert_send_static::<PreparedScan>();

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    write_session_file(
      &sessions.join("metadata.jsonl"),
      "11111111-1111-1111-1111-111111111111",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);

    let prepared = prepare_scan(&db_path, None, ScanKind::Full).expect("prepare scan");
    let stats = prepared.stats();
    assert_eq!(stats.files_visited, 1);
    assert!(stats.source_bytes_read > 0);
    assert!(stats.full_rebuild);
    assert!(!stats.used_spool);
    assert_eq!(
      prepared.source_key().selector(),
      Some(codex_home.to_string_lossy().as_ref())
    );
    assert_eq!(prepared.source_key().resolved_home(), codex_home.as_path());
  }

  #[test]
  fn prepared_scan_stays_uncommitted_until_commit() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "20202020-2020-2020-2020-202020202020";
    let session_path = sessions.join("prepared.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare scan");
    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(database_mutation_fingerprint(&conn).sessions, 0);
    drop(conn);

    std::fs::remove_file(&session_path).expect("remove parsed source");
    let result =
      commit_prepared_scan(prepared).expect("commit prepared scan without source reread");

    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, session_id).3, 110);
  }

  #[test]
  fn commit_prepared_scan_is_atomic() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let first_session_id = "30303030-3030-3030-3030-303030303030";
    let failed_session_id = "40404040-4040-4040-4040-404040404040";
    write_session_with_rate_limit_sample(&sessions.join("a-first.jsonl"), first_session_id, 110);
    write_session_file(
      &sessions.join("b-fails.jsonl"),
      failed_session_id,
      &[("2026-07-10T00:01:00Z", 200, 40, 20, 220)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);
    let prepared = prepare_scan(&db_path, None, ScanKind::Full).expect("prepare scan");

    let conn = open_connection(&db_path).expect("open database");
    conn
      .execute_batch(&format!(
        "
        CREATE TRIGGER fail_second_prepared_session
        BEFORE INSERT ON sessions
        WHEN NEW.session_id = '{failed_session_id}'
        BEGIN
          SELECT RAISE(ABORT, 'forced mid-commit failure');
        END;
        "
      ))
      .expect("install failure trigger");
    let before = database_mutation_fingerprint(&conn);
    drop(conn);

    let error = commit_prepared_scan(prepared).expect_err("commit must fail");
    assert!(error.contains("forced mid-commit failure"));

    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(database_mutation_fingerprint(&conn), before);
  }

  #[test]
  fn commit_checks_full_scan_guard_before_freshness_write() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).expect("Codex home");
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);
    let mut prepared = prepare_scan(&db_path, None, ScanKind::Full).expect("prepare scan");
    prepared.freshness_full_scan_required = !prepared.freshness_full_scan_required;

    let conn = open_connection(&db_path).expect("open database");
    conn
      .execute_batch(
        "
        CREATE TRIGGER reject_freshness_write
        BEFORE UPDATE ON sync_settings
        BEGIN
          SELECT RAISE(ABORT, 'freshness write happened before guard');
        END;
        ",
      )
      .expect("install freshness trigger");
    drop(conn);

    let error = commit_prepared_scan(prepared).expect_err("reject mismatched freshness plan");
    assert!(
      error.contains("freshness changed"),
      "unexpected error: {error}"
    );
    assert!(!error.contains("freshness write happened"));
  }

  #[test]
  fn commit_rejects_changed_source_without_prepared_writes() {
    let directory = tempdir().expect("tempdir");
    let first_codex_home = directory.path().join("codex-home-a");
    let second_codex_home = directory.path().join("codex-home-b");
    let sessions = first_codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    std::fs::create_dir_all(&second_codex_home).expect("second source");
    write_session_file(
      &sessions.join("stale.jsonl"),
      "50505050-5050-5050-5050-505050505050",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &first_codex_home);
    let prepared = prepare_scan(&db_path, None, ScanKind::Full).expect("prepare first source");

    configure_codex_home(&db_path, &second_codex_home);
    let conn = open_connection(&db_path).expect("open database");
    let before = database_mutation_fingerprint(&conn);
    drop(conn);

    let error = commit_prepared_scan(prepared).expect_err("reject stale prepared source");
    assert!(error.contains("source changed"));

    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(database_mutation_fingerprint(&conn), before);
  }

  #[test]
  fn override_commit_ignores_unrelated_default_source_change() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let first_default_home = directory.path().join("default-a");
    let second_default_home = directory.path().join("default-b");
    let scanned_home = directory.path().join("explicit-override");
    let sessions = scanned_home.join("sessions");
    std::fs::create_dir_all(&first_default_home).expect("first default source");
    std::fs::create_dir_all(&second_default_home).expect("second default source");
    std::fs::create_dir_all(&sessions).expect("override sessions");
    let session_id = "53535353-5353-5353-5353-535353535353";
    write_session_file(
      &sessions.join("override.jsonl"),
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    let _environment = CodexHomeEnvGuard::set(&first_default_home);

    let prepared = prepare_scan(
      &db_path,
      Some(scanned_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare override scan");
    std::env::set_var("CODEX_HOME", &second_default_home);

    commit_prepared_scan(prepared).expect("commit override scan");
    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(session_usage_totals(&conn, session_id).3, 110);
  }

  #[test]
  fn same_source_scan_commit_after_prepare_is_rejected_without_writes() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "51515151-5151-5151-5151-515151515151";
    let session_path = sessions.join("same-source.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);
    commit_prepared_scan(prepare_scan(&db_path, None, ScanKind::Full).expect("prepare full"))
      .expect("commit full");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );

    let stale = prepare_scan(&db_path, None, ScanKind::Incremental).expect("prepare stale scan");
    let winner = prepare_scan(&db_path, None, ScanKind::Incremental).expect("prepare winning scan");
    commit_prepared_scan(winner).expect("commit winning scan");
    let conn = open_connection(&db_path).expect("open database");
    let before = database_mutation_fingerprint(&conn);
    drop(conn);

    let error = commit_prepared_scan(stale).expect_err("reject stale same-source scan");
    assert!(error.contains("source changed") || error.contains("stale"));
    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(database_mutation_fingerprint(&conn), before);
  }

  #[test]
  fn untracked_override_rejects_same_source_commit_after_prepare() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let default_home = directory.path().join("default-home");
    let scanned_home = directory.path().join("explicit-override");
    let sessions = scanned_home.join("sessions");
    std::fs::create_dir_all(&default_home).expect("default source");
    std::fs::create_dir_all(&sessions).expect("override sessions");
    let _environment = CodexHomeEnvGuard::set(&default_home);
    let session_id = "54545454-5454-5454-5454-545454545454";
    let session_path = sessions.join("untracked-override.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    let source_override = Some(scanned_home.to_string_lossy().to_string());
    commit_prepared_scan(
      prepare_scan(&db_path, source_override.clone(), ScanKind::Full)
        .expect("prepare initial scan"),
    )
    .expect("commit initial scan");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );

    let stale = prepare_scan(&db_path, source_override.clone(), ScanKind::Incremental)
      .expect("prepare stale override scan");
    let winner = prepare_scan(&db_path, source_override, ScanKind::Incremental)
      .expect("prepare winning override scan");
    commit_prepared_scan(winner).expect("commit winning override scan");
    let conn = open_connection(&db_path).expect("open database");
    let before = database_mutation_fingerprint(&conn);
    drop(conn);

    let error = commit_prepared_scan(stale).expect_err("reject stale override scan");
    assert!(error.contains("source changed") || error.contains("stale"));
    let conn = open_connection(&db_path).expect("reopen database");
    assert_eq!(database_mutation_fingerprint(&conn), before);
  }

  #[test]
  fn prepare_stats_count_only_bytes_consumed_before_parse_failure() {
    use std::io::Write;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_path = sessions.join("partial-read.jsonl");
    let mut file = File::create(&session_path).expect("session file");
    writeln!(
      file,
      "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"52525252-5252-5252-5252-525252525252\"}}}}"
    )
    .expect("write metadata");
    file.write_all(&[0xff, b'\n']).expect("write invalid utf8");
    file
      .write_all(&vec![b' '; 32 * 1024])
      .expect("write unread tail");
    drop(file);
    let file_size = std::fs::metadata(&session_path).expect("metadata").len();
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare scan with unreadable file");

    assert!(prepared.stats().source_bytes_read > 0);
    assert!(prepared.stats().source_bytes_read < file_size);
  }

  #[test]
  fn small_incremental_prepare_stays_in_memory() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "60606060-6060-6060-6060-606060606060";
    let session_path = sessions.join("small.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare incremental scan");

    assert!(!prepared.uses_spool());
  }

  #[test]
  fn incremental_prepare_drops_full_title_index_after_parsing() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "67676767-6767-6767-6767-676767676767";
    let session_path = sessions.join("title-update.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");

    let mut title_index =
      format!("{{\"id\":\"{session_id}\",\"thread_name\":\"Incremental title\"}}\n");
    for index in 0..2_000 {
      title_index.push_str(&format!(
        "{{\"id\":\"unrelated-{index}\",\"thread_name\":\"Unused title {index}\"}}\n"
      ));
    }
    std::fs::write(codex_home.join("session_index.jsonl"), title_index).expect("write title index");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare incremental title update");

    assert_eq!(prepared.effective_kind, ScanKind::Incremental);
    assert!(prepared.titles.is_empty());
    assert_eq!(prepared.titles.capacity(), 0);
    let parsed_title = match &prepared.storage {
      PreparedStorage::Memory(entries) => entries[0].parsed.raw_session.title.as_deref(),
      PreparedStorage::Spool { .. } => panic!("small title update should stay in memory"),
    };
    assert_eq!(parsed_title, Some("Incremental title"));
    commit_prepared_scan(prepared).expect("commit incremental title update");
    let conn = open_connection(&db_path).expect("open database");
    let title: String = conn
      .query_row(
        "SELECT title FROM sessions WHERE session_id = ?1",
        params![session_id],
        |row| row.get(0),
      )
      .expect("load updated title");
    assert_eq!(title, "Incremental title");
  }

  #[test]
  fn single_large_incremental_stays_in_memory() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "70707070-7070-7070-7070-707070707070";
    let session_path = sessions.join("large.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");
    write_large_session_file(
      &session_path,
      session_id,
      PREPARED_SPOOL_THRESHOLD_BYTES * 4,
    );

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare large scan");

    assert!(!prepared.uses_spool());
    assert!(!prepared.stats().used_spool);
    assert_eq!(prepared.updated_sessions, 1);
  }

  #[test]
  fn multiple_changed_sessions_spill() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    write_large_session_file(
      &sessions.join("a-large.jsonl"),
      "74747474-7474-7474-7474-747474747474",
      PREPARED_SPOOL_THRESHOLD_BYTES * 2,
    );
    write_session_file(
      &sessions.join("z-second.jsonl"),
      "75757575-7575-7575-7575-757575757575",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare multiple changed sessions");

    assert!(prepared.uses_spool());
    assert!(prepared.stats().used_spool);
  }

  #[cfg(unix)]
  #[test]
  fn spool_file_is_anonymous_and_unlinked() {
    use std::os::unix::fs::MetadataExt;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    write_large_session_file(
      &sessions.join("a-large.jsonl"),
      "76767676-7676-7676-7676-767676767676",
      PREPARED_SPOOL_THRESHOLD_BYTES * 2,
    );
    write_session_file(
      &sessions.join("z-second.jsonl"),
      "77777777-7777-7777-7777-777777777777",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare anonymous spool");
    let link_count = match &prepared.storage {
      PreparedStorage::Memory(_) => panic!("expected spool storage"),
      PreparedStorage::Spool { file, .. } => file.metadata().expect("spool metadata").nlink(),
    };

    assert_eq!(link_count, 0, "spool must have no directory entry");
  }

  #[cfg(unix)]
  #[test]
  fn spool_compresses_repetitive_prepared_records() {
    let mut builder = PreparedStorageBuilder::new();
    builder
      .push(prepared_session_fixture(
        PathBuf::from("/synthetic/a-large.jsonl"),
        "80808080-8080-8080-8080-808080808080",
        PREPARED_SPOOL_THRESHOLD_BYTES * 2,
      ))
      .expect("buffer first large record");
    builder
      .push(prepared_session_fixture(
        PathBuf::from("/synthetic/b-large.jsonl"),
        "81818181-8181-8181-8181-818181818181",
        PREPARED_SPOOL_THRESHOLD_BYTES * 2,
      ))
      .expect("spill second large record");

    let storage = builder.finish().expect("finish compressed spool");
    let bytes = match storage {
      PreparedStorage::Memory(_) => panic!("expected spool storage"),
      PreparedStorage::Spool { file, records } => {
        assert_eq!(records, 2);
        file.metadata().expect("spool metadata").len()
      }
    };

    assert!(
      bytes < 64 * 1024,
      "repetitive prepared records should compress below 64 KiB, got {bytes}"
    );
  }

  #[cfg(unix)]
  #[test]
  fn non_utf8_session_path_matches_memory_and_spool_round_trip() {
    use std::os::unix::ffi::OsStringExt;

    let session_id = "78787878-7878-7878-7878-787878787878";
    let non_utf8_path = PathBuf::from(std::ffi::OsString::from_vec(
      b"/synthetic/00-non-utf8-\x80.jsonl".to_vec(),
    ));
    let expected_path = non_utf8_path.to_string_lossy().to_string();
    let mut memory_builder = PreparedStorageBuilder::new();
    memory_builder
      .push(prepared_session_fixture(
        non_utf8_path.clone(),
        session_id,
        1,
      ))
      .expect("keep non-UTF-8 entry in memory");
    let memory_storage = memory_builder.finish().expect("finish memory storage");
    assert!(matches!(&memory_storage, PreparedStorage::Memory(_)));

    let mut spool_builder = PreparedStorageBuilder::new();
    spool_builder
      .push(prepared_session_fixture(non_utf8_path, session_id, 1))
      .expect("buffer non-UTF-8 entry");
    spool_builder
      .push(prepared_session_fixture(
        PathBuf::from("/synthetic/zz-large.jsonl"),
        "79797979-7979-7979-7979-797979797979",
        PREPARED_SPOOL_THRESHOLD_BYTES * 2,
      ))
      .expect("spill entries without serializing PathBuf directly");
    let spool_storage = spool_builder.finish().expect("finish spool storage");
    assert!(matches!(
      &spool_storage,
      PreparedStorage::Spool { records: 2, .. }
    ));

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).expect("Codex home");
    let persist_and_load = |db_path: &Path, storage: PreparedStorage| {
      initialize_scan_database(db_path);
      let mut prepared = prepare_scan(
        db_path,
        Some(codex_home.to_string_lossy().to_string()),
        ScanKind::Full,
      )
      .expect("prepare empty scan shell");
      prepared.storage = storage;
      prepared.imported_sessions = 1;
      prepared.updated_sessions = 1;
      commit_prepared_scan(prepared).expect("commit synthetic prepared scan");
      let conn = open_connection(db_path).expect("open committed database");
      conn
        .query_row(
          "
          SELECT sessions.source_path, import_state.source_path,
                 COALESCE(SUM(usage_events.total_tokens), 0)
          FROM sessions
          JOIN import_state USING (session_id)
          LEFT JOIN usage_events USING (session_id)
          WHERE sessions.session_id = ?1
          GROUP BY sessions.source_path, import_state.source_path
          ",
          params![session_id],
          |row| {
            Ok((
              row.get::<_, String>(0)?,
              row.get::<_, String>(1)?,
              row.get::<_, i64>(2)?,
            ))
          },
        )
        .expect("load persisted prepared entry")
    };

    let memory_result = persist_and_load(&directory.path().join("memory.sqlite"), memory_storage);
    let spool_result = persist_and_load(&directory.path().join("spool.sqlite"), spool_storage);
    assert_eq!(spool_result, memory_result);
    assert_eq!(memory_result, (expected_path.clone(), expected_path, 10));
  }

  #[test]
  fn prepared_scan_started_at_includes_parse_time() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "73737373-7373-7373-7373-737373737373";
    let mut body = format!(
      concat!(
        "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}\n"
      ),
      session_id
    );
    let mut total_tokens = 0i64;
    while body.len() <= PREPARED_SPOOL_THRESHOLD_BYTES * 32 {
      total_tokens += 10;
      body.push_str(&token_count_line(TokenFixture {
        timestamp: "2026-07-10T00:00:02Z",
        total: (total_tokens, 0, 0, total_tokens),
        last: (10, 0, 0, 10),
      }));
    }
    std::fs::write(sessions.join("timed.jsonl"), body).expect("write timed session");
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare timed scan");
    let scan_started_at =
      chrono::DateTime::parse_from_rfc3339(&prepared.scan_started_at).expect("parse scan start");
    let elapsed = chrono::Utc::now().signed_duration_since(scan_started_at);

    assert!(
      elapsed >= chrono::Duration::milliseconds(10),
      "scan start should precede parsing, elapsed={elapsed:?}"
    );
  }

  #[test]
  fn spooled_commit_preserves_last_usage_with_anonymous_file() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "71717171-7171-7171-7171-717171717171";
    let missing_parent_id = "72727272-7272-7272-7272-727272727272";
    let mut body = format!(
      concat!(
        "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}\n"
      ),
      session_id, missing_parent_id,
    );
    let mut snapshots = 0i64;
    let mut total_tokens = 1_000i64;
    while body.len() <= PREPARED_SPOOL_THRESHOLD_BYTES * 3 {
      if snapshots > 0 {
        total_tokens += 10;
      }
      body.push_str(&token_count_line(TokenFixture {
        timestamp: "2026-07-10T00:00:02Z",
        total: (total_tokens, 0, 0, total_tokens),
        last: (10, 0, 0, 10),
      }));
      snapshots += 1;
    }
    std::fs::write(sessions.join("a-spooled-fork.jsonl"), body).expect("write fork session");
    write_session_file(
      &sessions.join("z-spool-filler.jsonl"),
      "72727272-7272-7272-7272-727272727273",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare spooled fork");
    assert!(prepared.stats().used_spool);

    commit_prepared_scan(prepared).expect("commit spooled fork");

    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(session_usage_totals(&conn, session_id).3, snapshots * 10);
  }

  #[test]
  fn prepared_estimates_include_reserved_vec_and_string_capacity() {
    let mut model_id = String::with_capacity(4 * 1024);
    model_id.push('x');
    let mut snapshots = Vec::with_capacity(64);
    snapshots.push(UsageSnapshot {
      timestamp: "2026-07-10T00:00:00Z".to_string(),
      model_id,
      usage: replay_usage((10, 0, 0, 0, 10)),
      last_token_usage: Some(replay_usage((10, 0, 0, 0, 10))),
      plan_type: None,
      limit_id: None,
      limit_name: None,
      explicit_fast_mode: None,
    });

    let estimate = estimated_usage_snapshots_bytes(&snapshots);

    assert!(estimate >= snapshots.capacity() * std::mem::size_of::<UsageSnapshot>());
    assert!(estimate >= snapshots[0].model_id.capacity());
  }

  #[test]
  fn bounded_parent_replay_cache_evicts_without_changing_fork_results() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let pair_count = PARENT_REPLAY_CACHE_MAX_ENTRIES + 1;
    let mut child_session_ids = Vec::new();
    for index in 0..pair_count {
      let parent_session_id = format!("90000000-0000-0000-0000-{index:012x}");
      let child_session_id = format!("a0000000-0000-0000-0000-{index:012x}");
      write_replay_cache_pair(&sessions, index, &parent_session_id, &child_session_id);
      child_session_ids.push(child_session_id);
    }
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare replay pairs");

    assert!(prepared.parent_replay_cache_evictions() > 0);
    commit_prepared_scan(prepared).expect("commit replay pairs");
    let conn = open_connection(&db_path).expect("open database");
    for child_session_id in child_session_ids {
      assert_eq!(session_usage_totals(&conn, &child_session_id).3, 10);
    }
  }

  #[test]
  fn oversized_parent_replay_cache_entry_is_bypassed_not_evicted() {
    let oversized_model_id = "x".repeat(PARENT_REPLAY_CACHE_MAX_BYTES);
    let snapshots = vec![replay_snapshot(
      "2026-07-10T00:00:00Z",
      &oversized_model_id,
      (10, 0, 0, 10, 10),
      Some((10, 0, 0, 10, 10)),
    )];
    let mut cache = ParentReplayCache::new();

    cache.insert("oversized-parent".to_string(), Some(snapshots));

    assert_eq!(cache.evictions(), 0);
    assert_eq!(cache.oversized_bypasses(), 1);
    assert!(cache.get("oversized-parent").is_none());
  }

  #[test]
  fn parent_replay_cache_counts_reserved_capacity_toward_its_limit() {
    let mut reserved_key = String::with_capacity(PARENT_REPLAY_CACHE_MAX_BYTES + 1);
    reserved_key.push('p');
    let mut key_cache = ParentReplayCache::new();

    key_cache.insert(reserved_key, None);

    assert_eq!(key_cache.evictions(), 0);
    assert_eq!(key_cache.oversized_bypasses(), 1);
    assert!(key_cache.get("p").is_none());
    assert!(key_cache.estimated_bytes <= PARENT_REPLAY_CACHE_MAX_BYTES);

    let snapshot_capacity = PARENT_REPLAY_CACHE_MAX_BYTES
      .checked_div(std::mem::size_of::<UsageSnapshot>())
      .unwrap_or_default()
      + 1;
    let mut snapshots = Vec::with_capacity(snapshot_capacity);
    snapshots.push(replay_snapshot(
      "2026-07-10T00:00:00Z",
      "gpt-5.6-sol",
      (10, 0, 0, 10, 10),
      Some((10, 0, 0, 10, 10)),
    ));
    let mut snapshot_cache = ParentReplayCache::new();

    snapshot_cache.insert("reserved-snapshots".to_string(), Some(snapshots));

    assert_eq!(snapshot_cache.evictions(), 0);
    assert_eq!(snapshot_cache.oversized_bypasses(), 1);
    assert!(snapshot_cache.get("reserved-snapshots").is_none());
    assert!(snapshot_cache.estimated_bytes <= PARENT_REPLAY_CACHE_MAX_BYTES);
  }

  #[test]
  fn prepared_stats_include_parent_replay_bytes() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let parent_session_id = "91919191-9191-9191-9191-919191919191";
    let child_session_id = "92929292-9292-9292-9292-929292929292";
    write_replay_cache_pair(&sessions, 0, parent_session_id, child_session_id);
    let main_scan_bytes = std::fs::read_dir(&sessions)
      .expect("read sessions")
      .map(|entry| {
        entry
          .expect("session entry")
          .metadata()
          .expect("metadata")
          .len()
      })
      .sum::<u64>();
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Full,
    )
    .expect("prepare replay pair");

    assert!(prepared.stats().source_bytes_read > main_scan_bytes);
  }

  #[test]
  fn full_and_incremental_wrappers_match_prepared_scan_results() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "80808080-8080-8080-8080-808080808080";
    let session_path = sessions.join("compatibility.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let direct_db_path = directory.path().join("direct.sqlite");
    let wrapper_db_path = directory.path().join("wrapper.sqlite");
    initialize_scan_database(&direct_db_path);

    let direct_full = commit_prepared_scan(
      prepare_scan(
        &direct_db_path,
        Some(codex_home.to_string_lossy().to_string()),
        ScanKind::Full,
      )
      .expect("prepare direct full scan"),
    )
    .expect("commit direct full scan");
    let wrapper_full = perform_scan(
      &wrapper_db_path,
      Some(codex_home.to_string_lossy().to_string()),
    )
    .expect("wrapper full scan");
    assert_scan_results_equivalent(&direct_full, &wrapper_full);

    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );
    let direct_incremental = commit_prepared_scan(
      prepare_scan(
        &direct_db_path,
        Some(codex_home.to_string_lossy().to_string()),
        ScanKind::Incremental,
      )
      .expect("prepare direct incremental scan"),
    )
    .expect("commit direct incremental scan");
    let wrapper_incremental = perform_incremental_scan(
      &wrapper_db_path,
      Some(codex_home.to_string_lossy().to_string()),
    )
    .expect("wrapper incremental scan");
    assert_scan_results_equivalent(&direct_incremental, &wrapper_incremental);

    let direct_conn = open_connection(&direct_db_path).expect("open direct database");
    let wrapper_conn = open_connection(&wrapper_db_path).expect("open wrapper database");
    assert_eq!(
      session_usage_totals(&direct_conn, session_id),
      session_usage_totals(&wrapper_conn, session_id)
    );
  }

  #[test]
  fn parent_replay_reader_rejects_malformed_token_candidate_between_snapshots() {
    let directory = tempdir().expect("tempdir");
    let parent_session_id = "10101010-1010-4010-8010-101010101010";
    let parent_path = directory.path().join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let mut body = format!(
      "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{parent_session_id}\"}}}}\n"
    );
    body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    }));
    body.push_str(
      "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":\n",
    );
    body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:03Z",
      total: (180, 0, 0, 180),
      last: (80, 0, 0, 80),
    }));
    std::fs::write(&parent_path, body).expect("write malformed replay parent");

    assert!(read_parent_replay_snapshots(&parent_path, parent_session_id).is_err());
  }

  #[test]
  fn parent_replay_reader_rejects_token_count_without_timestamp() {
    let directory = tempdir().expect("tempdir");
    let parent_session_id = "20202020-2020-4020-8020-202020202020";
    let parent_path = directory.path().join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let mut body = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    });
    body.push_str(concat!(
      "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{",
      "\"total_token_usage\":{\"input_tokens\":180,\"cached_input_tokens\":0,",
      "\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":180}}}}\n"
    ));
    std::fs::write(&parent_path, body).expect("write replay parent without timestamp");

    assert!(read_parent_replay_snapshots(&parent_path, parent_session_id).is_err());
  }

  #[test]
  fn parent_replay_reader_rejects_token_count_without_total_usage() {
    let directory = tempdir().expect("tempdir");
    let parent_session_id = "30303030-3030-4030-8030-303030303030";
    let parent_path = directory.path().join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let mut body = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    });
    body.push_str(concat!(
      "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"event_msg\",",
      "\"payload\":{\"type\":\"token_count\",\"info\":{",
      "\"last_token_usage\":{\"input_tokens\":80,\"cached_input_tokens\":0,",
      "\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":80}}}}\n"
    ));
    std::fs::write(&parent_path, body).expect("write replay parent without total usage");

    assert!(read_parent_replay_snapshots(&parent_path, parent_session_id).is_err());
  }

  #[test]
  fn parent_replay_reader_rejects_non_numeric_token_usage() {
    let directory = tempdir().expect("tempdir");
    let parent_session_id = "40404040-4040-4040-8040-404040404040";
    let parent_path = directory.path().join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let body = concat!(
      "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"event_msg\",",
      "\"payload\":{\"type\":\"token_count\",\"info\":{",
      "\"total_token_usage\":{\"input_tokens\":\"not-a-number\",\"cached_input_tokens\":0,",
      "\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":100}}}}\n"
    );
    std::fs::write(&parent_path, body).expect("write replay parent with invalid usage");

    assert!(read_parent_replay_snapshots(&parent_path, parent_session_id).is_err());
  }

  #[test]
  fn parent_replay_reader_ignores_nested_token_types_in_unrelated_root_record() {
    let directory = tempdir().expect("tempdir");
    let parent_session_id = "50505050-5050-4050-8050-505050505050";
    let parent_path = directory.path().join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let mut body = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    });
    body.push_str(concat!(
      "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"response_item\",",
      "\"payload\":{\"message\":{\"type\":\"event_msg\",\"payload\":{",
      "\"type\":\"token_count\",\"info\":{\"total_token_usage\":{",
      "\"input_tokens\":900,\"cached_input_tokens\":0,\"output_tokens\":0,",
      "\"reasoning_output_tokens\":0,\"total_tokens\":900}}}}}}\n"
    ));
    std::fs::write(&parent_path, body).expect("write replay parent with nested token types");

    let snapshots = read_parent_replay_snapshots(&parent_path, parent_session_id)
      .expect("ignore unrelated nested token fields");
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].usage.total_tokens, 100);
  }

  #[test]
  fn replay_matching_accepts_a_complete_three_record_match() {
    let parent = vec![
      replay_snapshot(
        "2026-03-24T00:00:01Z",
        "parent-a",
        (100, 10, 20, 1, 121),
        Some((100, 10, 20, 1, 121)),
      ),
      replay_snapshot(
        "2026-03-24T00:01:01Z",
        "parent-b",
        (180, 20, 35, 2, 217),
        Some((80, 10, 15, 1, 96)),
      ),
      replay_snapshot(
        "2026-03-24T00:02:01Z",
        "parent-c",
        (260, 30, 50, 3, 313),
        Some((80, 10, 15, 1, 96)),
      ),
    ];
    let child = vec![
      replay_snapshot(
        "2026-03-24T00:10:00Z",
        "child-x",
        (100, 10, 20, 1, 121),
        Some((100, 10, 20, 1, 121)),
      ),
      replay_snapshot(
        "2026-03-24T00:10:00Z",
        "child-y",
        (180, 20, 35, 2, 217),
        Some((80, 10, 15, 1, 96)),
      ),
      replay_snapshot(
        "2026-03-24T00:10:00Z",
        "child-z",
        (260, 30, 50, 3, 313),
        Some((80, 10, 15, 1, 96)),
      ),
    ];

    assert_eq!(
      replayed_child_snapshot_cutoff(&parent, &child, Some(fork_instant("2026-03-24T00:05:00Z")),),
      3
    );
  }

  #[test]
  fn replay_matching_finds_a_child_prefix_in_the_middle_of_the_parent() {
    let unrelated = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "parent",
      (20, 0, 5, 0, 25),
      Some((20, 0, 5, 0, 25)),
    );
    let first = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "parent",
      (100, 10, 20, 1, 121),
      Some((80, 10, 15, 1, 96)),
    );
    let second = replay_snapshot(
      "2026-03-24T00:02:00Z",
      "parent",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );
    let third = replay_snapshot(
      "2026-03-24T00:03:00Z",
      "parent",
      (260, 30, 50, 3, 313),
      Some((80, 10, 15, 1, 96)),
    );
    let parent = vec![unrelated, first.clone(), second.clone(), third.clone()];
    let child = vec![first, second, third];

    assert_eq!(
      replayed_child_snapshot_cutoff(&parent, &child, Some(fork_instant("2026-03-24T00:04:00Z")),),
      3
    );
  }

  #[test]
  fn replay_matching_rejects_one_exact_record_from_longer_parent() {
    let record = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let parent_second = replay_snapshot(
      "2026-03-24T00:00:30Z",
      "model",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );

    assert_eq!(
      replayed_child_snapshot_cutoff(
        &[record.clone(), parent_second],
        std::slice::from_ref(&record),
        Some(fork_instant("2026-03-24T00:01:00Z")),
      ),
      0
    );
  }

  #[test]
  fn replay_matching_missing_last_usage_breaks_the_match() {
    let first = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let parent_second = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "model",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );
    let child_second =
      replay_snapshot("2026-03-24T00:01:00Z", "model", (180, 20, 35, 2, 217), None);

    assert_eq!(
      replayed_child_snapshot_cutoff(
        &[first.clone(), parent_second],
        &[first, child_second],
        Some(fork_instant("2026-03-24T00:02:00Z")),
      ),
      0
    );
  }

  #[test]
  fn replay_matching_omits_same_total_changed_last_from_the_canonical_sequence() {
    let first = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let changed_last = replay_snapshot(
      "2026-03-24T00:00:30Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((1, 2, 3, 4, 10)),
    );
    let second = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "model",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );

    assert_eq!(
      replayed_child_snapshot_cutoff(
        &[first.clone(), second.clone()],
        &[first, changed_last, second],
        Some(fork_instant("2026-03-24T00:02:00Z")),
      ),
      3
    );
  }

  #[test]
  fn replay_matching_uses_cumulative_high_water_after_a_rollback() {
    let first = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let rollback = replay_snapshot(
      "2026-03-24T00:00:30Z",
      "model",
      (70, 5, 10, 0, 80),
      Some((5, 0, 2, 0, 7)),
    );
    let recovery = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "model",
      (140, 15, 30, 2, 172),
      Some((40, 5, 10, 1, 51)),
    );

    assert_eq!(
      replayed_child_snapshot_cutoff(
        &[first.clone(), recovery.clone()],
        &[first, rollback, recovery],
        Some(fork_instant("2026-03-24T00:02:00Z")),
      ),
      3
    );
  }

  #[test]
  fn replay_matching_excludes_parent_records_after_the_fork_instant() {
    let first = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let second = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "model",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );
    let post_fork = replay_snapshot(
      "2026-03-24T00:06:00Z",
      "model",
      (260, 30, 50, 3, 313),
      Some((80, 10, 15, 1, 96)),
    );

    assert_eq!(
      replayed_child_snapshot_cutoff(
        &[first.clone(), second.clone(), post_fork.clone()],
        &[first, second, post_fork],
        Some(fork_instant("2026-03-24T00:05:00Z")),
      ),
      2
    );
  }

  #[test]
  fn replay_matching_without_a_valid_fork_instant_returns_zero() {
    let first = replay_snapshot(
      "2026-03-24T00:00:00Z",
      "model",
      (100, 10, 20, 1, 121),
      Some((100, 10, 20, 1, 121)),
    );
    let second = replay_snapshot(
      "2026-03-24T00:01:00Z",
      "model",
      (180, 20, 35, 2, 217),
      Some((80, 10, 15, 1, 96)),
    );

    assert_eq!(
      replayed_child_snapshot_cutoff(&[first.clone(), second.clone()], &[first, second], None,),
      0
    );
  }

  #[test]
  fn parser_retains_last_usage_and_matching_explicit_fork_metadata() {
    let directory = tempdir().expect("tempdir");
    let child_id = "55555555-5555-5555-5555-555555555555";
    let parent_id = "44444444-4444-4444-4444-444444444444";
    let session_path = directory
      .path()
      .join(format!("rollout-2026-03-24T00-30-00-{child_id}.jsonl"));
    std::fs::write(
      &session_path,
      format!(
        concat!(
          "{{\"timestamp\":\"2026-03-24T08:30:00+08:00\",\"type\":\"session_meta\",",
          "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
          "{{\"timestamp\":\"2026-03-24T00:30:01Z\",\"type\":\"event_msg\",",
          "\"payload\":{{\"type\":\"token_count\",\"info\":{{",
          "\"total_token_usage\":{{\"input_tokens\":180,\"cached_input_tokens\":20,",
          "\"output_tokens\":35,\"reasoning_output_tokens\":2,\"total_tokens\":217}},",
          "\"last_token_usage\":{{\"input_tokens\":80,\"cached_input_tokens\":10,",
          "\"output_tokens\":15,\"reasoning_output_tokens\":1,\"total_tokens\":96}}",
          "}}}}}}\n",
          "{{\"timestamp\":\"2026-03-24T00:30:02Z\",\"type\":\"session_meta\",",
          "\"payload\":{{\"id\":\"{}\"}}}}\n"
        ),
        child_id, parent_id, parent_id,
      ),
    )
    .expect("write fork session");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "active".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse fork session");

    assert_eq!(
      parsed.snapshots[0].last_token_usage,
      Some(replay_usage((80, 10, 15, 1, 96)))
    );
    assert_eq!(parsed.explicit_forked_from_id.as_deref(), Some(parent_id));
    assert_eq!(
      parsed.explicit_fork_timestamp,
      Some(fork_instant("2026-03-24T08:30:00+08:00"))
    );
    let serialized = serde_json::to_value(&parsed.snapshots[0]).expect("serialize snapshot");
    assert!(!serialized
      .as_object()
      .expect("snapshot object")
      .contains_key("lastTokenUsage"));
  }

  #[test]
  fn parser_leaves_explicit_fork_fields_empty_for_thread_spawn_only_metadata() {
    let directory = tempdir().expect("tempdir");
    let child_id = "77777777-7777-7777-7777-777777777777";
    let parent_id = "66666666-6666-6666-6666-666666666666";
    let session_path = directory
      .path()
      .join(format!("rollout-2026-03-24T01-00-00-{child_id}.jsonl"));
    std::fs::write(
      &session_path,
      format!(
        concat!(
          "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"session_meta\",",
          "\"payload\":{{\"id\":\"{}\",\"source\":{{\"subagent\":{{\"thread_spawn\":{{",
          "\"parent_thread_id\":\"{}\"}}}}}}}}}}\n"
        ),
        child_id, parent_id,
      ),
    )
    .expect("write thread-spawn session");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "active".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse thread-spawn session");

    assert_eq!(
      parsed.raw_session.parent_session_id.as_deref(),
      Some(parent_id)
    );
    assert!(parsed.explicit_forked_from_id.is_none());
    assert!(parsed.explicit_fork_timestamp.is_none());
  }

  #[test]
  fn parser_invalid_explicit_fork_timestamp_disables_replay_metadata() {
    let directory = tempdir().expect("tempdir");
    let child_id = "99999999-9999-9999-9999-999999999999";
    let parent_id = "88888888-8888-8888-8888-888888888888";
    let session_path = directory
      .path()
      .join(format!("rollout-2026-03-24T01-30-00-{child_id}.jsonl"));
    std::fs::write(
      &session_path,
      format!(
        concat!(
          "{{\"timestamp\":\"not-an-instant\",\"type\":\"session_meta\",",
          "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n"
        ),
        child_id, parent_id,
      ),
    )
    .expect("write invalid fork session");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "active".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse invalid fork session");

    assert_eq!(parsed.explicit_forked_from_id.as_deref(), Some(parent_id));
    assert!(parsed.explicit_fork_timestamp.is_none());
  }

  #[test]
  fn diff_usage_handles_growth_and_component_rollbacks() {
    let previous = TokenUsage {
      input_tokens: 10,
      cached_input_tokens: 2,
      output_tokens: 3,
      reasoning_output_tokens: 1,
      total_tokens: 13,
    };
    let current = TokenUsage {
      input_tokens: 18,
      cached_input_tokens: 5,
      output_tokens: 7,
      reasoning_output_tokens: 2,
      total_tokens: 25,
    };
    let delta = diff_usage(&previous, &current);
    assert_eq!(delta.input_tokens, 8);
    assert_eq!(delta.cached_input_tokens, 3);
    assert_eq!(delta.output_tokens, 4);
    assert_eq!(delta.reasoning_output_tokens, 1);
    assert_eq!(delta.total_tokens, 12);

    let component_rollback = TokenUsage {
      input_tokens: 28,
      cached_input_tokens: 3,
      output_tokens: 12,
      reasoning_output_tokens: 1,
      total_tokens: 40,
    };
    let delta = diff_usage(&current, &component_rollback);
    assert_eq!(delta.input_tokens, 10);
    assert_eq!(delta.cached_input_tokens, 0);
    assert_eq!(delta.output_tokens, 5);
    assert_eq!(delta.reasoning_output_tokens, 0);
    assert_eq!(delta.total_tokens, 15);
  }

  #[test]
  fn diff_usage_ignores_non_monotonic_replayed_totals() {
    let previous = TokenUsage {
      input_tokens: 18,
      cached_input_tokens: 5,
      output_tokens: 7,
      reasoning_output_tokens: 2,
      total_tokens: 25,
    };
    let replayed = TokenUsage {
      input_tokens: 17,
      cached_input_tokens: 4,
      output_tokens: 6,
      reasoning_output_tokens: 1,
      total_tokens: 24,
    };
    let delta = diff_usage(&previous, &replayed);
    assert!(is_zero_delta(&delta));
  }

  #[test]
  fn zero_delta_helper_keeps_reasoning_only_growth() {
    assert!(!is_zero_delta(&TokenUsage {
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 8,
      total_tokens: 0,
    }));
  }

  #[test]
  fn scan_prices_gpt_55_fast_mode_does_not_change_api_value() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "12121212-1212-1212-1212-121212121212";
    let session_path = sessions_dir.join("gpt55.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-04-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"12121212-1212-1212-1212-121212121212\"}}\n",
        "{\"timestamp\":\"2026-04-24T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"fast_mode\":true}}\n",
        "{\"timestamp\":\"2026-04-24T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":25,\"output_tokens\":40,\"reasoning_output_tokens\":0,\"total_tokens\":140}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
      ),
    )
    .expect("write gpt-5.5 session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let (value_usd, fast_mode_auto, fast_mode_effective): (f64, i64, i64) = conn
      .query_row(
        "SELECT value_usd, fast_mode_auto, fast_mode_effective FROM usage_events WHERE session_id = ?1",
        params![session_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
      )
      .expect("query usage");

    let standard =
      (75.0 / 1_000_000.0) * 5.0 + (25.0 / 1_000_000.0) * 0.5 + (40.0 / 1_000_000.0) * 30.0;
    assert!((value_usd - standard).abs() < 1e-9);
    assert_eq!(fast_mode_auto, 0);
    assert_eq!(fast_mode_effective, 0);
  }

  #[test]
  fn scan_prices_gpt_56_sol_at_standard_api_equivalent_value() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "56565656-5656-5656-5656-565656565656";
    let session_path = sessions_dir.join("gpt56-sol.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-07-09T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"56565656-5656-5656-5656-565656565656\"}}\n",
        "{\"timestamp\":\"2026-07-09T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}\n",
        "{\"timestamp\":\"2026-07-09T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":25,\"output_tokens\":40,\"reasoning_output_tokens\":0,\"total_tokens\":140}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
      ),
    )
    .expect("write GPT-5.6 Sol session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let (input_tokens, cached_input_tokens, output_tokens, total_tokens, value_usd): (
      i64,
      i64,
      i64,
      i64,
      f64,
    ) = conn
      .query_row(
        "
        SELECT input_tokens, cached_input_tokens, output_tokens, total_tokens, value_usd
        FROM usage_events
        WHERE session_id = ?1
        ",
        params![session_id],
        |row| {
          Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
          ))
        },
      )
      .expect("query usage");

    assert_eq!(input_tokens, 100);
    assert_eq!(cached_input_tokens, 25);
    assert_eq!(output_tokens, 40);
    assert_eq!(total_tokens, 140);
    let standard =
      (75.0 / 1_000_000.0) * 5.0 + (25.0 / 1_000_000.0) * 0.5 + (40.0 / 1_000_000.0) * 30.0;
    assert!((value_usd - standard).abs() < 1e-9);
  }

  #[test]
  fn import_state_mismatch_reimports_even_when_file_metadata_is_unchanged() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("archived dir");

    let child_session_id = "019d4f72-a2ee-77a0-bd4a-76f43b7b299b";
    let wrong_session_id = "019d4d7c-457e-7020-8b5f-7940eb5e3716";
    let session_path = sessions_dir.join(format!(
      "rollout-2026-04-03T02-26-46-{child_session_id}.jsonl"
    ));
    write_session_file_with_parent(
      &session_path,
      child_session_id,
      Some(wrong_session_id),
      &[("2026-04-02T18:26:46.507Z", 100, 20, 25, 125)],
    );

    let metadata = std::fs::metadata(&session_path).expect("metadata");
    let file_size = metadata.len() as i64;
    let file_mtime_ms = metadata
      .modified()
      .ok()
      .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
      .map(|duration| duration.as_millis() as i64)
      .unwrap_or_default();

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open db");
    init_db(&conn).expect("init db");
    conn
      .execute(
        "
        INSERT INTO import_state (source_path, session_id, source_bucket, file_size, file_mtime_ms, last_imported_at)
        VALUES (?1, ?2, 'archived', ?3, ?4, ?5)
        ",
        params![
          session_path.to_string_lossy().to_string(),
          wrong_session_id,
          file_size,
          file_mtime_ms,
          now_utc_string(),
        ],
      )
      .expect("insert stale import state");
    drop(conn);

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let repaired_session_id: Option<String> = conn
      .query_row(
        "SELECT session_id FROM import_state WHERE source_path = ?1",
        params![session_path.to_string_lossy().to_string()],
        |row| row.get(0),
      )
      .optional()
      .expect("query repaired import state");
    assert_eq!(repaired_session_id.as_deref(), Some(child_session_id));
    assert_eq!(
      session_usage_totals(&conn, child_session_id),
      (100, 20, 25, 125, 1)
    );
  }

  #[test]
  fn parser_keeps_parent_session_and_dedupes_model_context() {
    let directory = tempdir().expect("tempdir");
    let session_path = directory.path().join("sample.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"root-child\",\"forked_from_id\":\"root-parent\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"root-parent\",\"agent_nickname\":\"Hume\",\"agent_role\":\"explorer\"}}}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":25,\"reasoning_output_tokens\":5,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":25,\"reasoning_output_tokens\":5,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
      ),
    )
    .expect("write sample");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "active".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse");

    assert_eq!(
      parsed.raw_session.parent_session_id.as_deref(),
      Some("root-parent")
    );
    assert_eq!(parsed.raw_session.agent_nickname.as_deref(), Some("Hume"));
    assert_eq!(parsed.snapshots.len(), 2);
    assert_eq!(parsed.latest_plan_type.as_deref(), Some("pro"));
  }

  #[test]
  fn parser_prefers_file_matching_session_meta_when_fork_file_replays_parent_meta() {
    let directory = tempdir().expect("tempdir");
    let session_path = directory
      .path()
      .join("rollout-2026-03-24T00-00-00-55555555-5555-5555-5555-555555555555.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"55555555-5555-5555-5555-555555555555\",\"forked_from_id\":\"44444444-4444-4444-4444-444444444444\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"44444444-4444-4444-4444-444444444444\",\"agent_nickname\":\"Scout\",\"agent_role\":\"explore\"}}}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"44444444-4444-4444-4444-444444444444\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
      ),
    )
    .expect("write fork sample");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "active".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse");

    assert_eq!(
      parsed.raw_session.session_id,
      "55555555-5555-5555-5555-555555555555"
    );
    assert_eq!(
      parsed.raw_session.parent_session_id.as_deref(),
      Some("44444444-4444-4444-4444-444444444444")
    );
    assert_eq!(parsed.raw_session.agent_nickname.as_deref(), Some("Scout"));
    assert_eq!(parsed.raw_session.agent_role.as_deref(), Some("explore"));
    assert_eq!(parsed.snapshots.len(), 1);
  }

  #[test]
  fn scan_persists_rate_limit_samples_from_session_events() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_path = sessions_dir.join("quota.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-26T11:45:00+08:00\",\"type\":\"session_meta\",\"payload\":{\"id\":\"99999999-9999-9999-9999-999999999999\"}}\n",
        "{\"timestamp\":\"2026-03-26T11:44:59+08:00\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-26T11:45:00+08:00\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\",\"limit_id\":\"codex\",\"primary\":{\"used_percent\":12.0,\"window_minutes\":300,\"resets_at\":1774513656},\"secondary\":{\"used_percent\":21.0,\"window_minutes\":10080,\"resets_at\":1774589128}}}}\n"
      ),
    )
    .expect("write session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let samples = conn
      .query_row(
        "
        SELECT
          COUNT(*),
          MIN(bucket),
          MAX(bucket),
          MIN(remaining_percent),
          MAX(remaining_percent)
        FROM rate_limit_samples
        WHERE source_kind = 'session'
        ",
        [],
        |row| {
          Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
          ))
        },
      )
      .expect("query rate limit samples");

    assert_eq!(samples.0, 2);
    assert_eq!(samples.1, "five_hour".to_string());
    assert_eq!(samples.2, "seven_day".to_string());
    assert_eq!(samples.3, 79);
    assert_eq!(samples.4, 88);
  }

  #[test]
  fn primary_only_seven_day_rate_limit_is_imported_into_the_seven_day_bucket() {
    let payload = serde_json::json!({
      "rate_limits": {
        "plan_type": "pro",
        "primary": {
          "used_percent": 21,
          "window_duration_mins": 10_080,
          "resets_at": 1_774_589_128
        }
      }
    });

    let samples = extract_rate_limit_samples("2026-03-26T11:45:00+08:00", &payload);

    assert_eq!(samples.len(), 1);
    assert_eq!(samples[0].bucket, "seven_day");
    assert_eq!(samples[0].remaining_percent, 79);
  }

  #[test]
  fn scan_persists_usage_event_epoch_timestamp() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_path = sessions_dir.join("usage-epoch.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-07-10T10:00:00+08:00\",\"type\":\"session_meta\",\"payload\":{\"id\":\"98989898-9898-4898-8898-989898989898\"}}\n",
        "{\"timestamp\":\"2026-07-10T10:00:01+08:00\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-07-10T10:00:02+08:00\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}}}}\n"
      ),
    )
    .expect("write session");
    let db_path = directory.path().join("usage.sqlite");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open database");
    let persisted = conn
      .query_row(
        "SELECT timestamp, timestamp_ms FROM usage_events",
        [],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
      )
      .expect("load usage epoch");
    assert_eq!(persisted.0, "2026-07-10T10:00:02+08:00");
    assert_eq!(
      persisted.1,
      Some(
        crate::database::parse_epoch_millis(&persisted.0).expect("parse expected usage epoch")
      )
    );
  }

  #[test]
  fn scan_ignores_malformed_timestamps_on_skipped_usage_snapshots() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_path = sessions_dir.join("skipped-usage-timestamps.jsonl");
    let mut body = concat!(
      "{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"97979797-9797-4797-8797-979797979797\"}}\n",
      "{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n"
    )
    .to_string();
    for fixture in [
      TokenFixture {
        timestamp: "invalid-zero-delta",
        total: (0, 0, 0, 0),
        last: (0, 0, 0, 0),
      },
      TokenFixture {
        timestamp: "2026-07-10T00:00:02Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "invalid-duplicate",
        total: (100, 0, 0, 100),
        last: (0, 0, 0, 0),
      },
      TokenFixture {
        timestamp: "invalid-non-monotonic",
        total: (90, 0, 0, 90),
        last: (0, 0, 0, 0),
      },
    ] {
      body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&session_path, body).expect("write session");
    let db_path = directory.path().join("usage.sqlite");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open database");
    let persisted = conn
      .query_row(
        "
        SELECT COUNT(*), MIN(timestamp), MIN(timestamp_ms), SUM(total_tokens)
        FROM usage_events
        ",
        [],
        |row| {
          Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
          ))
        },
      )
      .expect("load persisted usage");
    assert_eq!(persisted.0, 1);
    assert_eq!(persisted.1, "2026-07-10T00:00:02Z");
    assert_eq!(
      persisted.2,
      crate::database::parse_epoch_millis(&persisted.1).expect("parse persisted timestamp")
    );
    assert_eq!(persisted.3, 100);
  }

  #[test]
  fn malformed_timestamp_on_written_usage_event_rolls_back_batch_and_freshness() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_path = sessions_dir.join("written-usage-timestamps.jsonl");
    let mut body = concat!(
      "{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"96969696-9696-4696-8696-969696969696\"}}\n",
      "{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n"
    )
    .to_string();
    for fixture in [
      TokenFixture {
        timestamp: "2026-07-10T00:00:02Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "invalid-written-event",
        total: (200, 0, 0, 200),
        last: (100, 0, 0, 100),
      },
    ] {
      body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&session_path, body).expect("write session");
    let db_path = directory.path().join("usage.sqlite");
    initialize_scan_database(&db_path);
    configure_codex_home(&db_path, &codex_home);
    let conn = open_connection(&db_path).expect("open database");
    let freshness_before = conn
      .query_row(
        "
        SELECT last_scan_started_at, last_scan_completed_at,
               last_full_scan_completed_at, scan_commit_revision
        FROM sync_settings
        WHERE singleton_id = 1
        ",
        [],
        |row| {
          Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, i64>(3)?,
          ))
        },
      )
      .expect("load initial freshness");
    drop(conn);

    let error = perform_scan(&db_path, None).expect_err("reject malformed written event");

    assert!(error.contains("Invalid usage event timestamp"));
    let conn = open_connection(&db_path).expect("reopen database");
    let usage_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))
      .expect("count usage events");
    let freshness_after = conn
      .query_row(
        "
        SELECT last_scan_started_at, last_scan_completed_at,
               last_full_scan_completed_at, scan_commit_revision
        FROM sync_settings
        WHERE singleton_id = 1
        ",
        [],
        |row| {
          Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, i64>(3)?,
          ))
        },
      )
      .expect("load rolled back freshness");
    assert_eq!(usage_count, 0);
    assert_eq!(freshness_after, freshness_before);
  }

  #[test]
  fn persist_session_delegates_usage_inserts_to_database_writer() {
    let source = include_str!("importer.rs");
    let persist_session_source = source
      .split("fn persist_session(")
      .nth(1)
      .expect("persist_session source")
      .split("fn diff_usage(")
      .next()
      .expect("persist_session body");

    assert!(persist_session_source.contains("replace_session_usage_events("));
    assert!(!persist_session_source.contains("INSERT INTO usage_events"));
  }

  #[test]
  fn parser_supports_legacy_top_level_id_format() {
    let directory = tempdir().expect("tempdir");
    let session_path = directory
      .path()
      .join("rollout-2025-09-09T16-29-03-0df0be29-d74d-468f-8dda-0630fc6e989e.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"id\":\"0df0be29-d74d-468f-8dda-0630fc6e989e\",\"timestamp\":\"2025-09-09T08:29:03.118Z\",\"instructions\":null}\n",
        "{\"record_type\":\"state\"}\n",
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]}\n"
      ),
    )
    .expect("write sample");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "archived".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse");

    assert_eq!(
      parsed.raw_session.session_id,
      "0df0be29-d74d-468f-8dda-0630fc6e989e"
    );
    assert_eq!(
      parsed.raw_session.started_at.as_deref(),
      Some("2025-09-09T08:29:03.118Z")
    );
  }

  #[test]
  fn parser_falls_back_to_session_id_from_filename() {
    let directory = tempdir().expect("tempdir");
    let session_path = directory
      .path()
      .join("rollout-2026-03-17T18-00-21-019cfb3d-415c-7623-aab0-22e73abcec2e.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"record_type\":\"state\"}\n",
        "{\"timestamp\":\"2026-03-17T10:00:21.636Z\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"fallback\"}]}\n"
      ),
    )
    .expect("write sample");

    let parsed = parse_session_file(
      &SessionFile {
        path: session_path,
        bucket: "archived".to_string(),
        file_size: 0,
        file_mtime_ms: 0,
      },
      &HashMap::new(),
    )
    .expect("parse");

    assert_eq!(
      parsed.raw_session.session_id,
      "019cfb3d-415c-7623-aab0-22e73abcec2e"
    );
  }

  #[test]
  fn topology_classification_handles_incremental_scan_cases() {
    let existing_child = ExistingSessionRelation {
      exists: true,
      parent_session_id: Some("root-parent".to_string()),
      child_count: 0,
    };
    assert_eq!(
      classify_topology_maintenance(
        Some(&existing_child),
        existing_child.child_count,
        Some("root-parent")
      ),
      TopologyMaintenance::None
    );
    assert_eq!(
      classify_topology_maintenance(
        Some(&existing_child),
        existing_child.child_count,
        Some("other-parent")
      ),
      TopologyMaintenance::RecomputeAll
    );

    let missing_parent_placeholder = ExistingSessionRelation {
      exists: false,
      parent_session_id: None,
      child_count: 2,
    };
    assert_eq!(
      classify_topology_maintenance(
        Some(&missing_parent_placeholder),
        missing_parent_placeholder.child_count,
        None
      ),
      TopologyMaintenance::RecomputeAll
    );
    assert_eq!(
      classify_topology_maintenance(None, 0, None),
      TopologyMaintenance::InsertRootLink
    );
    assert_eq!(
      classify_topology_maintenance(None, 0, Some("root-parent")),
      TopologyMaintenance::RecomputeAll
    );
  }

  #[test]
  fn child_usage_update_keeps_root_linked_to_existing_parent() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "44444444-4444-4444-4444-444444444444";
    let child_session_id = "55555555-5555-5555-5555-555555555555";
    write_session_file(
      &sessions_dir.join("parent.jsonl"),
      parent_session_id,
      &[("2026-03-24T00:00:01Z", 120, 20, 30, 150)],
    );
    write_session_file_with_parent(
      &sessions_dir.join("child.jsonl"),
      child_session_id,
      Some(parent_session_id),
      &[("2026-03-24T00:00:02Z", 80, 10, 15, 95)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "UPDATE sync_settings SET codex_home = ?1 WHERE singleton_id = 1",
        params![codex_home.to_string_lossy().to_string()],
      )
      .expect("configure source home");
    drop(conn);
    perform_scan(&db_path, None).expect("first scan");

    write_session_file_with_parent(
      &sessions_dir.join("child.jsonl"),
      child_session_id,
      Some(parent_session_id),
      &[
        ("2026-03-24T00:00:02Z", 80, 10, 15, 95),
        ("2026-03-24T00:10:02Z", 160, 20, 25, 185),
      ],
    );
    perform_incremental_scan(&db_path, None).expect("second scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_root_and_subagents(&conn, child_session_id),
      Some((parent_session_id.to_string(), false))
    );
    assert_eq!(
      session_root_and_subagents(&conn, parent_session_id),
      Some((parent_session_id.to_string(), true))
    );
    assert_eq!(
      conversation_link(&conn, child_session_id),
      Some((
        parent_session_id.to_string(),
        Some(parent_session_id.to_string()),
        1
      ))
    );
  }

  #[test]
  fn newly_arrived_parent_recomputes_existing_descendant_links() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "66666666-6666-6666-6666-666666666666";
    let child_session_id = "77777777-7777-7777-7777-777777777777";
    write_session_file_with_parent(
      &sessions_dir.join("child.jsonl"),
      child_session_id,
      Some(parent_session_id),
      &[("2026-03-24T00:00:02Z", 80, 10, 15, 95)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "UPDATE sync_settings SET codex_home = ?1 WHERE singleton_id = 1",
        params![codex_home.to_string_lossy().to_string()],
      )
      .expect("configure source home");
    drop(conn);
    perform_scan(&db_path, None).expect("first scan");

    write_session_file(
      &sessions_dir.join("parent.jsonl"),
      parent_session_id,
      &[("2026-03-24T00:00:01Z", 120, 20, 30, 150)],
    );
    perform_incremental_scan(&db_path, None).expect("second scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_root_and_subagents(&conn, parent_session_id),
      Some((parent_session_id.to_string(), true))
    );
    assert_eq!(
      conversation_link(&conn, parent_session_id),
      Some((parent_session_id.to_string(), None, 0))
    );
    assert_eq!(
      conversation_link(&conn, child_session_id),
      Some((
        parent_session_id.to_string(),
        Some(parent_session_id.to_string()),
        1
      ))
    );
  }

  #[test]
  fn archived_session_reuses_session_id_without_duplicate_billing() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archived_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_dir).expect("archived dir");

    let session_id = "11111111-1111-1111-1111-111111111111";
    let active_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &active_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_source_state(&conn, session_id),
      Some("active".to_string())
    );

    let archived_path = archived_dir.join("sample.jsonl");
    std::fs::rename(&active_path, &archived_path).expect("move to archived");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_source_state(&conn, session_id),
      Some("archived".to_string())
    );
  }

  #[test]
  fn incremental_scan_does_not_walk_archived_directory_for_untracked_files() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archived_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_dir).expect("archived dir");

    let active_session_id = "12121212-3434-5656-7878-909090909090";
    let archived_session_id = "abababab-cdcd-efef-1212-343434343434";
    write_session_file(
      &sessions_dir.join("active.jsonl"),
      active_session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");
    let archived_path = archived_dir.join("archived.jsonl");
    write_session_file(
      &archived_path,
      archived_session_id,
      &[
        ("2026-03-24T00:00:01Z", 150, 30, 40, 190),
        ("2026-03-24T00:10:01Z", 300, 60, 80, 380),
      ],
    );

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 0);
    assert_eq!(
      session_usage_totals(&conn, active_session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_usage_totals(&conn, archived_session_id),
      (0, 0, 0, 0, 0)
    );
  }

  #[test]
  fn incremental_snapshot_does_not_load_archived_database_rows() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archived_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_dir).expect("archived dir");

    write_session_file(
      &sessions_dir.join("active.jsonl"),
      "12121212-0000-0000-0000-000000000001",
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    for index in 2..=32 {
      write_session_file(
        &archived_dir.join(format!("archived-{index}.jsonl")),
        &format!("12121212-0000-0000-0000-{index:012}"),
        &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
      );
    }

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "UPDATE sync_settings SET codex_home = ?1 WHERE singleton_id = 1",
        params![codex_home.to_string_lossy().to_string()],
      )
      .expect("configure source home");
    drop(conn);
    perform_scan(&db_path, None).expect("full scan");

    let snapshot = load_preparation_database_snapshot(
      &db_path,
      None,
      ScanKind::Incremental,
    )
    .expect("incremental snapshot");
    assert_eq!(snapshot.import_state.len(), 1);
    assert_eq!(snapshot.session_source_paths.len(), 1);
    assert_eq!(snapshot.existing_relations.len(), 1);
    assert_eq!(snapshot.existing_session_sources.len(), 1);
  }

  #[test]
  fn incremental_scan_discovers_new_recent_active_session() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let existing_session_id = "99999999-8888-7777-6666-555555555555";
    write_session_file(
      &sessions_dir.join("existing.jsonl"),
      existing_session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");

    let today = Local::now();
    let recent_dir = sessions_dir
      .join(today.format("%Y").to_string())
      .join(today.format("%m").to_string())
      .join(today.format("%d").to_string());
    std::fs::create_dir_all(&recent_dir).expect("recent sessions dir");
    let new_session_id = "44444444-3333-2222-1111-000000000000";
    write_session_file(
      &recent_dir.join("new.jsonl"),
      new_session_id,
      &[("2026-03-24T00:10:01Z", 180, 40, 45, 225)],
    );

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, existing_session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_usage_totals(&conn, new_session_id),
      (180, 40, 45, 225, 1)
    );
  }

  #[test]
  fn reconcile_scan_discovers_new_old_dated_active_session() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let existing_session_id = "10101010-2020-3030-4040-505050505050";
    write_session_file(
      &sessions_dir.join("existing.jsonl"),
      existing_session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");

    let old_dir = sessions_dir.join("2025").join("11").join("05");
    std::fs::create_dir_all(&old_dir).expect("old sessions dir");
    let new_session_id = "60606060-7070-8080-9090-a0a0a0a0a0a0";
    write_session_file(
      &old_dir.join("old-new.jsonl"),
      new_session_id,
      &[("2026-03-24T00:10:01Z", 180, 40, 45, 225)],
    );

    let incremental = perform_incremental_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
    )
    .expect("incremental scan");
    assert_eq!(incremental.updated_sessions, 0);
    let result = perform_scan_with_kind(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Reconcile,
    )
    .expect("reconcile scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, existing_session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_usage_totals(&conn, new_session_id),
      (180, 40, 45, 225, 1)
    );
  }

  #[test]
  fn incremental_scan_marks_missing_active_source() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "b0b0b0b0-c0c0-d0d0-e0e0-f0f0f0f0f0f0";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");
    std::fs::remove_file(&session_path).expect("remove active session");

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 0);
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_source_state(&conn, session_id),
      Some("missing".to_string())
    );
  }

  #[test]
  fn incremental_scan_retries_pending_repair_path_without_import_state() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archived_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_dir).expect("archived sessions dir");

    let existing_session_id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb";
    write_session_file(
      &sessions_dir.join("existing.jsonl"),
      existing_session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let pending_path = archived_dir.join("unparseable.jsonl");
    std::fs::write(&pending_path, "not json\n").expect("write bad session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");

    let recovered_session_id = "88888888-9999-aaaa-bbbb-cccccccccccc";
    write_session_file(
      &pending_path,
      recovered_session_id,
      &[("2026-03-24T00:10:01Z", 180, 40, 45, 225)],
    );

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, existing_session_id),
      (100, 20, 25, 125, 1)
    );
    assert_eq!(
      session_usage_totals(&conn, recovered_session_id),
      (180, 40, 45, 225, 1)
    );
    let pending_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repair_pending_files WHERE repair_key = ?1",
        params![TOKEN_USAGE_MONOTONIC_REPAIR_KEY],
        |row| row.get(0),
      )
      .expect("query pending repairs");
    assert_eq!(pending_count, 0);
  }

  #[test]
  fn deleted_session_keeps_usage_and_marks_source_missing() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "22222222-2222-2222-2222-222222222222";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 150, 30, 40, 190)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::remove_file(&session_path).expect("delete source");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (150, 30, 40, 190, 1)
    );
    assert_eq!(
      session_source_state(&conn, session_id),
      Some("missing".to_string())
    );
  }

  #[test]
  fn restored_session_rebuilds_usage_without_rebilling_old_history() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "33333333-3333-3333-3333-333333333333";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::remove_file(&session_path).expect("delete source");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
        ("2026-03-24T00:10:01Z", 180, 40, 45, 225),
      ],
    );
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("third scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
    assert_eq!(
      session_source_state(&conn, session_id),
      Some("active".to_string())
    );
  }

  #[test]
  fn non_monotonic_token_snapshots_do_not_rebill_replayed_usage() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "34343434-3434-3434-3434-343434343434";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-05-18T14:42:17Z", 800, 100, 100, 1000),
        ("2026-05-18T14:42:28Z", 880, 110, 110, 1100),
        ("2026-05-18T14:42:39Z", 840, 105, 105, 1050),
        ("2026-05-18T14:42:50Z", 960, 120, 120, 1200),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (960, 120, 120, 1200, 3)
    );
  }

  #[test]
  fn scan_repairs_existing_overcounted_usage_when_source_metadata_is_unchanged() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "35353535-3535-3535-3535-353535353535";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-05-18T14:42:17Z", 800, 100, 100, 1000),
        ("2026-05-18T14:42:28Z", 880, 110, 110, 1100),
        ("2026-05-18T14:42:39Z", 840, 105, 105, 1050),
        ("2026-05-18T14:42:50Z", 960, 120, 120, 1200),
      ],
    );
    let metadata = std::fs::metadata(&session_path).expect("metadata");
    let file_size = metadata.len() as i64;
    let file_mtime_ms = metadata
      .modified()
      .ok()
      .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
      .map(|duration| duration.as_millis() as i64)
      .unwrap_or_default();

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open db");
    init_db(&conn).expect("init db");
    conn
      .execute(
        "
        INSERT INTO sessions (
          session_id, root_session_id, parent_session_id, title, source_state, source_path,
          source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
          fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
        )
        VALUES (?1, ?1, NULL, NULL, 'active', ?2, 'active', NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.4', 0, ?3, ?3)
        ",
        params![session_id, session_path.to_string_lossy().to_string(), now_utc_string()],
      )
      .expect("insert existing session");
    conn
      .execute(
        "
        INSERT INTO import_state (source_path, session_id, source_bucket, file_size, file_mtime_ms, last_imported_at)
        VALUES (?1, ?2, 'active', ?3, ?4, ?5)
        ",
        params![
          session_path.to_string_lossy().to_string(),
          session_id,
          file_size,
          file_mtime_ms,
          now_utc_string(),
        ],
      )
      .expect("insert matching import state");
    for (input_tokens, cached_input_tokens, output_tokens, total_tokens) in [
      (800, 100, 100, 1000),
      (80, 10, 10, 100),
      (840, 105, 105, 1050),
      (120, 15, 15, 150),
    ] {
      conn
        .execute(
          "
          INSERT INTO usage_events (
            session_id, timestamp, model_id, input_tokens, cached_input_tokens, output_tokens,
            reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective
          )
          VALUES (?1, '2026-05-18T14:42:50Z', 'gpt-5.4', ?2, ?3, ?4, 0, ?5, 0.0, 0, 0)
          ",
          params![
            session_id,
            input_tokens,
            cached_input_tokens,
            output_tokens,
            total_tokens
          ],
        )
        .expect("insert stale usage event");
    }
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (1840, 230, 230, 2300, 4)
    );
    drop(conn);

    let result =
      perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (960, 120, 120, 1200, 3)
    );
    let repair_completed: Option<String> = conn
      .query_row(
        "SELECT completed_at FROM data_repairs WHERE repair_key = ?1",
        params![TOKEN_USAGE_MONOTONIC_REPAIR_KEY],
        |row| row.get(0),
      )
      .optional()
      .expect("query data repair marker");
    assert!(repair_completed.is_some());
  }

  #[test]
  fn v3_repair_rebuilds_unchanged_fork_usage() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "56565656-5656-4656-8656-565656565656";
    let child_session_id = "57575757-5757-4757-8757-575757575757";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    let repaired_session_id = "58585858-5858-4858-8858-585858585858";
    let repaired_path = sessions_dir.join("unparseable-v3.jsonl");
    let parent_fixtures = [
      TokenFixture {
        timestamp: "2026-03-24T00:00:01Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:10:01Z",
        total: (180, 0, 0, 180),
        last: (80, 0, 0, 80),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:20:01Z",
        total: (260, 0, 0, 260),
        last: (80, 0, 0, 80),
      },
    ];

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    for fixture in parent_fixtures.iter().copied() {
      parent_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&parent_path, parent_body).expect("write parent session");

    let child_created_at = "2026-03-24T00:30:00Z";
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_created_at, child_session_id, parent_session_id, child_created_at,
    );
    for (index, fixture) in parent_fixtures.iter().copied().enumerate() {
      let timestamp = match index {
        0 => "2026-03-24T00:30:01Z",
        1 => "2026-03-24T00:30:02Z",
        _ => "2026-03-24T00:30:03Z",
      };
      child_body.push_str(&token_count_line(TokenFixture {
        timestamp,
        ..fixture
      }));
    }
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:31:00Z",
      total: (310, 0, 0, 310),
      last: (50, 0, 0, 50),
    }));
    std::fs::write(&child_path, child_body).expect("write fork session");
    std::fs::write(&repaired_path, "not json\n").expect("write unreadable repair fixture");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, parent_session_id).3, 260);
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 50);
    conn
      .execute(
        "DELETE FROM usage_events WHERE session_id = ?1",
        params![child_session_id],
      )
      .expect("delete corrected child usage");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective
        )
        VALUES (?1, '2026-03-24T00:31:00Z', 'gpt-5.4', 310, 0, 0, 0, 310, 0.0, 0, 0)
        ",
        params![child_session_id],
      )
      .expect("insert legacy overcounted child usage");
    conn
      .execute(
        "DELETE FROM data_repairs WHERE repair_key = 'token_usage_fork_replay_v3'",
        [],
      )
      .expect("simulate database upgraded from v2");
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 310);
    drop(conn);

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("v3 repair scan");

    let conn = open_connection(&db_path).expect("open repaired db");
    assert_eq!(result.updated_sessions, 2);
    assert_eq!(session_usage_totals(&conn, parent_session_id).3, 260);
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 50);
    let v2_completed: Option<String> = conn
      .query_row(
        "SELECT completed_at FROM data_repairs WHERE repair_key = 'token_usage_monotonic_v2'",
        [],
        |row| row.get(0),
      )
      .optional()
      .expect("query v2 repair marker");
    let v3_completed: Option<String> = conn
      .query_row(
        "SELECT completed_at FROM data_repairs WHERE repair_key = 'token_usage_fork_replay_v3'",
        [],
        |row| row.get(0),
      )
      .optional()
      .expect("query v3 repair marker");
    let pending_v3_path: Option<String> = conn
      .query_row(
        "
        SELECT source_path
        FROM data_repair_pending_files
        WHERE repair_key = 'token_usage_fork_replay_v3'
        ",
        [],
        |row| row.get(0),
      )
      .optional()
      .expect("query pending v3 repair file");
    assert!(v2_completed.is_some());
    assert!(v3_completed.is_some());
    assert_eq!(
      pending_v3_path.as_deref(),
      Some(repaired_path.to_string_lossy().as_ref())
    );
    drop(conn);

    write_session_file(
      &repaired_path,
      repaired_session_id,
      &[("2026-03-24T01:00:01Z", 40, 0, 10, 50)],
    );
    let retry = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("retry v3 repair file");

    let conn = open_connection(&db_path).expect("open retried db");
    assert_eq!(retry.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, repaired_session_id).3, 50);
    let pending_v3_count: i64 = conn
      .query_row(
        "
        SELECT COUNT(*)
        FROM data_repair_pending_files
        WHERE repair_key = 'token_usage_fork_replay_v3'
        ",
        [],
        |row| row.get(0),
      )
      .expect("count pending v3 repair files");
    assert_eq!(pending_v3_count, 0);
  }

  #[test]
  fn fork_repair_retries_child_after_parent_source_recovers() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "63636363-6363-4363-8363-636363636363";
    let child_session_id = "64646464-6464-4464-8464-646464646464";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    std::fs::write(&parent_path, "not json\n").expect("write unavailable parent");
    let inherited = TokenFixture {
      timestamp: "2026-03-24T00:30:00Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    };
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:30:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:30:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id, parent_session_id,
    );
    child_body.push_str(&token_count_line(inherited));
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:31:00Z",
      total: (150, 0, 0, 150),
      last: (50, 0, 0, 50),
    }));
    std::fs::write(&child_path, child_body).expect("write fork child");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");

    let conn = open_connection(&db_path).expect("open initial db");
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 150);
    let pending_child_count: i64 = conn
      .query_row(
        "
        SELECT COUNT(*)
        FROM data_repair_pending_files
        WHERE repair_key = ?1 AND source_path = ?2
        ",
        params![
          TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY,
          child_path.to_string_lossy().to_string()
        ],
        |row| row.get(0),
      )
      .expect("count pending child repair");
    assert_eq!(pending_child_count, 1);
    drop(conn);

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    parent_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:00Z",
      ..inherited
    }));
    std::fs::write(&parent_path, parent_body).expect("restore parent source");
    let retry = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("retry recovered parent and child");

    let conn = open_connection(&db_path).expect("open repaired db");
    assert_eq!(retry.updated_sessions, 2);
    assert_eq!(session_usage_totals(&conn, parent_session_id).3, 100);
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 50);
    let pending_v3_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repair_pending_files WHERE repair_key = ?1",
        params![TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY],
        |row| row.get(0),
      )
      .expect("count pending v3 repairs");
    assert_eq!(pending_v3_count, 0);
  }

  #[test]
  fn moved_archive_clears_v3_pending_active_source() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions/2026/07/10");
    let archived_sessions_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_sessions_dir).expect("archived sessions dir");

    let session_id = "59595959-5959-4959-8959-595959595959";
    let filename = format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl");
    let active_path = sessions_dir.join(&filename);
    let archived_path = archived_sessions_dir.join(&filename);
    write_session_file(
      &active_path,
      session_id,
      &[("2026-07-10T00:00:01Z", 80, 0, 20, 100)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");
    std::fs::rename(&active_path, &archived_path).expect("archive session during repair");
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("record archived source before stale pending retry");

    let conn = open_connection(&db_path).expect("open db");
    conn
      .execute(
        "DELETE FROM usage_events WHERE session_id = ?1",
        params![session_id],
      )
      .expect("delete corrected usage");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective
        )
        VALUES (?1, '2026-07-10T00:00:01Z', 'gpt-5.4', 160, 0, 40, 0, 200, 0.0, 0, 0)
        ",
        params![session_id],
      )
      .expect("insert stale usage");
    conn
      .execute(
        "
        INSERT INTO data_repair_pending_files (repair_key, source_path, last_error, updated_at)
        VALUES (?1, ?2, 'source moved during repair', ?3)
        ",
        params![
          TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY,
          active_path.to_string_lossy().to_string(),
          now_utc_string(),
        ],
      )
      .expect("insert pending active source");
    drop(conn);

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("repair moved archive");

    let conn = open_connection(&db_path).expect("open repaired db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, session_id).3, 100);
    let pending_v3_count: i64 = conn
      .query_row(
        "
        SELECT COUNT(*)
        FROM data_repair_pending_files
        WHERE repair_key = ?1
        ",
        params![TOKEN_USAGE_FORK_REPLAY_REPAIR_KEY],
        |row| row.get(0),
      )
      .expect("count pending v3 repair files");
    assert_eq!(pending_v3_count, 0);
  }

  #[test]
  fn scan_tracks_skipped_token_repair_files_without_reimporting_everything() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "36363636-3636-3636-3636-363636363636";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-05-18T14:42:17Z", 800, 100, 100, 1000),
        ("2026-05-18T14:42:28Z", 880, 110, 110, 1100),
        ("2026-05-18T14:42:39Z", 840, 105, 105, 1050),
        ("2026-05-18T14:42:50Z", 960, 120, 120, 1200),
      ],
    );
    std::fs::write(sessions_dir.join("unparseable.jsonl"), "not json\n")
      .expect("write bad session");

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open db");
    init_db(&conn).expect("init db");
    conn
      .execute(
        "
        INSERT INTO rate_limit_samples (
          source_kind, source_session_id, bucket, sample_timestamp, limit_id, limit_name,
          plan_type, window_start, resets_at, used_percent, remaining_percent, created_at
        )
        VALUES ('session', 'seed', 'five_hour', ?1, '', '', '', ?1, ?1, 0, 100, ?1)
        ",
        params![now_utc_string()],
      )
      .expect("insert rate limit backfill sentinel");
    conn
      .execute(
        "
        INSERT INTO sessions (
          session_id, root_session_id, parent_session_id, title, source_state, source_path,
          source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
          fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
        )
        VALUES (?1, ?1, NULL, NULL, 'active', ?2, 'active', NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.4', 0, ?3, ?3)
        ",
        params![session_id, session_path.to_string_lossy().to_string(), now_utc_string()],
      )
      .expect("insert existing session");
    for (input_tokens, cached_input_tokens, output_tokens, total_tokens) in [
      (800, 100, 100, 1000),
      (80, 10, 10, 100),
      (840, 105, 105, 1050),
      (120, 15, 15, 150),
    ] {
      conn
        .execute(
          "
          INSERT INTO usage_events (
            session_id, timestamp, model_id, input_tokens, cached_input_tokens, output_tokens,
            reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective
          )
          VALUES (?1, '2026-05-18T14:42:50Z', 'gpt-5.4', ?2, ?3, ?4, 0, ?5, 0.0, 0, 0)
          ",
          params![
            session_id,
            input_tokens,
            cached_input_tokens,
            output_tokens,
            total_tokens
          ],
        )
        .expect("insert stale usage event");
    }
    drop(conn);

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (960, 120, 120, 1200, 3)
    );
    let repair_completed: Option<String> = conn
      .query_row(
        "SELECT completed_at FROM data_repairs WHERE repair_key = ?1",
        params![TOKEN_USAGE_MONOTONIC_REPAIR_KEY],
        |row| row.get(0),
      )
      .optional()
      .expect("query data repair marker");
    assert!(repair_completed.is_some());
    let pending_path: Option<String> = conn
      .query_row(
        "SELECT source_path FROM data_repair_pending_files WHERE repair_key = ?1",
        params![TOKEN_USAGE_MONOTONIC_REPAIR_KEY],
        |row| row.get(0),
      )
      .optional()
      .expect("query pending repair file");
    assert_eq!(
      pending_path.as_deref(),
      Some(
        sessions_dir
          .join("unparseable.jsonl")
          .to_string_lossy()
          .as_ref()
      )
    );
    let session_rate_sample_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM rate_limit_samples WHERE source_kind = 'session'",
        [],
        |row| row.get(0),
      )
      .expect("query session rate sample count");
    assert!(session_rate_sample_count > 0);
    drop(conn);

    let result =
      perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("rescan");
    assert_eq!(result.updated_sessions, 0);
  }

  #[test]
  fn scan_keeps_pending_token_repair_file_when_persistence_fails() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "37373737-3737-3737-3737-373737373737";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-05-18T14:42:17Z", 800, 100, 100, 1000)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open db");
    init_db(&conn).expect("init db");
    conn
      .execute(
        "
        INSERT INTO data_repairs (repair_key, completed_at)
        VALUES (?1, ?2)
        ",
        params![TOKEN_USAGE_MONOTONIC_REPAIR_KEY, now_utc_string()],
      )
      .expect("insert repair marker");
    conn
      .execute(
        "
        INSERT INTO data_repair_pending_files (repair_key, source_path, last_error, updated_at)
        VALUES (?1, ?2, 'previous parse error', ?3)
        ",
        params![
          TOKEN_USAGE_MONOTONIC_REPAIR_KEY,
          session_path.to_string_lossy().to_string(),
          now_utc_string(),
        ],
      )
      .expect("insert pending file");
    conn
      .execute_batch(
        "
        CREATE TRIGGER fail_usage_event_insert
        BEFORE INSERT ON usage_events
        BEGIN
          SELECT RAISE(ABORT, 'forced usage insert failure');
        END;
        ",
      )
      .expect("create failing trigger");
    drop(conn);

    let error = perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect_err("scan should fail while persisting pending repair file");
    assert!(error.contains("forced usage insert failure"));

    let conn = open_connection(&db_path).expect("open db");
    let pending_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repair_pending_files WHERE repair_key = ?1 AND source_path = ?2",
        params![
          TOKEN_USAGE_MONOTONIC_REPAIR_KEY,
          session_path.to_string_lossy().to_string(),
        ],
        |row| row.get(0),
      )
      .expect("query pending file count");
    assert_eq!(pending_count, 1);
  }

  #[test]
  fn back_to_back_scans_change_totals_when_active_session_file_grows() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "44444444-4444-4444-4444-444444444444";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let conn = open_connection(&db_path).expect("open db after first scan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 25, 125, 1)
    );
    drop(conn);

    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
        ("2026-03-24T00:00:10Z", 180, 40, 45, 225),
      ],
    );
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db after second scan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn growing_active_session_reads_only_completed_tail_after_checkpoint() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "45454545-4545-4545-4545-454545454545";
    let session_path = sessions_dir.join("growing.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let filler = "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"ignored\",\"payload\":{}}\n";
    let mut file = std::fs::OpenOptions::new()
      .append(true)
      .open(&session_path)
      .expect("open initial session for append");
    for _ in 0..4_096 {
      file.write_all(filler.as_bytes()).expect("append filler");
    }
    drop(file);

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial full scan");

    let appended = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:01:01Z",
      total: (180, 40, 45, 225),
      last: (80, 20, 20, 100),
    });
    std::fs::OpenOptions::new()
      .append(true)
      .open(&session_path)
      .expect("open growing session")
      .write_all(appended.as_bytes())
      .expect("append completed token line");

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare incremental tail");
    assert!(
      prepared.stats().source_bytes_read < appended.len() as u64 * 4,
      "incremental parse should avoid rereading the historical prefix; read {} bytes",
      prepared.stats().source_bytes_read
    );
    commit_prepared_scan(prepared).expect("commit incremental tail");

    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn unchanged_size_with_new_mtime_uses_checkpoint_instead_of_full_parse() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_id = "45454545-aaaa-bbbb-cccc-454545454545";
    let session_path = sessions_dir.join("touched.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial scan");

    let unchanged = std::fs::read(&session_path).expect("read source");
    std::thread::sleep(Duration::from_millis(5));
    std::fs::write(&session_path, unchanged).expect("rewrite identical source");

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare touched source");
    assert_eq!(prepared.stats().source_bytes_read, 0);
    assert_eq!(prepared.stats().fully_parsed_files, 0);
    assert_eq!(prepared.updated_sessions, 0);
  }

  #[test]
  fn reconcile_scan_reads_only_completed_tail_after_checkpoint() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "56565656-5656-5656-5656-565656565656";
    let session_path = sessions_dir.join("reconciled-growing.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let filler = "{\"timestamp\":\"2026-03-24T00:00:02Z\",\"type\":\"ignored\",\"payload\":{}}\n";
    let mut file = std::fs::OpenOptions::new()
      .append(true)
      .open(&session_path)
      .expect("open initial session for append");
    for _ in 0..4_096 {
      file.write_all(filler.as_bytes()).expect("append filler");
    }
    drop(file);

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial full scan");

    let appended = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:01:01Z",
      total: (180, 40, 45, 225),
      last: (80, 20, 20, 100),
    });
    std::fs::OpenOptions::new()
      .append(true)
      .open(&session_path)
      .expect("open growing session")
      .write_all(appended.as_bytes())
      .expect("append completed token line");

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Reconcile,
    )
    .expect("prepare reconcile tail");
    assert_eq!(prepared.stats().tail_parsed_files, 1);
    assert_eq!(prepared.stats().fully_parsed_files, 0);
    assert!(
      prepared.stats().source_bytes_read < appended.len() as u64 * 4,
      "reconcile should avoid rereading the historical prefix; read {} bytes",
      prepared.stats().source_bytes_read
    );
    commit_prepared_scan(prepared).expect("commit reconcile tail");

    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn reconcile_scan_discovers_new_archived_session() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archives_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archives_dir).expect("archives dir");

    let initial_id = "67676767-6767-6767-6767-676767676767";
    write_session_file(
      &sessions_dir.join("initial.jsonl"),
      initial_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial full scan");

    let archived_id = "78787878-7878-7878-7878-787878787878";
    write_session_file(
      &archives_dir.join("new-archive.jsonl"),
      archived_id,
      &[("2026-03-24T01:00:01Z", 200, 40, 50, 250)],
    );

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Reconcile,
    )
    .expect("prepare reconcile scan");
    assert_eq!(prepared.stats().fully_parsed_files, 1);
    commit_prepared_scan(prepared).expect("commit reconcile scan");

    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(
      session_usage_totals(&conn, archived_id),
      (200, 40, 50, 250, 1)
    );
  }

  #[test]
  #[ignore = "resource profiling helper; requires database and Codex home copies"]
  fn profile_real_incremental_scan() {
    let db_path = std::env::var_os("CODEX_PACER_PROFILE_DB")
      .map(PathBuf::from)
      .expect("set CODEX_PACER_PROFILE_DB to a database copy");
    let codex_home = std::env::var_os("CODEX_PACER_PROFILE_CODEX_HOME")
      .map(PathBuf::from)
      .expect("set CODEX_PACER_PROFILE_CODEX_HOME");
    let started = std::time::Instant::now();
    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare incremental scan");
    eprintln!(
      "profile incremental elapsed_ms={} visited={} read_bytes={} tail={} full={}",
      started.elapsed().as_millis(),
      prepared.stats().files_visited,
      prepared.stats().source_bytes_read,
      prepared.stats().tail_parsed_files,
      prepared.stats().fully_parsed_files
    );
  }

  #[test]
  fn changed_checkpoint_suffix_falls_back_to_full_session_parse() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_id = "46464646-4646-4646-4646-464646464646";
    let session_path = sessions_dir.join("rewritten.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial scan");

    let mut body = std::fs::read_to_string(&session_path).expect("read initial session");
    let suffix_index = body.rfind('\n').expect("session ends with newline");
    body.insert(suffix_index, ' ');
    body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:01:01Z",
      total: (180, 40, 45, 225),
      last: (80, 20, 20, 100),
    }));
    std::fs::write(&session_path, body).expect("rewrite checkpoint suffix and append");

    let prepared = prepare_scan(
      &db_path,
      Some(codex_home.to_string_lossy().to_string()),
      ScanKind::Incremental,
    )
    .expect("prepare safe fallback");
    assert!(
      prepared.stats().source_bytes_read > 500,
      "signature mismatch must re-read the complete session"
    );
    commit_prepared_scan(prepared).expect("commit fallback scan");
    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn tail_checkpoint_keeps_monotonic_usage_high_water() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    let session_id = "47474747-4747-4747-4747-474747474747";
    let session_path = sessions_dir.join("rollback.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 0, 0, 100),
        ("2026-03-24T00:00:02Z", 80, 0, 0, 80),
      ],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("initial scan with rollback");

    let appended = token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:01:01Z",
      total: (150, 0, 0, 150),
      last: (50, 0, 0, 50),
    });
    std::fs::OpenOptions::new()
      .append(true)
      .open(&session_path)
      .expect("open session")
      .write_all(appended.as_bytes())
      .expect("append recovery after rollback");
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental tail scan");

    let conn = open_connection(&db_path).expect("open database");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (150, 0, 0, 150, 2)
    );
  }

  #[test]
  fn complete_trailing_token_line_without_newline_is_imported_once() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "55555555-5555-5555-5555-555555555555";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let conn = open_connection(&db_path).expect("open db after first scan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 25, 125, 1)
    );
    drop(conn);

    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"55555555-5555-5555-5555-555555555555\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:10Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":180,\"cached_input_tokens\":40,\"output_tokens\":45,\"reasoning_output_tokens\":0,\"total_tokens\":225}},\"rate_limits\":{\"plan_type\":\"pro\"}}}"
      ),
    )
    .expect("write complete session without trailing newline");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db after no-newline rescan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
    drop(conn);

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("unchanged third scan");

    let conn = open_connection(&db_path).expect("open db after unchanged scan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn incomplete_trailing_line_keeps_latest_completed_token_snapshot() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "66666666-6666-6666-6666-666666666666";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"66666666-6666-6666-6666-666666666666\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:10Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":180,\"cached_input_tokens\":40,\"output_tokens\":45,\"reasoning_output_tokens\":0,\"total_tokens\":225}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:20Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":240"
      ),
    )
    .expect("write active session with incomplete tail");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db after second scan");
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 45, 225, 2)
    );
  }

  #[test]
  fn scan_keeps_root_and_fork_sessions_distinct_when_child_replays_parent_meta() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "77777777-7777-7777-7777-777777777777";
    let child_session_id = "88888888-8888-8888-8888-888888888888";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-05-00-{child_session_id}.jsonl"
    ));

    write_session_file(
      &parent_path,
      parent_session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
        ("2026-03-24T00:10:01Z", 180, 40, 45, 225),
        ("2026-03-24T00:20:01Z", 260, 60, 65, 325),
      ],
    );
    write_replayed_fork_session_file(
      &child_path,
      child_session_id,
      parent_session_id,
      &[
        ("2026-03-24T00:05:01Z", 80, 10, 15, 95),
        ("2026-03-24T00:15:01Z", 140, 20, 25, 165),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      session_usage_totals(&conn, parent_session_id),
      (260, 60, 65, 325, 3)
    );
    assert_eq!(
      session_usage_totals(&conn, child_session_id),
      (140, 20, 25, 165, 2)
    );
    assert_eq!(
      session_root_and_subagents(&conn, parent_session_id),
      Some((parent_session_id.to_string(), true))
    );
    assert_eq!(
      session_root_and_subagents(&conn, child_session_id),
      Some((parent_session_id.to_string(), false))
    );
    assert_eq!(
      import_state_session_id(&conn, &parent_path),
      Some(parent_session_id.to_string())
    );
    assert_eq!(
      import_state_session_id(&conn, &child_path),
      Some(child_session_id.to_string())
    );
  }

  #[test]
  fn fork_replay_counts_only_child_usage() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "99999999-9999-9999-9999-999999999999";
    let child_session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    let parent_fixtures = [
      TokenFixture {
        timestamp: "2026-03-24T00:00:01Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:10:01Z",
        total: (180, 0, 0, 180),
        last: (80, 0, 0, 80),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:20:01Z",
        total: (260, 0, 0, 260),
        last: (80, 0, 0, 80),
      },
    ];

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    for fixture in parent_fixtures.iter().copied() {
      parent_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&parent_path, parent_body).expect("write parent session");

    let child_created_at = "2026-03-24T00:30:00Z";
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_created_at, child_session_id, parent_session_id, child_created_at,
    );
    for fixture in parent_fixtures.iter().copied() {
      child_body.push_str(&token_count_line(TokenFixture {
        timestamp: child_created_at,
        ..fixture
      }));
    }
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:31:00Z",
      total: (310, 0, 0, 310),
      last: (50, 0, 0, 50),
    }));
    std::fs::write(&child_path, child_body).expect("write fork session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let parent_total = session_usage_totals(&conn, parent_session_id).3;
    let child_total = session_usage_totals(&conn, child_session_id).3;
    assert_eq!(parent_total, 260);
    assert_eq!(child_total, 50);
    assert_eq!(parent_total + child_total, 310);
  }

  #[test]
  fn single_snapshot_parent_replay_counts_only_child_usage() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "61616161-6161-4161-8161-616161616161";
    let child_session_id = "62626262-6262-4262-8262-626262626262";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    let inherited = TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (100, 0, 0, 100),
      last: (100, 0, 0, 100),
    };

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    parent_body.push_str(&token_count_line(inherited));
    std::fs::write(&parent_path, parent_body).expect("write single-snapshot parent");

    let child_created_at = "2026-03-24T00:30:00Z";
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_created_at, child_session_id, parent_session_id, child_created_at,
    );
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:30:01Z",
      ..inherited
    }));
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:31:00Z",
      total: (150, 0, 0, 150),
      last: (50, 0, 0, 50),
    }));
    std::fs::write(&child_path, child_body).expect("write fork child");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    let parent_total = session_usage_totals(&conn, parent_session_id).3;
    let child_total = session_usage_totals(&conn, child_session_id).3;
    assert_eq!(parent_total, 100);
    assert_eq!(child_total, 50);
    assert_eq!(parent_total + child_total, 150);
  }

  #[test]
  fn incremental_fork_scan_loads_unchanged_archived_parent() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    let archived_sessions_dir = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");
    std::fs::create_dir_all(&archived_sessions_dir).expect("archived sessions dir");

    let parent_session_id = "11111111-1111-4111-8111-111111111111";
    let child_session_id = "22222222-2222-4222-8222-222222222222";
    let parent_path = archived_sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    let parent_fixtures = [
      TokenFixture {
        timestamp: "2026-03-24T00:00:01Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:10:01Z",
        total: (180, 0, 0, 180),
        last: (80, 0, 0, 80),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:20:01Z",
        total: (260, 0, 0, 260),
        last: (80, 0, 0, 80),
      },
    ];

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    for fixture in parent_fixtures.iter().copied() {
      parent_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&parent_path, parent_body).expect("write archived parent session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("full parent scan");

    let child_created_at = "2026-03-24T00:30:00Z";
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_created_at, child_session_id, parent_session_id, child_created_at,
    );
    for (index, fixture) in parent_fixtures.iter().copied().enumerate() {
      let timestamp = match index {
        0 => "2026-03-24T00:30:01Z",
        1 => "2026-03-24T00:30:02Z",
        _ => "2026-03-24T00:30:03Z",
      };
      child_body.push_str(&token_count_line(TokenFixture {
        timestamp,
        ..fixture
      }));
    }
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:31:00Z",
      total: (310, 0, 0, 310),
      last: (50, 0, 0, 50),
    }));
    std::fs::write(&child_path, child_body).expect("write active fork child");

    let incremental =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
        .expect("incremental child scan");

    let conn = open_connection(&db_path).expect("open db");
    let parent_total = session_usage_totals(&conn, parent_session_id).3;
    let child_total = session_usage_totals(&conn, child_session_id).3;
    assert_eq!(incremental.updated_sessions, 1);
    assert_eq!(parent_total, 260);
    assert_eq!(child_total, 50);
    assert_eq!(parent_total + child_total, 310);
  }

  #[test]
  fn nested_fork_replay_uses_direct_parent() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let root_session_id = "33333333-3333-4333-8333-333333333333";
    let child_session_id = "44444444-4444-4444-8444-444444444444";
    let grandchild_session_id = "55555555-5555-4555-8555-555555555555";
    let root_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{root_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"
    ));
    let grandchild_path = sessions_dir.join(format!(
      "rollout-2026-03-24T01-00-00-{grandchild_session_id}.jsonl"
    ));
    let root_fixtures = [
      TokenFixture {
        timestamp: "2026-03-24T00:00:01Z",
        total: (100, 0, 0, 100),
        last: (100, 0, 0, 100),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:10:01Z",
        total: (180, 0, 0, 180),
        last: (80, 0, 0, 80),
      },
      TokenFixture {
        timestamp: "2026-03-24T00:20:01Z",
        total: (260, 0, 0, 260),
        last: (80, 0, 0, 80),
      },
    ];
    let child_fixtures = [
      TokenFixture {
        timestamp: "2026-03-24T00:30:01Z",
        ..root_fixtures[0]
      },
      TokenFixture {
        timestamp: "2026-03-24T00:30:02Z",
        ..root_fixtures[1]
      },
      TokenFixture {
        timestamp: "2026-03-24T00:30:03Z",
        ..root_fixtures[2]
      },
      TokenFixture {
        timestamp: "2026-03-24T00:31:00Z",
        total: (310, 0, 0, 310),
        last: (50, 0, 0, 50),
      },
    ];

    let mut root_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      root_session_id,
    );
    for fixture in root_fixtures.iter().copied() {
      root_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&root_path, root_body).expect("write root session");

    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:30:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:30:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id, root_session_id,
    );
    for fixture in child_fixtures.iter().copied() {
      child_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&child_path, child_body).expect("write child session");

    let mut grandchild_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      grandchild_session_id, child_session_id,
    );
    for (index, fixture) in child_fixtures.iter().copied().enumerate() {
      let timestamp = match index {
        0 => "2026-03-24T01:00:01Z",
        1 => "2026-03-24T01:00:02Z",
        2 => "2026-03-24T01:00:03Z",
        _ => "2026-03-24T01:00:04Z",
      };
      grandchild_body.push_str(&token_count_line(TokenFixture {
        timestamp,
        ..fixture
      }));
    }
    grandchild_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T01:01:00Z",
      total: (330, 0, 0, 330),
      last: (20, 0, 0, 20),
    }));
    std::fs::write(&grandchild_path, grandchild_body).expect("write grandchild session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("full family scan");

    let conn = open_connection(&db_path).expect("open db");
    let root_total = session_usage_totals(&conn, root_session_id).3;
    let child_total = session_usage_totals(&conn, child_session_id).3;
    let grandchild_total = session_usage_totals(&conn, grandchild_session_id).3;
    assert_eq!(root_total, 260);
    assert_eq!(child_total, 50);
    assert_eq!(grandchild_total, 20);
    assert_eq!(root_total + child_total + grandchild_total, 330);
  }

  #[test]
  fn parent_path_validation_rejects_child_file_with_replayed_parent_meta() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "66666666-6666-4666-8666-666666666666";
    let child_session_id = "77777777-7777-4777-8777-777777777777";
    let parent_path = sessions_dir.join(format!(
      "rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"
    ));
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T01-00-00-{child_session_id}.jsonl"
    ));

    let mut parent_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      parent_session_id,
    );
    parent_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T00:00:01Z",
      total: (25, 0, 0, 25),
      last: (25, 0, 0, 25),
    }));
    std::fs::write(&parent_path, parent_body).expect("write parent session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("full parent scan");

    let conn = open_connection(&db_path).expect("open db to corrupt parent source paths");
    assert_eq!(
      conn
        .execute(
          "UPDATE sessions SET source_path = ?1 WHERE session_id = ?2",
          params![child_path.to_string_lossy().to_string(), parent_session_id],
        )
        .expect("corrupt parent source path"),
      1
    );
    assert_eq!(
      conn
        .execute(
          "UPDATE import_state SET source_path = ?1 WHERE session_id = ?2",
          params![child_path.to_string_lossy().to_string(), parent_session_id],
        )
        .expect("corrupt parent import state path"),
      1
    );
    drop(conn);
    std::fs::remove_file(&parent_path).expect("remove original parent source");

    let child_created_at = "2026-03-24T01:00:00Z";
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_created_at, child_session_id, parent_session_id, parent_session_id, child_created_at,
    );
    for fixture in [
      TokenFixture {
        timestamp: child_created_at,
        total: (100, 0, 0, 100),
        last: (40, 0, 0, 40),
      },
      TokenFixture {
        timestamp: child_created_at,
        total: (150, 0, 0, 150),
        last: (50, 0, 0, 50),
      },
    ] {
      child_body.push_str(&token_count_line(fixture));
    }
    std::fs::write(&child_path, child_body).expect("write child with replayed parent meta");

    let incremental =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
        .expect("incremental child scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(incremental.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, parent_session_id).3, 25);
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 90);
  }

  #[test]
  fn fork_first_snapshot_uses_last_usage_as_baseline() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    let child_session_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T01-00-00-{child_session_id}.jsonl"
    ));
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id, parent_session_id,
    );
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T01:00:00Z",
      total: (1000, 0, 0, 1000),
      last: (40, 0, 0, 40),
    }));
    std::fs::write(child_path, child_body).expect("write fork session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 40);
  }

  #[test]
  fn thread_spawn_without_fork_keeps_full_usage() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "dddddddd-dddd-dddd-dddd-dddddddddddd";
    let child_session_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee";
    let child_path = sessions_dir.join(format!(
      "rollout-2026-03-24T02-00-00-{child_session_id}.jsonl"
    ));
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T02:00:00Z\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"source\":{{\"subagent\":{{\"thread_spawn\":{{",
        "\"parent_thread_id\":\"{}\"}}}}}}}}}}\n",
        "{{\"timestamp\":\"2026-03-24T02:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id, parent_session_id,
    );
    child_body.push_str(&token_count_line(TokenFixture {
      timestamp: "2026-03-24T02:00:00Z",
      total: (1000, 0, 0, 1000),
      last: (40, 0, 0, 40),
    }));
    std::fs::write(child_path, child_body).expect("write thread-spawn session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, child_session_id).3, 1000);
  }

  #[test]
  fn invalid_custom_home_does_not_advance_completed_scan_time() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let missing = directory.path().join("missing-codex-home");

    let error = perform_scan(&db_path, Some(missing.to_string_lossy().to_string()))
      .expect_err("missing home must fail");
    assert!(error.contains("existing directory"));

    let conn = open_connection(&db_path).expect("open db");
    let completed: Option<String> = conn
      .query_row(
        "SELECT last_scan_completed_at FROM sync_settings WHERE singleton_id = 1",
        [],
        |row| row.get(0),
      )
      .expect("load completion");
    assert!(completed.is_none());
  }

  #[test]
  fn scan_does_not_restore_freshness_after_source_changes_mid_import() {
    let directory = tempdir().expect("tempdir");
    let old_codex_home = directory.path().join("old-codex-home");
    let new_codex_home = directory.path().join("new-codex-home");
    let sessions_dir = old_codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("old sessions dir");
    std::fs::create_dir_all(&new_codex_home).expect("new Codex home");

    let session_path = sessions_dir.join("source-race.jsonl");
    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"abababab-abab-abab-abab-abababababab\"}}\n",
        "{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}\n",
        "{\"timestamp\":\"2026-07-10T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10,\"reasoning_output_tokens\":0,\"total_tokens\":110}}}}\n"
      ),
    )
    .expect("write session");

    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init database");
    let mut settings = get_sync_settings(&conn).expect("load settings");
    settings.codex_home = Some(old_codex_home.to_string_lossy().to_string());
    save_sync_settings(&conn, &settings).expect("save old source");

    let new_home_sql = new_codex_home.to_string_lossy().replace('\'', "''");
    conn
      .execute_batch(&format!(
        "
        CREATE TRIGGER switch_codex_home_during_import
        AFTER INSERT ON usage_events
        BEGIN
          UPDATE sync_settings
          SET codex_home = '{new_home_sql}',
              last_scan_started_at = NULL,
              last_scan_completed_at = NULL,
              last_full_scan_completed_at = NULL
          WHERE singleton_id = 1;
        END;
        "
      ))
      .expect("create source switch trigger");
    drop(conn);

    perform_scan(&db_path, Some(old_codex_home.to_string_lossy().to_string()))
      .expect("scan old source");

    let conn = open_connection(&db_path).expect("reopen database");
    let (codex_home, started, completed, full_completed): (
      Option<String>,
      Option<String>,
      Option<String>,
      Option<String>,
    ) = conn
      .query_row(
        "
        SELECT codex_home, last_scan_started_at, last_scan_completed_at,
               last_full_scan_completed_at
        FROM sync_settings
        WHERE singleton_id = 1
        ",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
      )
      .expect("load scan freshness");

    assert_eq!(
      codex_home.as_deref(),
      Some(new_codex_home.to_string_lossy().as_ref())
    );
    assert_eq!(started, None);
    assert_eq!(completed, None);
    assert_eq!(full_completed, None);
  }

  #[test]
  fn scan_writes_freshness_when_source_selector_is_unchanged() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).expect("Codex home");
    let db_path = directory.path().join("usage.sqlite");

    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init database");
    let mut settings = get_sync_settings(&conn).expect("load settings");
    settings.codex_home = Some(codex_home.to_string_lossy().to_string());
    save_sync_settings(&conn, &settings).expect("save source");
    drop(conn);

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("scan matching source");

    let conn = open_connection(&db_path).expect("reopen database");
    let (started, completed, full_completed): (Option<String>, Option<String>, Option<String>) =
      conn
        .query_row(
          "
        SELECT last_scan_started_at, last_scan_completed_at,
               last_full_scan_completed_at
        FROM sync_settings
        WHERE singleton_id = 1
        ",
          [],
          |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load scan freshness");

    assert!(started.is_some());
    assert!(completed.is_some());
    assert!(full_completed.is_some());
  }

  #[test]
  fn scan_does_not_write_freshness_for_an_override_from_the_previous_source() {
    let directory = tempdir().expect("tempdir");
    let old_codex_home = directory.path().join("old-codex-home");
    let new_codex_home = directory.path().join("new-codex-home");
    std::fs::create_dir_all(&old_codex_home).expect("old Codex home");
    std::fs::create_dir_all(&new_codex_home).expect("new Codex home");
    let db_path = directory.path().join("usage.sqlite");

    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init database");
    let mut settings = get_sync_settings(&conn).expect("load settings");
    settings.codex_home = Some(new_codex_home.to_string_lossy().to_string());
    save_sync_settings(&conn, &settings).expect("save new source");
    drop(conn);

    perform_scan(&db_path, Some(old_codex_home.to_string_lossy().to_string()))
      .expect("scan previous source");

    let conn = open_connection(&db_path).expect("reopen database");
    let (started, completed, full_completed): (Option<String>, Option<String>, Option<String>) =
      conn
        .query_row(
          "
        SELECT last_scan_started_at, last_scan_completed_at,
               last_full_scan_completed_at
        FROM sync_settings
        WHERE singleton_id = 1
        ",
          [],
          |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load scan freshness");

    assert_eq!(started, None);
    assert_eq!(completed, None);
    assert_eq!(full_completed, None);
  }

  #[test]
  fn changed_resolved_default_source_forces_full_scan() {
    assert_eq!(
      effective_scan_scope(ScanKind::Incremental, false, false, false, true),
      ScanKind::Full
    );
  }

  #[test]
  fn moved_default_source_reconciles_sessions_from_the_previous_existing_home() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let first_codex_home = directory.path().join("codex-home-a");
    let second_codex_home = directory.path().join("codex-home-b");
    let first_sessions = first_codex_home.join("sessions");
    let second_archives = second_codex_home.join("archived_sessions");
    std::fs::create_dir_all(&first_sessions).expect("first sessions");
    std::fs::create_dir_all(&second_archives).expect("second archives");

    let first_session_id = "18181818-1818-1818-1818-181818181818";
    write_session_file(
      &first_sessions.join("first.jsonl"),
      first_session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let second_session_id = "28282828-2828-2828-2828-282828282828";
    write_session_file(
      &second_archives.join("second.jsonl"),
      second_session_id,
      &[("2026-07-10T01:00:00Z", 200, 40, 20, 220)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let _environment = CodexHomeEnvGuard::set(&first_codex_home);
    perform_scan(&db_path, None).expect("scan first default source");

    std::env::set_var("CODEX_HOME", &second_codex_home);
    let result = perform_incremental_scan(&db_path, None).expect("scan moved default source");

    let conn = open_connection(&db_path).expect("open database");
    let (selector, resolved_source): (Option<String>, Option<String>) = conn
      .query_row(
        "
        SELECT codex_home, last_scan_codex_home
        FROM sync_settings
        WHERE singleton_id = 1
        ",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
      )
      .expect("load scan source identity");

    assert_eq!(selector, None);
    assert_eq!(
      resolved_source.as_deref(),
      Some(second_codex_home.to_string_lossy().as_ref())
    );
    assert_eq!(result.scanned_files, 1);
    assert_eq!(session_usage_totals(&conn, second_session_id).3, 220);
    assert_eq!(session_usage_totals(&conn, first_session_id).3, 110);
    assert_eq!(
      session_source_state(&conn, first_session_id),
      Some("missing".to_string())
    );
    assert_eq!(
      import_state_session_id(&conn, &first_sessions.join("first.jsonl")),
      None
    );
    assert!(first_sessions.join("first.jsonl").is_file());
  }

  #[test]
  fn failed_full_scan_rolls_back_freshness_and_retry_reconciles_previous_source() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let first_codex_home = directory.path().join("codex-home-a");
    let second_codex_home = directory.path().join("codex-home-b");
    let first_sessions = first_codex_home.join("sessions");
    let second_sessions = second_codex_home.join("sessions");
    std::fs::create_dir_all(&first_sessions).expect("first sessions");
    std::fs::create_dir_all(&second_sessions).expect("second sessions");

    let first_session_id = "19191919-1919-1919-1919-191919191919";
    let first_session_path = first_sessions.join("first.jsonl");
    write_session_file(
      &first_session_path,
      first_session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let second_session_id = "29292929-2929-2929-2929-292929292929";
    write_session_file(
      &second_sessions.join("second.jsonl"),
      second_session_id,
      &[("2026-07-10T01:00:00Z", 200, 40, 20, 220)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let _environment = CodexHomeEnvGuard::set(&first_codex_home);
    perform_scan(&db_path, None).expect("scan first default source");

    let conn = open_connection(&db_path).expect("open database");
    let previous_full_scan_completed_at =
      get_last_full_scan_completed(&conn).expect("load previous full freshness");
    assert!(previous_full_scan_completed_at.is_some());
    conn
      .execute_batch(&format!(
        "
        CREATE TRIGGER fail_previous_source_reconciliation
        BEFORE UPDATE OF source_state ON sessions
        WHEN OLD.session_id = '{first_session_id}'
        BEGIN
          SELECT RAISE(ABORT, 'forced source reconciliation failure');
        END;
        "
      ))
      .expect("create reconciliation trigger");
    drop(conn);

    std::env::set_var("CODEX_HOME", &second_codex_home);
    let error =
      perform_incremental_scan(&db_path, None).expect_err("first moved-source scan should fail");
    assert!(error.contains("forced source reconciliation failure"));

    let conn = open_connection(&db_path).expect("reopen failed database");
    assert_eq!(
      get_last_full_scan_completed(&conn).expect("load rolled-back freshness"),
      previous_full_scan_completed_at
    );
    conn
      .execute_batch("DROP TRIGGER fail_previous_source_reconciliation;")
      .expect("drop reconciliation trigger");
    drop(conn);

    let retry = perform_incremental_scan(&db_path, None).expect("retry moved default source");

    let conn = open_connection(&db_path).expect("open retried database");
    assert_eq!(retry.scanned_files, 1);
    assert_eq!(session_usage_totals(&conn, second_session_id).3, 220);
    assert_eq!(
      session_source_state(&conn, first_session_id),
      Some("missing".to_string())
    );
    assert_eq!(import_state_session_id(&conn, &first_session_path), None);
    assert!(first_session_path.is_file());
  }

  #[test]
  fn partial_full_scan_invalidates_freshness_and_tracks_skipped_rate_limit_backfill() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let archived_sessions = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&archived_sessions).expect("archived sessions");

    let session_id = "39393939-3939-3939-3939-393939393939";
    let session_path = archived_sessions.join("archive.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );

    let db_path = directory.path().join("usage.sqlite");
    let _environment = CodexHomeEnvGuard::set(&codex_home);
    perform_scan(&db_path, None).expect("initial full scan");

    let conn = open_connection(&db_path).expect("open initial database");
    assert!(get_last_full_scan_completed(&conn)
      .expect("load initial freshness")
      .is_some());
    conn
      .execute(
        "DELETE FROM data_repairs WHERE repair_key = ?1",
        params![RATE_LIMIT_SAMPLE_BACKFILL_KEY],
      )
      .expect("make rate-limit backfill pending");
    drop(conn);

    std::fs::write(&session_path, [0xff, 0xfe, 0xfd]).expect("corrupt archived session");
    perform_scan(&db_path, None).expect("partial full scan");

    let conn = open_connection(&db_path).expect("open partial database");
    let (completed, full_completed): (Option<String>, Option<String>) = conn
      .query_row(
        "SELECT last_scan_completed_at, last_full_scan_completed_at FROM sync_settings WHERE singleton_id = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
      )
      .expect("load partial scan freshness");
    assert!(completed.is_some());
    assert_eq!(full_completed, None);
    let pending_rate_limit_path: Option<String> = conn
      .query_row(
        "SELECT source_path FROM data_repair_pending_files WHERE repair_key = ?1",
        params![RATE_LIMIT_SAMPLE_BACKFILL_KEY],
        |row| row.get(0),
      )
      .optional()
      .expect("load pending rate-limit repair");
    assert_eq!(
      pending_rate_limit_path.as_deref(),
      Some(session_path.to_string_lossy().as_ref())
    );
    drop(conn);

    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 200, 40, 20, 220),
      ],
    );
    let retry = perform_incremental_scan(&db_path, None).expect("retry repaired archive");

    let conn = open_connection(&db_path).expect("open repaired database");
    assert_eq!(retry.scanned_files, 1);
    assert_eq!(session_usage_totals(&conn, session_id).3, 220);
    assert!(get_last_full_scan_completed(&conn)
      .expect("load repaired freshness")
      .is_some());
    let pending_rate_limit_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repair_pending_files WHERE repair_key = ?1",
        params![RATE_LIMIT_SAMPLE_BACKFILL_KEY],
        |row| row.get(0),
      )
      .expect("count pending rate-limit repairs");
    assert_eq!(pending_rate_limit_count, 0);
  }

  #[test]
  fn incremental_scan_retries_unchanged_pending_rate_limit_archive() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let archived_sessions = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&archived_sessions).expect("archived sessions");

    let session_id = "69696969-6969-4969-8969-696969696969";
    let session_path =
      archived_sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    write_session_file(
      &session_path,
      session_id,
      &[("2026-07-10T00:00:01Z", 80, 0, 20, 100)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("initial scan");

    let conn = open_connection(&db_path).expect("open db");
    conn
      .execute(
        "
        INSERT INTO data_repair_pending_files (repair_key, source_path, last_error, updated_at)
        VALUES (?1, ?2, 'temporary read failure', ?3)
        ",
        params![
          RATE_LIMIT_SAMPLE_BACKFILL_KEY,
          session_path.to_string_lossy().to_string(),
          now_utc_string(),
        ],
      )
      .expect("insert pending rate-limit archive");
    drop(conn);

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("retry unchanged rate-limit archive");

    let conn = open_connection(&db_path).expect("open retried db");
    assert_eq!(result.updated_sessions, 1);
    let pending_rate_limit_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repair_pending_files WHERE repair_key = ?1",
        params![RATE_LIMIT_SAMPLE_BACKFILL_KEY],
        |row| row.get(0),
      )
      .expect("count pending rate-limit repairs");
    assert_eq!(pending_rate_limit_count, 0);
  }

  #[test]
  fn skipped_archive_keeps_moved_default_source_due_for_full_retry() {
    let _environment_lock = CODEX_HOME_ENV_LOCK.lock().expect("lock CODEX_HOME");
    let directory = tempdir().expect("tempdir");
    let first_codex_home = directory.path().join("codex-home-a");
    let second_codex_home = directory.path().join("codex-home-b");
    let first_sessions = first_codex_home.join("sessions");
    let second_sessions = second_codex_home.join("sessions");
    let second_archives = second_codex_home.join("archived_sessions");
    std::fs::create_dir_all(&first_sessions).expect("first sessions");
    std::fs::create_dir_all(&second_sessions).expect("second sessions");
    std::fs::create_dir_all(&second_archives).expect("second archives");

    write_session_file(
      &first_sessions.join("first.jsonl"),
      "38383838-3838-3838-3838-383838383838",
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    write_session_file(
      &second_sessions.join("tracked.jsonl"),
      "48484848-4848-4848-4848-484848484848",
      &[("2026-07-10T01:00:00Z", 150, 30, 15, 165)],
    );
    let repaired_session_id = "58585858-5858-5858-5858-585858585858";
    let repaired_archive = second_archives.join("repaired.jsonl");
    std::fs::write(&repaired_archive, [0xff, 0xfe, 0xfd]).expect("write unreadable archive");

    let db_path = directory.path().join("usage.sqlite");
    let _environment = CodexHomeEnvGuard::set(&first_codex_home);
    perform_scan(&db_path, None).expect("scan first default source");

    std::env::set_var("CODEX_HOME", &second_codex_home);
    let partial =
      perform_incremental_scan(&db_path, None).expect("scan moved source with skipped archive");
    assert_eq!(partial.scanned_files, 2);

    let conn = open_connection(&db_path).expect("open partial database");
    assert_eq!(
      get_last_full_scan_completed(&conn).expect("load full freshness"),
      None
    );
    drop(conn);

    write_session_file(
      &repaired_archive,
      repaired_session_id,
      &[("2026-07-10T01:30:00Z", 200, 40, 20, 220)],
    );
    let retry = perform_incremental_scan(&db_path, None).expect("retry repaired archive");

    let conn = open_connection(&db_path).expect("open repaired database");
    assert_eq!(retry.scanned_files, 2);
    assert_eq!(session_usage_totals(&conn, repaired_session_id).3, 220);
  }

  #[test]
  fn custom_home_path_expands_supported_tilde_forms() {
    let directory = tempdir().expect("tempdir");
    let nested = directory.path().join("codex-home");
    std::fs::create_dir_all(&nested).expect("codex home");

    assert_eq!(
      validate_codex_home(PathBuf::from("~"), Some(directory.path())).expect("bare tilde"),
      directory.path()
    );
    assert_eq!(
      validate_codex_home(PathBuf::from("~/codex-home"), Some(directory.path()))
        .expect("tilde prefix"),
      nested
    );
  }

  #[test]
  fn incremental_scan_imports_final_snapshot_after_active_file_is_archived() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    let archived = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    std::fs::create_dir_all(&archived).expect("archive");
    let session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    let active_path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let archived_path = archived.join(active_path.file_name().expect("filename"));
    write_session_file(
      &active_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    write_session_file(
      &active_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );
    std::fs::rename(&active_path, &archived_path).expect("archive session");
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id).3, 200);
    assert_eq!(
      session_source_state(&conn, session_id).as_deref(),
      Some("archived")
    );
  }

  #[test]
  fn incremental_scan_reimports_archived_file_after_incomplete_tail_is_finished() {
    use std::io::Write;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    let archived = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    std::fs::create_dir_all(&archived).expect("archive");
    let session_id = "a0a0a0a0-a0a0-a0a0-a0a0-a0a0a0a0a0a0";
    let active_path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let archived_path = archived.join(active_path.file_name().expect("filename"));
    write_session_file(
      &active_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let mut file = std::fs::OpenOptions::new()
      .append(true)
      .open(&active_path)
      .expect("open active session");
    file
      .write_all(
        concat!(
          "{\"timestamp\":\"2026-07-10T00:01:00Z\",\"type\":\"event_msg\",\"payload\":{",
          "\"type\":\"token_count\",\"info\":{\"total_token_usage\":{",
          "\"input_tokens\":180,\"cached_input_tokens\":40,\"output_tokens\":20,"
        )
        .as_bytes(),
      )
      .expect("write incomplete tail");
    drop(file);
    std::fs::rename(&active_path, &archived_path).expect("archive session");

    let first_result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
        .expect("import complete prefix from archive");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(first_result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (100, 20, 10, 110, 1)
    );
    let archived_state: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM import_state WHERE source_path = ?1 AND source_bucket = 'archived'",
        params![archived_path.to_string_lossy().to_string()],
        |row| row.get(0),
      )
      .expect("query archived state");
    assert_eq!(archived_state, 1);
    drop(conn);

    let mut file = std::fs::OpenOptions::new()
      .append(true)
      .open(&archived_path)
      .expect("open archived session");
    file
      .write_all(
        concat!(
          "\"reasoning_output_tokens\":0,\"total_tokens\":200}}",
          ",\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
        )
        .as_bytes(),
      )
      .expect("finish archived tail");
    drop(file);

    let result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("reimport finished archive");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(
      session_usage_totals(&conn, session_id),
      (180, 40, 20, 200, 2)
    );
    assert_eq!(
      session_source_state(&conn, session_id).as_deref(),
      Some("archived")
    );
  }

  #[test]
  fn incremental_scan_retries_moved_archive_after_read_error() {
    use std::io::Write;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    let archived = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    std::fs::create_dir_all(&archived).expect("archive");
    let session_id = "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1";
    let active_path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let archived_path = archived.join(active_path.file_name().expect("filename"));
    write_session_file(
      &active_path,
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    write_session_file(
      &sessions.join("other.jsonl"),
      "a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2",
      &[("2026-07-10T00:00:00Z", 50, 10, 5, 55)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let mut file = File::create(&active_path).expect("session file");
    writeln!(
      file,
      "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{session_id}\"}}}}"
    )
    .expect("meta");
    file.write_all(&[0xff, b'\n']).expect("invalid utf8");
    drop(file);
    std::fs::rename(&active_path, &archived_path).expect("archive session");
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("scan skips unreadable archive");

    let conn = open_connection(&db_path).expect("open db");
    let retained_state: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM import_state WHERE source_path = ?1",
        params![active_path.to_string_lossy().to_string()],
        |row| row.get(0),
      )
      .expect("retained active state");
    assert_eq!(retained_state, 1);
    drop(conn);

    write_session_file(
      &archived_path,
      session_id,
      &[
        ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
        ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
      ],
    );
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("retry moved archive");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id).3, 200);
    assert_eq!(
      session_source_state(&conn, session_id).as_deref(),
      Some("archived")
    );
  }

  #[test]
  fn full_scan_refreshes_title_when_only_session_index_changes() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    write_session_file(
      &sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl")),
      session_id,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let index_path = codex_home.join("session_index.jsonl");
    std::fs::write(
      &index_path,
      format!("{{\"id\":\"{session_id}\",\"thread_name\":\"A\"}}\n"),
    )
    .expect("title A");
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::write(
      &index_path,
      format!("{{\"id\":\"{session_id}\",\"thread_name\":\"B\"}}\n"),
    )
    .expect("title B");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db");
    let title: String = conn
      .query_row(
        "SELECT title FROM sessions WHERE session_id = ?1",
        params![session_id],
        |row| row.get(0),
      )
      .expect("title");
    assert_eq!(title, "B");
  }

  #[test]
  fn invalid_utf8_does_not_commit_partial_session_or_import_state() {
    use std::io::Write;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    let path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let mut file = File::create(&path).expect("session file");
    writeln!(
      file,
      "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{session_id}\"}}}}"
    )
    .expect("meta");
    file.write_all(&[0xff, b'\n']).expect("invalid utf8");
    writeln!(
      file,
      "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}"
    )
    .expect("tail");
    drop(file);

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("scan skips bad file");
    let conn = open_connection(&db_path).expect("open db");
    let sessions_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
      .expect("sessions");
    let states_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM import_state", [], |row| row.get(0))
      .expect("states");
    assert_eq!((sessions_count, states_count), (0, 0));
  }

  #[test]
  fn incremental_scan_repairs_missing_conversation_link_without_source_change() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let parent = "dddddddd-dddd-dddd-dddd-dddddddddddd";
    let child = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee";
    write_session_file_with_parent(
      &sessions.join(format!("rollout-2026-07-10T00-00-00-{parent}.jsonl")),
      parent,
      None,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    write_session_file_with_parent(
      &sessions.join(format!("rollout-2026-07-10T00-01-00-{child}.jsonl")),
      child,
      Some(parent),
      &[("2026-07-10T00:01:00Z", 50, 10, 5, 55)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    let conn = open_connection(&db_path).expect("open db");
    conn
      .execute(
        "DELETE FROM conversation_links WHERE session_id = ?1",
        params![child],
      )
      .expect("remove link");
    drop(conn);

    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("repair scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      conversation_link(&conn, child).expect("child link").0,
      parent
    );
  }

  #[test]
  fn incremental_scan_repairs_conversation_link_parent_mismatch_without_source_change() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let parent = "f1f1f1f1-f1f1-f1f1-f1f1-f1f1f1f1f1f1";
    let child = "f2f2f2f2-f2f2-f2f2-f2f2-f2f2f2f2f2f2";
    write_session_file(
      &sessions.join(format!("rollout-2026-07-10T00-00-00-{parent}.jsonl")),
      parent,
      &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    write_session_file_with_parent(
      &sessions.join(format!("rollout-2026-07-10T00-01-00-{child}.jsonl")),
      child,
      Some(parent),
      &[("2026-07-10T00:01:00Z", 50, 10, 5, 55)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    let conn = open_connection(&db_path).expect("open db");
    conn
      .execute(
        "UPDATE conversation_links SET parent_session_id = NULL WHERE session_id = ?1",
        params![child],
      )
      .expect("corrupt direct parent");
    drop(conn);

    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("repair scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(
      conversation_link(&conn, child)
        .expect("child link")
        .1
        .as_deref(),
      Some(parent)
    );
  }

  #[derive(Clone, Copy)]
  struct TokenFixture {
    timestamp: &'static str,
    total: (i64, i64, i64, i64),
    last: (i64, i64, i64, i64),
  }

  fn token_count_line(fixture: TokenFixture) -> String {
    let (input, cached, output, total) = fixture.total;
    let (last_input, last_cached, last_output, last_total) = fixture.last;
    format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"event_msg\",\"payload\":{{",
        "\"type\":\"token_count\",\"info\":{{",
        "\"total_token_usage\":{{\"input_tokens\":{},\"cached_input_tokens\":{},",
        "\"output_tokens\":{},\"reasoning_output_tokens\":0,\"total_tokens\":{}}},",
        "\"last_token_usage\":{{\"input_tokens\":{},\"cached_input_tokens\":{},",
        "\"output_tokens\":{},\"reasoning_output_tokens\":0,\"total_tokens\":{}}}",
        "}}}}}}\n"
      ),
      fixture.timestamp,
      input,
      cached,
      output,
      total,
      last_input,
      last_cached,
      last_output,
      last_total,
    )
  }

  fn write_large_session_file(path: &Path, session_id: &str, minimum_bytes: usize) -> i64 {
    let mut body = format!(
      concat!(
        "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}\n"
      ),
      session_id
    );
    let mut total_tokens = 0i64;
    while body.len() <= minimum_bytes {
      total_tokens += 10;
      body.push_str(&token_count_line(TokenFixture {
        timestamp: "2026-07-10T00:00:02Z",
        total: (total_tokens, 0, 0, total_tokens),
        last: (10, 0, 0, 10),
      }));
    }
    std::fs::write(path, body).expect("write large session");
    total_tokens
  }

  fn write_session_file(path: &Path, session_id: &str, snapshots: &[(&str, i64, i64, i64, i64)]) {
    write_session_file_with_parent(path, session_id, None, snapshots);
  }

  fn write_session_file_with_parent(
    path: &Path,
    session_id: &str,
    parent_session_id: Option<&str>,
    snapshots: &[(&str, i64, i64, i64, i64)],
  ) {
    let session_meta = match parent_session_id {
      Some(parent_session_id) => format!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        snapshots.first().map(|item| item.0).unwrap_or("2026-03-24T00:00:00Z"),
        session_id,
        parent_session_id
      ),
      None => format!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\"}}}}\n",
        snapshots.first().map(|item| item.0).unwrap_or("2026-03-24T00:00:00Z"),
        session_id
      ),
    };

    let mut body = session_meta;
    body.push_str(
      "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
    );

    for (timestamp, input_tokens, cached_input_tokens, output_tokens, total_tokens) in snapshots {
      body.push_str(&format!(
        concat!(
          "{{\"timestamp\":\"{}\",\"type\":\"event_msg\",\"payload\":{{",
          "\"type\":\"token_count\",",
          "\"info\":{{\"total_token_usage\":{{",
          "\"input_tokens\":{},\"cached_input_tokens\":{},\"output_tokens\":{},",
          "\"reasoning_output_tokens\":0,\"total_tokens\":{}",
          "}}}},",
          "\"rate_limits\":{{\"plan_type\":\"pro\"}}",
          "}}}}\n"
        ),
        timestamp, input_tokens, cached_input_tokens, output_tokens, total_tokens
      ));
    }

    std::fs::write(path, body).expect("write session");
  }

  fn write_replayed_fork_session_file(
    path: &Path,
    session_id: &str,
    parent_session_id: &str,
    snapshots: &[(&str, i64, i64, i64, i64)],
  ) {
    let first_timestamp = snapshots
      .first()
      .map(|item| item.0)
      .unwrap_or("2026-03-24T00:00:00Z");
    let mut body = format!(
      concat!(
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"forked_from_id\":\"{}\",",
        "\"source\":{{\"subagent\":{{\"thread_spawn\":{{",
        "\"parent_thread_id\":\"{}\",\"agent_nickname\":\"Scout\",\"agent_role\":\"explore\"",
        "}}}}}}",
        "}}}}\n",
        "{{\"timestamp\":\"{}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      first_timestamp,
      session_id,
      parent_session_id,
      parent_session_id,
      first_timestamp,
      parent_session_id,
    );

    for (timestamp, input_tokens, cached_input_tokens, output_tokens, total_tokens) in snapshots {
      body.push_str(&format!(
        concat!(
          "{{\"timestamp\":\"{}\",\"type\":\"event_msg\",\"payload\":{{",
          "\"type\":\"token_count\",",
          "\"info\":{{\"total_token_usage\":{{",
          "\"input_tokens\":{},\"cached_input_tokens\":{},\"output_tokens\":{},",
          "\"reasoning_output_tokens\":0,\"total_tokens\":{}",
          "}}}},",
          "\"rate_limits\":{{\"plan_type\":\"pro\"}}",
          "}}}}\n"
        ),
        timestamp, input_tokens, cached_input_tokens, output_tokens, total_tokens
      ));
    }

    std::fs::write(path, body).expect("write replayed fork session");
  }

  fn session_root_and_subagents(conn: &Connection, session_id: &str) -> Option<(String, bool)> {
    conn
      .query_row(
        "SELECT root_session_id, contains_subagents FROM sessions WHERE session_id = ?1",
        params![session_id],
        |row| Ok((row.get(0)?, row.get::<_, i64>(1)? != 0)),
      )
      .optional()
      .expect("query root and subagents")
  }

  fn conversation_link(
    conn: &Connection,
    session_id: &str,
  ) -> Option<(String, Option<String>, i64)> {
    conn
      .query_row(
        "
        SELECT root_session_id, parent_session_id, depth
        FROM conversation_links
        WHERE session_id = ?1
        ",
        params![session_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
      )
      .optional()
      .expect("query conversation link")
  }

  fn session_usage_totals(conn: &Connection, session_id: &str) -> (i64, i64, i64, i64, i64) {
    conn
      .query_row(
        "
        SELECT
          COALESCE(SUM(input_tokens), 0),
          COALESCE(SUM(cached_input_tokens), 0),
          COALESCE(SUM(output_tokens), 0),
          COALESCE(SUM(total_tokens), 0),
          COUNT(*)
        FROM usage_events
        WHERE session_id = ?1
        ",
        params![session_id],
        |row| {
          Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
          ))
        },
      )
      .expect("query usage totals")
  }

  fn session_source_state(conn: &Connection, session_id: &str) -> Option<String> {
    conn
      .query_row(
        "SELECT source_state FROM sessions WHERE session_id = ?1",
        params![session_id],
        |row| row.get(0),
      )
      .optional()
      .expect("query source state")
  }

  fn import_state_session_id(conn: &Connection, path: &Path) -> Option<String> {
    conn
      .query_row(
        "SELECT session_id FROM import_state WHERE source_path = ?1",
        params![path.to_string_lossy().to_string()],
        |row| row.get(0),
      )
      .optional()
      .expect("query import state session id")
  }
}

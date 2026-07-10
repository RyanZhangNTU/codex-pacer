use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use chrono::{Local, LocalResult, TimeZone, Timelike};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use walkdir::WalkDir;

use crate::database::{
  bool_to_i64, get_sync_settings, init_db, now_utc_string, open_connection,
  replace_session_rate_limit_samples, set_last_scan_started_for_source, set_scan_completed_for_source,
};
use crate::models::{RateLimitSampleRecord, RawSession, ScanResult, TokenUsage, UsageSnapshot};
use crate::pricing::{
  calculate_value_usd, load_catalog_map, normalize_model_id, resolve_pricing, seed_pricing_catalog,
};

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
  explicit_fast_mode: Option<bool>,
  latest_plan_type: Option<String>,
  last_model_id: Option<String>,
}

#[derive(Debug, Clone)]
struct SessionMetaCandidate {
  session_id: String,
  parent_session_id: Option<String>,
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
  Fatal(String),
}

const TOKEN_USAGE_MONOTONIC_REPAIR_KEY: &str = "token_usage_monotonic_v2";
const RATE_LIMIT_SAMPLE_BACKFILL_KEY: &str = "rate_limit_sample_backfill_v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScanScope {
  Full,
  Incremental,
}

pub fn perform_scan(db_path: &Path, codex_home_override: Option<String>) -> Result<ScanResult, String> {
  perform_scan_with_scope(db_path, codex_home_override, ScanScope::Full)
}

pub fn perform_incremental_scan(db_path: &Path, codex_home_override: Option<String>) -> Result<ScanResult, String> {
  perform_scan_with_scope(db_path, codex_home_override, ScanScope::Incremental)
}

fn perform_scan_with_scope(
  db_path: &Path,
  codex_home_override: Option<String>,
  requested_scope: ScanScope,
) -> Result<ScanResult, String> {
  let mut conn = open_connection(db_path).map_err(|error| error.to_string())?;
  init_db(&conn).map_err(|error| error.to_string())?;
  let scan_source_selector = get_sync_settings(&conn)
    .map_err(|error| error.to_string())?
    .codex_home;
  seed_pricing_catalog(&conn).map_err(|error| error.to_string())?;

  let home_dir = dirs::home_dir();
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
  let scan_started_at = now_utc_string();
  let scan_freshness_start = if track_scan_freshness {
    set_last_scan_started_for_source(
      &conn,
      &scan_started_at,
      scan_source_selector.as_deref(),
      &resolved_codex_home,
    )
    .map_err(|error| error.to_string())?
  } else {
    Default::default()
  };

  let import_state = load_import_state(&conn).map_err(|error| error.to_string())?;
  let needs_rate_limit_backfill = needs_rate_limit_sample_backfill(&conn).map_err(|error| error.to_string())?;
  let pending_rate_limit_repair_paths =
    load_pending_data_repair_paths(&conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY).map_err(|error| error.to_string())?;
  let needs_token_usage_repair_sweep =
    data_repair_is_pending(&conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY).map_err(|error| error.to_string())?;
  let pending_token_repair_paths =
    load_pending_data_repair_paths(&conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY).map_err(|error| error.to_string())?;
  let effective_scope = effective_scan_scope(
    requested_scope,
    import_state.is_empty(),
    needs_rate_limit_backfill,
    needs_token_usage_repair_sweep,
    scan_freshness_start.full_scan_required,
  );

  let (session_files, active_paths_kept_for_archive_retry) = match effective_scope {
    ScanScope::Full => (collect_session_files(&codex_home), HashSet::new()),
    ScanScope::Incremental => collect_incremental_session_files(&codex_home, &import_state),
  };
  let mut present_paths: HashSet<String> = session_files
    .iter()
    .map(|item| item.path.to_string_lossy().to_string())
    .collect();
  present_paths.extend(active_paths_kept_for_archive_retry);

  let mut changed_sessions = 0usize;
  let mut imported_session_ids = HashSet::new();

  let mut changed_files = Vec::new();
  for session_file in &session_files {
    let source_path = session_file.path.to_string_lossy().to_string();
    if needs_rate_limit_backfill
      || pending_rate_limit_repair_paths.contains(&source_path)
      || needs_token_usage_repair_sweep
      || pending_token_repair_paths.contains(&source_path)
    {
      changed_files.push(session_file);
      continue;
    }
    if let Some(state) = import_state.get(&source_path) {
      let session_id_mismatch = import_state_session_id_mismatch(state, session_file);
      if state.file_size == session_file.file_size
        && state.file_mtime_ms == session_file.file_mtime_ms
        && !session_id_mismatch
      {
        if let Some(session_id) = &state.session_id {
          imported_session_ids.insert(session_id.clone());
        }
        continue;
      }
    }

    changed_files.push(session_file);
  }

  let titles = if effective_scope == ScanScope::Full || !changed_files.is_empty() {
    load_session_index(&codex_home)
  } else {
    HashMap::new()
  };

  let mut topology_dirty = false;
  let mut new_root_session_ids = Vec::new();
  let mut skipped_session_files = false;
  if !changed_files.is_empty() {
    let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;
    let existing_relations = load_existing_session_relations(&conn).map_err(|error| error.to_string())?;

    for session_file in changed_files {
      let source_path = session_file.path.to_string_lossy().to_string();
      let file_needs_rate_limit_repair =
        needs_rate_limit_backfill || pending_rate_limit_repair_paths.contains(&source_path);
      let file_needs_token_repair =
        needs_token_usage_repair_sweep || pending_token_repair_paths.contains(&source_path);
      let parsed = match parse_session_file(session_file, &titles) {
        Ok(parsed) => parsed,
        Err(error) => {
          skipped_session_files = true;
          log::warn!(
            "Skipping unreadable session file {}: {}",
            session_file.path.display(),
            error
          );
          if file_needs_token_repair {
            mark_data_repair_file_pending(&conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, &source_path, &error)
              .map_err(|error| error.to_string())?;
          }
          if file_needs_rate_limit_repair {
            mark_data_repair_file_pending(&conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY, &source_path, &error)
              .map_err(|error| error.to_string())?;
          }
          continue;
        }
      };
      imported_session_ids.insert(parsed.raw_session.session_id.clone());

      match classify_topology_maintenance(
        existing_relations.get(&parsed.raw_session.session_id),
        existing_relations.get(&parsed.raw_session.session_id).map(|item| item.child_count).unwrap_or_default(),
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

      persist_session(&mut conn, session_file, &parsed, &catalog).map_err(|error| error.to_string())?;
      if file_needs_rate_limit_repair {
        clear_pending_data_repair_file(&conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY, &source_path)
          .map_err(|error| error.to_string())?;
      }
      if file_needs_token_repair {
        clear_pending_data_repair_file(&conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, &source_path)
          .map_err(|error| error.to_string())?;
      }
      changed_sessions += 1;
    }
  }

  if effective_scope == ScanScope::Full {
    refresh_session_titles(&conn, &titles).map_err(|error| error.to_string())?;
  }

  if effective_scope == ScanScope::Full {
    // A full scan that is required for freshness is authoritative even on retry:
    // paths outside the resolved source must not remain active just because they still exist.
    let reconcile_existing_absent_sources = scan_freshness_start.full_scan_required;
    mark_missing_sources(
      &conn,
      &present_paths,
      reconcile_existing_absent_sources,
    )
    .map_err(|error| error.to_string())?;
    prune_import_state(
      &conn,
      &present_paths,
      reconcile_existing_absent_sources,
    )
    .map_err(|error| error.to_string())?;
  } else {
    mark_missing_active_sources(&conn, &present_paths).map_err(|error| error.to_string())?;
  }
  let topology_needs_repair = conversation_links_need_repair(&conn).map_err(|error| error.to_string())?;
  if topology_dirty || topology_needs_repair {
    recompute_conversation_links(&conn).map_err(|error| error.to_string())?;
  } else if !new_root_session_ids.is_empty() {
    upsert_root_conversation_links(&conn, &new_root_session_ids).map_err(|error| error.to_string())?;
  }

  let missing_sessions = conn
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE source_state = 'missing'",
      [],
      |row| row.get::<_, i64>(0),
    )
    .map_err(|error| error.to_string())? as usize;

  let completed_at = now_utc_string();
  if needs_rate_limit_backfill {
    mark_data_repair_complete(&conn, RATE_LIMIT_SAMPLE_BACKFILL_KEY, &completed_at)
      .map_err(|error| error.to_string())?;
  }
  if needs_token_usage_repair_sweep {
    mark_data_repair_complete(&conn, TOKEN_USAGE_MONOTONIC_REPAIR_KEY, &completed_at)
      .map_err(|error| error.to_string())?;
  }
  if scan_freshness_start.recorded {
    set_scan_completed_for_source(
      &conn,
      &completed_at,
      scan_source_selector.as_deref(),
      &resolved_codex_home,
      effective_scope == ScanScope::Full && !skipped_session_files,
      effective_scope == ScanScope::Full && skipped_session_files,
    )
    .map_err(|error| error.to_string())?;
  }

  Ok(ScanResult {
    codex_home: codex_home.to_string_lossy().to_string(),
    scanned_files: session_files.len(),
    imported_sessions: imported_session_ids.len(),
    updated_sessions: changed_sessions,
    missing_sessions,
    last_completed_at: completed_at,
  })
}

fn effective_scan_scope(
  requested_scope: ScanScope,
  import_state_is_empty: bool,
  needs_rate_limit_backfill: bool,
  needs_token_usage_repair_sweep: bool,
  resolved_source_requires_full_scan: bool,
) -> ScanScope {
  if requested_scope == ScanScope::Full
    || import_state_is_empty
    || needs_rate_limit_backfill
    || needs_token_usage_repair_sweep
    || resolved_source_requires_full_scan
  {
    ScanScope::Full
  } else {
    ScanScope::Incremental
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
  match (existing_relation.filter(|item| item.exists), parent_session_id) {
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

fn refresh_session_titles(conn: &Connection, titles: &HashMap<String, String>) -> rusqlite::Result<()> {
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

fn collect_active_session_files(codex_home: &Path) -> Vec<SessionFile> {
  let sessions_root = codex_home.join("sessions");
  if !sessions_root.exists() {
    return Vec::new();
  }

  let mut files = Vec::new();
  for entry in WalkDir::new(sessions_root).into_iter().filter_map(Result::ok) {
    if let Some(session_file) = session_file_from_path(entry.path().to_path_buf(), "active") {
      files.push(session_file);
    }
  }
  files.sort_by(|left, right| left.path.cmp(&right.path));
  files
}

fn collect_incremental_session_files(
  codex_home: &Path,
  import_state: &HashMap<String, ImportState>,
) -> (Vec<SessionFile>, HashSet<String>) {
  let mut files = collect_active_session_files(codex_home);
  let mut collected_paths = files
    .iter()
    .map(|session_file| session_file.path.to_string_lossy().to_string())
    .collect::<HashSet<_>>();
  let mut active_paths_kept_for_archive_retry = HashSet::new();

  for state in import_state.values() {
    if state.source_bucket == "archived" {
      let Some(session_file) = session_file_from_path(
        PathBuf::from(&state.source_path),
        "archived",
      ) else {
        continue;
      };
      if state.file_size == session_file.file_size && state.file_mtime_ms == session_file.file_mtime_ms {
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

fn parse_session_file(
  session_file: &SessionFile,
  titles: &HashMap<String, String>,
) -> Result<ParsedSession, String> {
  parse_session_file_once(session_file, titles).map_err(|error| match error {
    SessionParseError::Fatal(message) => message,
  })
}

fn parse_session_file_once(
  session_file: &SessionFile,
  titles: &HashMap<String, String>,
) -> Result<ParsedSession, SessionParseError> {
  let file = File::open(&session_file.path)
    .map_err(|error| SessionParseError::Fatal(format!("Failed to open {}: {error}", session_file.path.display())))?;
  let expected_session_id = fallback_session_id_from_filename(&session_file.path);

  let mut session_id = String::new();
  let mut parent_session_id: Option<String> = None;
  let mut started_at: Option<String> = None;
  let mut updated_at: Option<String> = None;
  let mut current_model: Option<String> = None;
  let mut agent_nickname: Option<String> = None;
  let mut agent_role: Option<String> = None;
  let mut explicit_fast_mode: Option<bool> = None;
  let mut latest_plan_type: Option<String> = None;
  let mut snapshots = Vec::new();
  let mut rate_limit_samples = Vec::new();
  let mut seen_models = HashSet::new();
  let mut first_session_meta: Option<SessionMetaCandidate> = None;
  let mut matching_session_meta: Option<SessionMetaCandidate> = None;

  for line_result in BufReader::new(file).lines() {
    let line = line_result.map_err(|error| {
      SessionParseError::Fatal(format!("Failed to read {}: {error}", session_file.path.display()))
    })?;
    if line.contains("\"fast_mode\":true") || line.contains("\"quick_mode\":true") {
      explicit_fast_mode = Some(true);
    }
    if line.contains("\"fast_mode\":false") || line.contains("\"quick_mode\":false") {
      explicit_fast_mode = Some(false);
    }

    let Ok(value) = serde_json::from_str::<Value>(&line) else {
      continue;
    };

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

    match value.get("type").and_then(Value::as_str).unwrap_or_default() {
      "session_meta" => {
        let payload = value.get("payload").unwrap_or(&Value::Null);
        let parent = payload
          .get("forked_from_id")
          .and_then(Value::as_str)
          .map(ToString::to_string)
          .or_else(|| {
            payload
              .get("source")
              .and_then(|source| source.get("subagent"))
              .and_then(|subagent| subagent.get("thread_spawn"))
              .and_then(|thread_spawn| thread_spawn.get("parent_thread_id"))
              .and_then(Value::as_str)
              .map(ToString::to_string)
          });

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

        let model_id = current_model.clone().unwrap_or_else(|| "unknown".to_string());
        seen_models.insert(model_id.clone());

        snapshots.push(UsageSnapshot {
          timestamp: sample_timestamp,
          model_id,
          usage,
          plan_type,
          limit_id,
          limit_name,
          explicit_fast_mode,
        });
      }
      _ => {}
    }
  }

  if let Some(candidate) = matching_session_meta.or(first_session_meta) {
    session_id = candidate.session_id;
    parent_session_id = candidate.parent_session_id.or(parent_session_id);
    agent_nickname = candidate.agent_nickname.or(agent_nickname);
    agent_role = candidate.agent_role.or(agent_role);
  }

  if session_id.is_empty() {
    if let Some(fallback) = fallback_session_id_from_filename(&session_file.path) {
      session_id = fallback;
    }
  }

  if session_id.is_empty() {
    return Err(SessionParseError::Fatal(format!(
      "Could not determine session id for {}",
      session_file.path.display()
    )));
  }

  let title = titles.get(&session_id).cloned();
  let last_model_id = current_model.clone();
  let mut rate_limit_samples = rate_limit_samples;
  for sample in &mut rate_limit_samples {
    sample.source_session_id = Some(session_id.clone());
  }

  Ok(ParsedSession {
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
    explicit_fast_mode,
    latest_plan_type,
    last_model_id: last_model_id.or_else(|| Some("unknown".to_string())),
  })
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
      segment.len() == *expected_len && segment.chars().all(|character| character.is_ascii_hexdigit())
    })
}

fn persist_session(
  conn: &mut Connection,
  session_file: &SessionFile,
  parsed: &ParsedSession,
  catalog: &HashMap<String, crate::models::PricingCatalogEntry>,
) -> rusqlite::Result<()> {
  let tx = conn.transaction()?;
  let created_at = now_utc_string();
  let imported_at = created_at.clone();
  let fast_mode_default = false;

  tx.execute(
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
      updated_at = excluded.updated_at,
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

  tx.execute(
    "DELETE FROM usage_events WHERE session_id = ?1",
    params![parsed.raw_session.session_id],
  )?;
  replace_session_rate_limit_samples(&tx, &parsed.raw_session.session_id, &parsed.rate_limit_samples)?;

  let mut previous_usage: Option<TokenUsage> = None;

  for snapshot in &parsed.snapshots {
    if previous_usage.as_ref() == Some(&snapshot.usage) {
      continue;
    }

    let delta = if let Some(previous) = previous_usage.as_ref() {
      if snapshot.usage.total_tokens <= previous.total_tokens {
        continue;
      }
      diff_usage(previous, &snapshot.usage)
    } else {
      snapshot.usage.clone()
    };

    previous_usage = Some(snapshot.usage.clone());

    if is_zero_delta(&delta) {
      continue;
    }

    let resolved_pricing = resolve_pricing(catalog, &snapshot.model_id);
    let value_usd = calculate_value_usd(&delta, resolved_pricing.as_ref());

    tx.execute(
      "
      INSERT INTO usage_events (
        session_id, timestamp, model_id, input_tokens, cached_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective
      )
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      ",
      params![
        parsed.raw_session.session_id,
        snapshot.timestamp,
        normalize_model_id(&snapshot.model_id),
        delta.input_tokens,
        delta.cached_input_tokens,
        delta.output_tokens,
        delta.reasoning_output_tokens,
        delta.total_tokens,
        value_usd,
        0,
        0,
      ],
    )?;
  }

  tx.execute(
    "
    INSERT INTO import_state (source_path, session_id, source_bucket, file_size, file_mtime_ms, last_imported_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(source_path) DO UPDATE SET
      session_id = excluded.session_id,
      source_bucket = excluded.source_bucket,
      file_size = excluded.file_size,
      file_mtime_ms = excluded.file_mtime_ms,
      last_imported_at = excluded.last_imported_at
    ",
    params![
      session_file.path.to_string_lossy().to_string(),
      parsed.raw_session.session_id,
      session_file.bucket,
      session_file.file_size,
      session_file.file_mtime_ms,
      now_utc_string(),
    ],
  )?;

  tx.execute(
    "
    DELETE FROM import_state
    WHERE session_id = ?1 AND source_path <> ?2
    ",
    params![
      parsed.raw_session.session_id,
      session_file.path.to_string_lossy().to_string(),
    ],
  )?;

  tx.commit()
}

fn diff_usage(previous: &TokenUsage, current: &TokenUsage) -> TokenUsage {
  if current.total_tokens <= previous.total_tokens {
    return TokenUsage::default();
  }

  TokenUsage {
    input_tokens: non_negative_delta(current.input_tokens, previous.input_tokens),
    cached_input_tokens: non_negative_delta(current.cached_input_tokens, previous.cached_input_tokens),
    output_tokens: non_negative_delta(current.output_tokens, previous.output_tokens),
    reasoning_output_tokens: non_negative_delta(current.reasoning_output_tokens, previous.reasoning_output_tokens),
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
  for (bucket, window_key) in [("five_hour", "primary"), ("seven_day", "secondary")] {
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
    let Some(resets_at_seconds) = rate_window.get("resets_at").and_then(Value::as_i64) else {
      continue;
    };
    let Some(resets_at) = unix_seconds_to_rfc3339_local(resets_at_seconds) else {
      continue;
    };
    let Some(window_start) = unix_seconds_to_rfc3339_local(resets_at_seconds - window_duration_mins * 60) else {
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
    SELECT source_path, session_id, source_bucket, file_size, file_mtime_ms
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
    })
  })?;

  let mut result = HashMap::new();
  for row in rows {
    let state = row?;
    result.insert(state.source_path.clone(), state);
  }
  Ok(result)
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

fn mark_data_repair_complete(conn: &Connection, repair_key: &str, completed_at: &str) -> rusqlite::Result<()> {
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

fn load_pending_data_repair_paths(conn: &Connection, repair_key: &str) -> rusqlite::Result<HashSet<String>> {
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

fn clear_pending_data_repair_file(conn: &Connection, repair_key: &str, source_path: &str) -> rusqlite::Result<()> {
  conn.execute(
    "
    DELETE FROM data_repair_pending_files
    WHERE repair_key = ?1 AND source_path = ?2
    ",
    params![repair_key, source_path],
  )?;
  Ok(())
}

fn load_existing_session_relations(conn: &Connection) -> rusqlite::Result<HashMap<String, ExistingSessionRelation>> {
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

fn upsert_root_conversation_links(conn: &Connection, session_ids: &[String]) -> rusqlite::Result<()> {
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

fn mark_missing_sources(
  conn: &Connection,
  present_paths: &HashSet<String>,
  reconcile_existing_absent_sources: bool,
) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare("SELECT session_id, source_path FROM sessions WHERE source_path IS NOT NULL")?;
  let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;

  for row in rows {
    let (session_id, source_path) = row?;
    if !present_paths.contains(&source_path)
      && (reconcile_existing_absent_sources || !Path::new(&source_path).exists())
    {
      conn.execute(
        "
        UPDATE sessions
        SET source_state = 'missing', imported_at = ?1
        WHERE session_id = ?2
        ",
        params![now_utc_string(), session_id],
      )?;
    }
  }
  Ok(())
}

fn mark_missing_active_sources(conn: &Connection, present_paths: &HashSet<String>) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare(
    "
    SELECT session_id, source_path
    FROM sessions
    WHERE source_state = 'active' AND source_bucket = 'active' AND source_path IS NOT NULL
    ",
  )?;
  let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;

  for row in rows {
    let (session_id, source_path) = row?;
    if !present_paths.contains(&source_path) && !Path::new(&source_path).exists() {
      let now = now_utc_string();
      conn.execute(
        "
        UPDATE sessions
        SET source_state = 'missing', imported_at = ?1
        WHERE session_id = ?2
        ",
        params![now, session_id],
      )?;
      conn.execute(
        "DELETE FROM import_state WHERE source_path = ?1",
        params![source_path],
      )?;
    }
  }
  Ok(())
}

fn prune_import_state(
  conn: &Connection,
  present_paths: &HashSet<String>,
  reconcile_existing_absent_sources: bool,
) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare("SELECT source_path FROM import_state")?;
  let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
  for row in rows {
    let source_path = row?;
    if !present_paths.contains(&source_path)
      && (reconcile_existing_absent_sources || !Path::new(&source_path).exists())
    {
      conn.execute(
        "DELETE FROM import_state WHERE source_path = ?1",
        params![source_path],
      )?;
    }
  }
  Ok(())
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
      params![session_id, root_session_id, parents.get(session_id).cloned().flatten(), depth as i64],
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
  value.get("total_tokens").and_then(Value::as_i64).unwrap_or_else(|| {
    read_i64(value, "input_tokens") + read_i64(value, "output_tokens")
  })
}

fn read_percent(value: &Value, key: &str) -> Option<i64> {
  value
    .get(key)
    .and_then(|field| field.as_i64().or_else(|| field.as_f64().map(|number| number.round() as i64)))
}

#[derive(Debug, Clone)]
struct ImportState {
  source_path: String,
  session_id: Option<String>,
  source_bucket: String,
  file_size: i64,
  file_mtime_ms: i64,
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::database::{
    get_last_full_scan_completed, init_db, now_utc_string, open_connection, save_sync_settings,
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

    let standard = (75.0 / 1_000_000.0) * 5.0
      + (25.0 / 1_000_000.0) * 0.5
      + (40.0 / 1_000_000.0) * 30.0;
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
    let (input_tokens, cached_input_tokens, output_tokens, total_tokens, value_usd):
      (i64, i64, i64, i64, f64) = conn
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
    let standard = (75.0 / 1_000_000.0) * 5.0
      + (25.0 / 1_000_000.0) * 0.5
      + (40.0 / 1_000_000.0) * 30.0;
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
    let session_path = sessions_dir.join(format!("rollout-2026-04-03T02-26-46-{child_session_id}.jsonl"));
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
    assert_eq!(session_usage_totals(&conn, child_session_id), (100, 20, 25, 125, 1));
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

    assert_eq!(parsed.raw_session.parent_session_id.as_deref(), Some("root-parent"));
    assert_eq!(parsed.raw_session.agent_nickname.as_deref(), Some("Hume"));
    assert_eq!(parsed.snapshots.len(), 2);
    assert_eq!(parsed.latest_plan_type.as_deref(), Some("pro"));
  }

  #[test]
  fn parser_prefers_file_matching_session_meta_when_fork_file_replays_parent_meta() {
    let directory = tempdir().expect("tempdir");
    let session_path =
      directory
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

    assert_eq!(parsed.raw_session.session_id, "55555555-5555-5555-5555-555555555555");
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
  fn parser_supports_legacy_top_level_id_format() {
    let directory = tempdir().expect("tempdir");
    let session_path =
      directory
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

    assert_eq!(parsed.raw_session.session_id, "0df0be29-d74d-468f-8dda-0630fc6e989e");
    assert_eq!(parsed.raw_session.started_at.as_deref(), Some("2025-09-09T08:29:03.118Z"));
  }

  #[test]
  fn parser_falls_back_to_session_id_from_filename() {
    let directory = tempdir().expect("tempdir");
    let session_path =
      directory
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

    assert_eq!(parsed.raw_session.session_id, "019cfb3d-415c-7623-aab0-22e73abcec2e");
  }

  #[test]
  fn topology_classification_handles_incremental_scan_cases() {
    let existing_child = ExistingSessionRelation {
      exists: true,
      parent_session_id: Some("root-parent".to_string()),
      child_count: 0,
    };
    assert_eq!(
      classify_topology_maintenance(Some(&existing_child), existing_child.child_count, Some("root-parent")),
      TopologyMaintenance::None
    );
    assert_eq!(
      classify_topology_maintenance(Some(&existing_child), existing_child.child_count, Some("other-parent")),
      TopologyMaintenance::RecomputeAll
    );

    let missing_parent_placeholder = ExistingSessionRelation {
      exists: false,
      parent_session_id: None,
      child_count: 2,
    };
    assert_eq!(
      classify_topology_maintenance(Some(&missing_parent_placeholder), missing_parent_placeholder.child_count, None),
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
    write_session_file(&sessions_dir.join("parent.jsonl"), parent_session_id, &[("2026-03-24T00:00:01Z", 120, 20, 30, 150)]);
    write_session_file_with_parent(
      &sessions_dir.join("child.jsonl"),
      child_session_id,
      Some(parent_session_id),
      &[("2026-03-24T00:00:02Z", 80, 10, 15, 95)],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    write_session_file_with_parent(
      &sessions_dir.join("child.jsonl"),
      child_session_id,
      Some(parent_session_id),
      &[
        ("2026-03-24T00:00:02Z", 80, 10, 15, 95),
        ("2026-03-24T00:10:02Z", 160, 20, 25, 185),
      ],
    );
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

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
      Some((parent_session_id.to_string(), Some(parent_session_id.to_string()), 1))
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
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    write_session_file(
      &sessions_dir.join("parent.jsonl"),
      parent_session_id,
      &[("2026-03-24T00:00:01Z", 120, 20, 30, 150)],
    );
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

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
      Some((parent_session_id.to_string(), Some(parent_session_id.to_string()), 1))
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
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_source_state(&conn, session_id), Some("active".to_string()));

    let archived_path = archived_dir.join("sample.jsonl");
    std::fs::rename(&active_path, &archived_path).expect("move to archived");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_source_state(&conn, session_id), Some("archived".to_string()));
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

    let result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 0);
    assert_eq!(session_usage_totals(&conn, active_session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_usage_totals(&conn, archived_session_id), (0, 0, 0, 0, 0));
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

    let result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, existing_session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_usage_totals(&conn, new_session_id), (180, 40, 45, 225, 1));
  }

  #[test]
  fn incremental_scan_discovers_new_old_dated_active_session() {
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

    let result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, existing_session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_usage_totals(&conn, new_session_id), (180, 40, 45, 225, 1));
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

    let result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 0);
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_source_state(&conn, session_id), Some("missing".to_string()));
  }

  #[test]
  fn incremental_scan_retries_pending_repair_path_without_import_state() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let existing_session_id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb";
    write_session_file(
      &sessions_dir.join("existing.jsonl"),
      existing_session_id,
      &[("2026-03-24T00:00:01Z", 100, 20, 25, 125)],
    );
    let pending_path = sessions_dir.join("unparseable.jsonl");
    std::fs::write(&pending_path, "not json\n").expect("write bad session");

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("full scan");

    let recovered_session_id = "88888888-9999-aaaa-bbbb-cccccccccccc";
    write_session_file(
      &pending_path,
      recovered_session_id,
      &[("2026-03-24T00:10:01Z", 180, 40, 45, 225)],
    );

    let result =
      perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, existing_session_id), (100, 20, 25, 125, 1));
    assert_eq!(session_usage_totals(&conn, recovered_session_id), (180, 40, 45, 225, 1));
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
      &[
        ("2026-03-24T00:00:01Z", 150, 30, 40, 190),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::remove_file(&session_path).expect("delete source");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id), (150, 30, 40, 190, 1));
    assert_eq!(session_source_state(&conn, session_id), Some("missing".to_string()));
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
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
      ],
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
    assert_eq!(session_usage_totals(&conn, session_id), (180, 40, 45, 225, 2));
    assert_eq!(session_source_state(&conn, session_id), Some("active".to_string()));
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
    assert_eq!(session_usage_totals(&conn, session_id), (960, 120, 120, 1200, 3));
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
          params![session_id, input_tokens, cached_input_tokens, output_tokens, total_tokens],
        )
        .expect("insert stale usage event");
    }
    assert_eq!(session_usage_totals(&conn, session_id), (1840, 230, 230, 2300, 4));
    drop(conn);

    let result = perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, session_id), (960, 120, 120, 1200, 3));
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
    std::fs::write(sessions_dir.join("unparseable.jsonl"), "not json\n").expect("write bad session");

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
          params![session_id, input_tokens, cached_input_tokens, output_tokens, total_tokens],
        )
        .expect("insert stale usage event");
    }
    drop(conn);

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id), (960, 120, 120, 1200, 3));
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
      Some(sessions_dir.join("unparseable.jsonl").to_string_lossy().as_ref())
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

    let result = perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("rescan");
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
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let conn = open_connection(&db_path).expect("open db after first scan");
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
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
    assert_eq!(session_usage_totals(&conn, session_id), (180, 40, 45, 225, 2));
  }

  #[test]
  fn incomplete_trailing_token_line_is_ignored_until_next_rescan() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let session_id = "55555555-5555-5555-5555-555555555555";
    let session_path = sessions_dir.join("sample.jsonl");
    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
      ],
    );

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    let conn = open_connection(&db_path).expect("open db after first scan");
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
    drop(conn);

    std::fs::write(
      &session_path,
      concat!(
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"55555555-5555-5555-5555-555555555555\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":25,\"reasoning_output_tokens\":0,\"total_tokens\":125}},\"rate_limits\":{\"plan_type\":\"pro\"}}}\n",
        "{\"timestamp\":\"2026-03-24T00:00:10Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":180,\"cached_input_tokens\":40,\"output_tokens\":45,\"reasoning_output_tokens\":0,\"total_tokens\":225}},\"rate_limits\":{\"plan_type\":\"pro\"}}"
      ),
    )
    .expect("write incomplete session");

    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db after incomplete rescan");
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 25, 125, 1));
    drop(conn);

    write_session_file(
      &session_path,
      session_id,
      &[
        ("2026-03-24T00:00:01Z", 100, 20, 25, 125),
        ("2026-03-24T00:00:10Z", 180, 40, 45, 225),
      ],
    );
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("third scan");

    let conn = open_connection(&db_path).expect("open db after third scan");
    assert_eq!(session_usage_totals(&conn, session_id), (180, 40, 45, 225, 2));
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
    assert_eq!(session_usage_totals(&conn, session_id), (180, 40, 45, 225, 2));
  }

  #[test]
  fn scan_keeps_root_and_fork_sessions_distinct_when_child_replays_parent_meta() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "77777777-7777-7777-7777-777777777777";
    let child_session_id = "88888888-8888-8888-8888-888888888888";
    let parent_path =
      sessions_dir.join(format!("rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"));
    let child_path =
      sessions_dir.join(format!("rollout-2026-03-24T00-05-00-{child_session_id}.jsonl"));

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
    assert_eq!(session_usage_totals(&conn, parent_session_id), (260, 60, 65, 325, 3));
    assert_eq!(session_usage_totals(&conn, child_session_id), (140, 20, 25, 165, 2));
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
    let parent_path =
      sessions_dir.join(format!("rollout-2026-03-24T00-00-00-{parent_session_id}.jsonl"));
    let child_path =
      sessions_dir.join(format!("rollout-2026-03-24T00-30-00-{child_session_id}.jsonl"));
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
      child_created_at,
      child_session_id,
      parent_session_id,
      child_created_at,
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
  fn fork_first_snapshot_uses_last_usage_as_baseline() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions_dir = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions_dir).expect("sessions dir");

    let parent_session_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    let child_session_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    let child_path =
      sessions_dir.join(format!("rollout-2026-03-24T01-00-00-{child_session_id}.jsonl"));
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"session_meta\",",
        "\"payload\":{{\"id\":\"{}\",\"forked_from_id\":\"{}\"}}}}\n",
        "{{\"timestamp\":\"2026-03-24T01:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id,
      parent_session_id,
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
    let child_path =
      sessions_dir.join(format!("rollout-2026-03-24T02-00-00-{child_session_id}.jsonl"));
    let mut child_body = format!(
      concat!(
        "{{\"timestamp\":\"2026-03-24T02:00:00Z\",\"type\":\"session_meta\",\"payload\":{{",
        "\"id\":\"{}\",\"source\":{{\"subagent\":{{\"thread_spawn\":{{",
        "\"parent_thread_id\":\"{}\"}}}}}}}}}}\n",
        "{{\"timestamp\":\"2026-03-24T02:00:00Z\",\"type\":\"turn_context\",",
        "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
      ),
      child_session_id,
      parent_session_id,
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

    perform_scan(
      &db_path,
      Some(old_codex_home.to_string_lossy().to_string()),
    )
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
    let (started, completed, full_completed): (Option<String>, Option<String>, Option<String>) = conn
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

    perform_scan(
      &db_path,
      Some(old_codex_home.to_string_lossy().to_string()),
    )
    .expect("scan previous source");

    let conn = open_connection(&db_path).expect("reopen database");
    let (started, completed, full_completed): (Option<String>, Option<String>, Option<String>) = conn
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
      effective_scan_scope(ScanScope::Incremental, false, false, false, true),
      ScanScope::Full
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
    assert_eq!(resolved_source.as_deref(), Some(second_codex_home.to_string_lossy().as_ref()));
    assert_eq!(result.scanned_files, 1);
    assert_eq!(session_usage_totals(&conn, second_session_id).3, 220);
    assert_eq!(session_usage_totals(&conn, first_session_id).3, 110);
    assert_eq!(session_source_state(&conn, first_session_id), Some("missing".to_string()));
    assert_eq!(import_state_session_id(&conn, &first_sessions.join("first.jsonl")), None);
    assert!(first_sessions.join("first.jsonl").is_file());
  }

  #[test]
  fn full_scan_retry_reconciles_previous_source_after_the_first_attempt_fails() {
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
    let error = perform_incremental_scan(&db_path, None).expect_err("first moved-source scan should fail");
    assert!(error.contains("forced source reconciliation failure"));

    let conn = open_connection(&db_path).expect("reopen failed database");
    assert_eq!(get_last_full_scan_completed(&conn).expect("load full freshness"), None);
    conn
      .execute_batch("DROP TRIGGER fail_previous_source_reconciliation;")
      .expect("drop reconciliation trigger");
    drop(conn);

    let retry = perform_incremental_scan(&db_path, None).expect("retry moved default source");

    let conn = open_connection(&db_path).expect("open retried database");
    assert_eq!(retry.scanned_files, 1);
    assert_eq!(session_usage_totals(&conn, second_session_id).3, 220);
    assert_eq!(session_source_state(&conn, first_session_id), Some("missing".to_string()));
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
    assert!(get_last_full_scan_completed(&conn).expect("load initial freshness").is_some());
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
    assert_eq!(pending_rate_limit_path.as_deref(), Some(session_path.to_string_lossy().as_ref()));
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
    assert!(get_last_full_scan_completed(&conn).expect("load repaired freshness").is_some());
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
    let partial = perform_incremental_scan(&db_path, None).expect("scan moved source with skipped archive");
    assert_eq!(partial.scanned_files, 2);

    let conn = open_connection(&db_path).expect("open partial database");
    assert_eq!(get_last_full_scan_completed(&conn).expect("load full freshness"), None);
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
      validate_codex_home(PathBuf::from("~/codex-home"), Some(directory.path())).expect("tilde prefix"),
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
    write_session_file(&active_path, session_id, &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)]);
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
    assert_eq!(session_source_state(&conn, session_id).as_deref(), Some("archived"));
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
    write_session_file(&active_path, session_id, &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)]);
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

    let first_result = perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("import complete prefix from archive");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(first_result.updated_sessions, 1);
    assert_eq!(session_usage_totals(&conn, session_id), (100, 20, 10, 110, 1));
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
    assert_eq!(session_usage_totals(&conn, session_id), (180, 40, 20, 200, 2));
    assert_eq!(session_source_state(&conn, session_id).as_deref(), Some("archived"));
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
    write_session_file(&active_path, session_id, &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)]);
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
    assert_eq!(session_source_state(&conn, session_id).as_deref(), Some("archived"));
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
    std::fs::write(&index_path, format!("{{\"id\":\"{session_id}\",\"thread_name\":\"A\"}}\n"))
      .expect("title A");
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::write(&index_path, format!("{{\"id\":\"{session_id}\",\"thread_name\":\"B\"}}\n"))
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
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan skips bad file");
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
      .execute("DELETE FROM conversation_links WHERE session_id = ?1", params![child])
      .expect("remove link");
    drop(conn);

    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
      .expect("repair scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(conversation_link(&conn, child).expect("child link").0, parent);
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
      conversation_link(&conn, child).expect("child link").1.as_deref(),
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
        timestamp,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        total_tokens
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
    let first_timestamp = snapshots.first().map(|item| item.0).unwrap_or("2026-03-24T00:00:00Z");
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
        timestamp,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        total_tokens
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

  fn conversation_link(conn: &Connection, session_id: &str) -> Option<(String, Option<String>, i64)> {
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
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
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

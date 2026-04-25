use std::path::Path;
use std::time::Duration;

use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};

use crate::models::{LiveRateLimitSnapshot, RateLimitSampleRecord, SubscriptionProfile, SyncSettings};

pub fn now_utc_string() -> String {
  Utc::now().to_rfc3339()
}

pub fn bool_to_i64(value: bool) -> i64 {
  if value { 1 } else { 0 }
}

pub fn i64_to_bool(value: i64) -> bool {
  value != 0
}

pub fn canonical_subscription_currency() -> &'static str {
  "USD"
}

pub fn default_menu_bar_popup_modules() -> Vec<String> {
  vec![
    "api_value".to_string(),
    "scan_freshness".to_string(),
  ]
}

fn is_supported_menu_bar_popup_module(module: &str) -> bool {
  matches!(
    module,
    "api_value"
      | "token_count"
      | "scan_freshness"
      | "live_quota_freshness"
      | "payoff_ratio"
      | "conversation_count"
  )
}

fn default_menu_bar_popup_modules_json() -> String {
  serde_json::to_string(&default_menu_bar_popup_modules()).expect("serialize default popup modules")
}

fn deserialize_menu_bar_popup_modules(value: String) -> Vec<String> {
  serde_json::from_str::<Vec<String>>(&value)
    .ok()
    .map(|modules| {
      modules
        .into_iter()
        .filter(|module| is_supported_menu_bar_popup_module(module))
        .fold(Vec::new(), |mut deduped, module| {
          if !deduped.iter().any(|existing| existing == &module) {
            deduped.push(module);
          }
          deduped
        })
    })
    .unwrap_or_else(default_menu_bar_popup_modules)
}

fn serialize_menu_bar_popup_modules(modules: &[String]) -> String {
  serde_json::to_string(modules).unwrap_or_else(|_| default_menu_bar_popup_modules_json())
}

pub fn open_connection(db_path: &Path) -> rusqlite::Result<Connection> {
  let conn = Connection::open(db_path)?;
  conn.busy_timeout(Duration::from_secs(10))?;
  conn.pragma_update(None, "foreign_keys", "ON")?;
  conn.pragma_update(None, "journal_mode", "WAL")?;
  conn.pragma_update(None, "synchronous", "NORMAL")?;
  Ok(conn)
}

pub fn init_db(conn: &Connection) -> rusqlite::Result<()> {
  conn.execute_batch(
    "
    CREATE TABLE IF NOT EXISTS sessions (
      session_id TEXT PRIMARY KEY,
      root_session_id TEXT NOT NULL,
      parent_session_id TEXT,
      title TEXT,
      source_state TEXT NOT NULL DEFAULT 'missing',
      source_path TEXT,
      source_bucket TEXT,
      started_at TEXT,
      updated_at TEXT,
      agent_nickname TEXT,
      agent_role TEXT,
      explicit_fast_mode INTEGER,
      fast_mode_default INTEGER NOT NULL DEFAULT 0,
      latest_plan_type TEXT,
      last_model_id TEXT,
      contains_subagents INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      imported_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS conversation_links (
      session_id TEXT PRIMARY KEY,
      root_session_id TEXT NOT NULL,
      parent_session_id TEXT,
      depth INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS usage_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      model_id TEXT NOT NULL,
      input_tokens INTEGER NOT NULL,
      cached_input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      reasoning_output_tokens INTEGER NOT NULL,
      total_tokens INTEGER NOT NULL,
      value_usd REAL NOT NULL,
      fast_mode_auto INTEGER NOT NULL,
      fast_mode_effective INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS pricing_catalog (
      model_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      input_price_per_million REAL NOT NULL,
      cached_input_price_per_million REAL NOT NULL,
      output_price_per_million REAL NOT NULL,
      effective_model_id TEXT NOT NULL,
      is_official INTEGER NOT NULL,
      note TEXT,
      source_url TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS subscription_profile (
      singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
      plan_type TEXT NOT NULL,
      currency TEXT NOT NULL,
      monthly_price REAL NOT NULL,
      billing_anchor_day INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS session_overrides (
      session_id TEXT PRIMARY KEY,
      fast_mode_override INTEGER,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sync_settings (
      singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
      codex_home TEXT,
      auto_scan_enabled INTEGER NOT NULL,
      auto_scan_interval_minutes INTEGER NOT NULL,
      live_quota_refresh_interval_seconds INTEGER NOT NULL DEFAULT 60,
      default_fast_mode_for_new_gpt54_sessions INTEGER NOT NULL DEFAULT 1,
      hide_dock_icon_when_menu_bar_visible INTEGER NOT NULL DEFAULT 0,
      show_menu_bar_logo INTEGER NOT NULL DEFAULT 1,
      show_menu_bar_daily_api_value INTEGER NOT NULL DEFAULT 1,
      show_menu_bar_live_quota_percent INTEGER NOT NULL DEFAULT 0,
      menu_bar_live_quota_metric TEXT NOT NULL DEFAULT 'remaining_percent',
      menu_bar_live_quota_bucket TEXT NOT NULL DEFAULT 'five_hour',
      menu_bar_bucket TEXT NOT NULL DEFAULT 'day',
      menu_bar_speed_show_emoji INTEGER NOT NULL DEFAULT 1,
      menu_bar_speed_fast_threshold_percent INTEGER NOT NULL DEFAULT 85,
      menu_bar_speed_slow_threshold_percent INTEGER NOT NULL DEFAULT 115,
      menu_bar_speed_healthy_emoji TEXT NOT NULL DEFAULT '🟢',
      menu_bar_speed_fast_emoji TEXT NOT NULL DEFAULT '🔥',
      menu_bar_speed_slow_emoji TEXT NOT NULL DEFAULT '🐢',
      menu_bar_popup_enabled INTEGER NOT NULL DEFAULT 1,
      menu_bar_popup_modules TEXT NOT NULL DEFAULT '[\"api_value\",\"scan_freshness\"]',
      menu_bar_popup_show_reset_timeline INTEGER NOT NULL DEFAULT 1,
      menu_bar_popup_show_actions INTEGER NOT NULL DEFAULT 1,
      last_scan_started_at TEXT,
      last_scan_completed_at TEXT,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS import_state (
      source_path TEXT PRIMARY KEY,
      session_id TEXT,
      source_bucket TEXT NOT NULL,
      file_size INTEGER NOT NULL,
      file_mtime_ms INTEGER NOT NULL,
      last_imported_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS rate_limit_samples (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_kind TEXT NOT NULL,
      source_session_id TEXT NOT NULL DEFAULT '',
      bucket TEXT NOT NULL,
      sample_timestamp TEXT NOT NULL,
      limit_id TEXT NOT NULL DEFAULT '',
      limit_name TEXT NOT NULL DEFAULT '',
      plan_type TEXT NOT NULL DEFAULT '',
      window_start TEXT NOT NULL,
      resets_at TEXT NOT NULL,
      used_percent INTEGER NOT NULL,
      remaining_percent INTEGER NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_usage_events_session_id ON usage_events(session_id);
    CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp ON usage_events(timestamp);
    CREATE INDEX IF NOT EXISTS idx_sessions_root_session_id ON sessions(root_session_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_parent_session_id ON sessions(parent_session_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_source_state ON sessions(source_state);
    CREATE INDEX IF NOT EXISTS idx_import_state_session_id ON import_state(session_id);
    CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_bucket_window
      ON rate_limit_samples(bucket, window_start, resets_at, sample_timestamp);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_limit_samples_dedupe
      ON rate_limit_samples(
        bucket, sample_timestamp, source_kind, source_session_id, limit_id, window_start, resets_at
      );
    ",
  )?;

  ensure_sync_settings_schema(conn)?;
  ensure_singletons(conn)?;
  Ok(())
}

fn ensure_sync_settings_schema(conn: &Connection) -> rusqlite::Result<()> {
  let mut stmt = conn.prepare("PRAGMA table_info(sync_settings)")?;
  let column_names = stmt
    .query_map([], |row| row.get::<_, String>(1))?
    .collect::<rusqlite::Result<Vec<_>>>()?;

  if !column_names
    .iter()
    .any(|name| name == "show_menu_bar_daily_api_value")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN show_menu_bar_daily_api_value INTEGER NOT NULL DEFAULT 1
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "show_menu_bar_logo")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN show_menu_bar_logo INTEGER NOT NULL DEFAULT 1
      ",
      [],
    )?;
    conn.execute(
      "
      UPDATE sync_settings
      SET show_menu_bar_logo = show_menu_bar_daily_api_value
      WHERE singleton_id = 1
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "show_menu_bar_live_quota_percent")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN show_menu_bar_live_quota_percent INTEGER NOT NULL DEFAULT 0
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_live_quota_metric")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN menu_bar_live_quota_metric TEXT NOT NULL DEFAULT 'remaining_percent'
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_live_quota_bucket")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN menu_bar_live_quota_bucket TEXT NOT NULL DEFAULT 'five_hour'
      ",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_bucket") {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN menu_bar_bucket TEXT NOT NULL DEFAULT 'day'
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "live_quota_refresh_interval_seconds")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN live_quota_refresh_interval_seconds INTEGER NOT NULL DEFAULT 60
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "default_fast_mode_for_new_gpt54_sessions")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN default_fast_mode_for_new_gpt54_sessions INTEGER NOT NULL DEFAULT 1
      ",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "hide_dock_icon_when_menu_bar_visible")
  {
    conn.execute(
      "
      ALTER TABLE sync_settings
      ADD COLUMN hide_dock_icon_when_menu_bar_visible INTEGER NOT NULL DEFAULT 0
      ",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_speed_show_emoji") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_show_emoji INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_speed_fast_threshold_percent")
  {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_fast_threshold_percent INTEGER NOT NULL DEFAULT 85",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_speed_slow_threshold_percent")
  {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_slow_threshold_percent INTEGER NOT NULL DEFAULT 115",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_speed_healthy_emoji")
  {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_healthy_emoji TEXT NOT NULL DEFAULT '🟢'",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_speed_fast_emoji") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_fast_emoji TEXT NOT NULL DEFAULT '🔥'",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_speed_slow_emoji") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_slow_emoji TEXT NOT NULL DEFAULT '🐢'",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_popup_enabled") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_enabled INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_popup_modules") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_modules TEXT NOT NULL DEFAULT '[\"api_value\",\"scan_freshness\"]'",
      [],
    )?;
  }

  if !column_names
    .iter()
    .any(|name| name == "menu_bar_popup_show_reset_timeline")
  {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_show_reset_timeline INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
  }

  if !column_names.iter().any(|name| name == "menu_bar_popup_show_actions") {
    conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_show_actions INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
  }

  Ok(())
}

fn ensure_singletons(conn: &Connection) -> rusqlite::Result<()> {
  let now = now_utc_string();
  conn.execute(
    "
    INSERT INTO subscription_profile (
      singleton_id, plan_type, currency, monthly_price, billing_anchor_day, updated_at
    )
    VALUES (1, 'plus', ?2, 20.0, 1, ?1)
    ON CONFLICT(singleton_id) DO NOTHING
    ",
    params![now, canonical_subscription_currency()],
  )?;

  let now = now_utc_string();
  conn.execute(
    "
    INSERT INTO sync_settings (
      singleton_id, codex_home, auto_scan_enabled, auto_scan_interval_minutes,
      live_quota_refresh_interval_seconds, default_fast_mode_for_new_gpt54_sessions,
      hide_dock_icon_when_menu_bar_visible,
      show_menu_bar_logo,
      show_menu_bar_daily_api_value,
      show_menu_bar_live_quota_percent, menu_bar_live_quota_metric,
      menu_bar_live_quota_bucket, menu_bar_bucket,
      menu_bar_speed_show_emoji, menu_bar_speed_fast_threshold_percent,
      menu_bar_speed_slow_threshold_percent, menu_bar_speed_healthy_emoji,
      menu_bar_speed_fast_emoji, menu_bar_speed_slow_emoji,
      menu_bar_popup_enabled, menu_bar_popup_modules,
      menu_bar_popup_show_reset_timeline, menu_bar_popup_show_actions,
      last_scan_started_at, last_scan_completed_at, updated_at
    )
    VALUES (1, NULL, 1, 5, 60, 1, 0, 1, 1, 0, 'remaining_percent', 'five_hour', 'day', 1, 85, 115, '🟢', '🔥', '🐢', 1, ?2, 1, 1, NULL, NULL, ?1)
    ON CONFLICT(singleton_id) DO NOTHING
    ",
    params![now, default_menu_bar_popup_modules_json()],
  )?;

  Ok(())
}

pub fn get_sync_settings(conn: &Connection) -> rusqlite::Result<SyncSettings> {
  conn.query_row(
    "
    SELECT codex_home, auto_scan_enabled, auto_scan_interval_minutes,
           live_quota_refresh_interval_seconds, default_fast_mode_for_new_gpt54_sessions,
           hide_dock_icon_when_menu_bar_visible,
           show_menu_bar_logo, show_menu_bar_daily_api_value,
           show_menu_bar_live_quota_percent, menu_bar_live_quota_metric,
           menu_bar_live_quota_bucket, menu_bar_bucket,
           menu_bar_speed_show_emoji, menu_bar_speed_fast_threshold_percent,
           menu_bar_speed_slow_threshold_percent, menu_bar_speed_healthy_emoji,
           menu_bar_speed_fast_emoji, menu_bar_speed_slow_emoji,
           menu_bar_popup_enabled, menu_bar_popup_modules,
           menu_bar_popup_show_reset_timeline, menu_bar_popup_show_actions,
           last_scan_started_at, last_scan_completed_at, updated_at
    FROM sync_settings
    WHERE singleton_id = 1
    ",
    [],
    |row| {
      Ok(SyncSettings {
        codex_home: row.get(0)?,
        auto_scan_enabled: i64_to_bool(row.get::<_, i64>(1)?),
        auto_scan_interval_minutes: row.get(2)?,
        live_quota_refresh_interval_seconds: row.get(3)?,
        default_fast_mode_for_new_gpt54_sessions: i64_to_bool(row.get::<_, i64>(4)?),
        hide_dock_icon_when_menu_bar_visible: i64_to_bool(row.get::<_, i64>(5)?),
        show_menu_bar_logo: i64_to_bool(row.get::<_, i64>(6)?),
        show_menu_bar_daily_api_value: i64_to_bool(row.get::<_, i64>(7)?),
        show_menu_bar_live_quota_percent: i64_to_bool(row.get::<_, i64>(8)?),
        menu_bar_live_quota_metric: row.get(9)?,
        menu_bar_live_quota_bucket: row.get(10)?,
        menu_bar_bucket: row.get(11)?,
        menu_bar_speed_show_emoji: i64_to_bool(row.get::<_, i64>(12)?),
        menu_bar_speed_fast_threshold_percent: row.get(13)?,
        menu_bar_speed_slow_threshold_percent: row.get(14)?,
        menu_bar_speed_healthy_emoji: row.get(15)?,
        menu_bar_speed_fast_emoji: row.get(16)?,
        menu_bar_speed_slow_emoji: row.get(17)?,
        menu_bar_popup_enabled: i64_to_bool(row.get::<_, i64>(18)?),
        menu_bar_popup_modules: deserialize_menu_bar_popup_modules(row.get(19)?),
        menu_bar_popup_show_reset_timeline: i64_to_bool(row.get::<_, i64>(20)?),
        menu_bar_popup_show_actions: i64_to_bool(row.get::<_, i64>(21)?),
        last_scan_started_at: row.get(22)?,
        last_scan_completed_at: row.get(23)?,
        updated_at: row.get(24)?,
      })
    },
  )
}

pub fn save_sync_settings(conn: &Connection, settings: &SyncSettings) -> rusqlite::Result<SyncSettings> {
  let updated_at = now_utc_string();
  conn.execute(
    "
    INSERT INTO sync_settings (
      singleton_id, codex_home, auto_scan_enabled, auto_scan_interval_minutes,
      live_quota_refresh_interval_seconds, default_fast_mode_for_new_gpt54_sessions,
      hide_dock_icon_when_menu_bar_visible,
      show_menu_bar_logo,
      show_menu_bar_daily_api_value,
      show_menu_bar_live_quota_percent, menu_bar_live_quota_metric,
      menu_bar_live_quota_bucket, menu_bar_bucket,
      menu_bar_speed_show_emoji, menu_bar_speed_fast_threshold_percent,
      menu_bar_speed_slow_threshold_percent, menu_bar_speed_healthy_emoji,
      menu_bar_speed_fast_emoji, menu_bar_speed_slow_emoji,
      menu_bar_popup_enabled, menu_bar_popup_modules,
      menu_bar_popup_show_reset_timeline, menu_bar_popup_show_actions,
      last_scan_started_at, last_scan_completed_at, updated_at
    )
    VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)
    ON CONFLICT(singleton_id) DO UPDATE SET
      codex_home = excluded.codex_home,
      auto_scan_enabled = excluded.auto_scan_enabled,
      auto_scan_interval_minutes = excluded.auto_scan_interval_minutes,
      live_quota_refresh_interval_seconds = excluded.live_quota_refresh_interval_seconds,
      default_fast_mode_for_new_gpt54_sessions = excluded.default_fast_mode_for_new_gpt54_sessions,
      hide_dock_icon_when_menu_bar_visible = excluded.hide_dock_icon_when_menu_bar_visible,
      show_menu_bar_logo = excluded.show_menu_bar_logo,
      show_menu_bar_daily_api_value = excluded.show_menu_bar_daily_api_value,
      show_menu_bar_live_quota_percent = excluded.show_menu_bar_live_quota_percent,
      menu_bar_live_quota_metric = excluded.menu_bar_live_quota_metric,
      menu_bar_live_quota_bucket = excluded.menu_bar_live_quota_bucket,
      menu_bar_bucket = excluded.menu_bar_bucket,
      menu_bar_speed_show_emoji = excluded.menu_bar_speed_show_emoji,
      menu_bar_speed_fast_threshold_percent = excluded.menu_bar_speed_fast_threshold_percent,
      menu_bar_speed_slow_threshold_percent = excluded.menu_bar_speed_slow_threshold_percent,
      menu_bar_speed_healthy_emoji = excluded.menu_bar_speed_healthy_emoji,
      menu_bar_speed_fast_emoji = excluded.menu_bar_speed_fast_emoji,
      menu_bar_speed_slow_emoji = excluded.menu_bar_speed_slow_emoji,
      menu_bar_popup_enabled = excluded.menu_bar_popup_enabled,
      menu_bar_popup_modules = excluded.menu_bar_popup_modules,
      menu_bar_popup_show_reset_timeline = excluded.menu_bar_popup_show_reset_timeline,
      menu_bar_popup_show_actions = excluded.menu_bar_popup_show_actions,
      last_scan_started_at = excluded.last_scan_started_at,
      last_scan_completed_at = excluded.last_scan_completed_at,
      updated_at = excluded.updated_at
    ",
    params![
      settings.codex_home,
      bool_to_i64(settings.auto_scan_enabled),
      settings.auto_scan_interval_minutes.max(1),
      settings.live_quota_refresh_interval_seconds.clamp(5, 3600),
      bool_to_i64(settings.default_fast_mode_for_new_gpt54_sessions),
      bool_to_i64(settings.hide_dock_icon_when_menu_bar_visible),
      bool_to_i64(settings.show_menu_bar_logo),
      bool_to_i64(settings.show_menu_bar_daily_api_value),
      bool_to_i64(settings.show_menu_bar_live_quota_percent),
      settings.menu_bar_live_quota_metric,
      settings.menu_bar_live_quota_bucket,
      settings.menu_bar_bucket,
      bool_to_i64(settings.menu_bar_speed_show_emoji),
      settings.menu_bar_speed_fast_threshold_percent.clamp(0, 1000),
      settings.menu_bar_speed_slow_threshold_percent.clamp(0, 1000),
      settings.menu_bar_speed_healthy_emoji,
      settings.menu_bar_speed_fast_emoji,
      settings.menu_bar_speed_slow_emoji,
      bool_to_i64(settings.menu_bar_popup_enabled),
      serialize_menu_bar_popup_modules(&settings.menu_bar_popup_modules),
      bool_to_i64(settings.menu_bar_popup_show_reset_timeline),
      bool_to_i64(settings.menu_bar_popup_show_actions),
      settings.last_scan_started_at,
      settings.last_scan_completed_at,
      updated_at,
    ],
  )?;
  get_sync_settings(conn)
}

pub fn replace_session_rate_limit_samples(
  conn: &Connection,
  session_id: &str,
  samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
  conn.execute(
    "
    DELETE FROM rate_limit_samples
    WHERE source_kind = 'session' AND source_session_id = ?1
    ",
    params![session_id],
  )?;
  insert_rate_limit_samples(conn, samples)
}

pub fn insert_rate_limit_samples(conn: &Connection, samples: &[RateLimitSampleRecord]) -> rusqlite::Result<()> {
  let created_at = now_utc_string();
  let mut stmt = conn.prepare(
    "
    INSERT OR IGNORE INTO rate_limit_samples (
      source_kind, source_session_id, bucket, sample_timestamp, limit_id, limit_name, plan_type,
      window_start, resets_at, used_percent, remaining_percent, created_at
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    ",
  )?;

  for sample in samples {
    stmt.execute(params![
      sample.source_kind,
      sample.source_session_id.clone().unwrap_or_default(),
      sample.bucket,
      sample.sample_timestamp,
      sample.limit_id.clone().unwrap_or_default(),
      sample.limit_name.clone().unwrap_or_default(),
      sample.plan_type.clone().unwrap_or_default(),
      sample.window_start,
      sample.resets_at,
      sample.used_percent.clamp(0, 100),
      sample.remaining_percent.clamp(0, 100),
      created_at,
    ])?;
  }

  Ok(())
}

pub fn insert_live_rate_limit_snapshot(conn: &Connection, snapshot: &LiveRateLimitSnapshot) -> rusqlite::Result<()> {
  let mut samples = Vec::new();
  for (bucket, window) in [("five_hour", snapshot.primary.as_ref()), ("seven_day", snapshot.secondary.as_ref())] {
    let Some(window) = window else {
      continue;
    };
    let (Some(window_start), Some(resets_at)) = (window.window_start.clone(), window.resets_at.clone()) else {
      continue;
    };
    samples.push(RateLimitSampleRecord {
      source_kind: "live".to_string(),
      source_session_id: None,
      bucket: bucket.to_string(),
      sample_timestamp: snapshot.fetched_at.clone(),
      limit_id: snapshot.limit_id.clone(),
      limit_name: snapshot.limit_name.clone(),
      plan_type: snapshot.plan_type.clone(),
      window_start,
      resets_at,
      used_percent: window.used_percent,
      remaining_percent: window.remaining_percent,
    });
  }
  insert_rate_limit_samples(conn, &samples)
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn init_db_adds_menu_bar_flag_to_existing_sync_settings() {
    let conn = Connection::open_in_memory().expect("open in-memory database");

    conn
      .execute_batch(
        "
        CREATE TABLE sync_settings (
          singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
          codex_home TEXT,
          auto_scan_enabled INTEGER NOT NULL,
          auto_scan_interval_minutes INTEGER NOT NULL,
          last_scan_started_at TEXT,
          last_scan_completed_at TEXT,
          updated_at TEXT NOT NULL
        );

        INSERT INTO sync_settings (
          singleton_id, codex_home, auto_scan_enabled, auto_scan_interval_minutes,
          last_scan_started_at, last_scan_completed_at, updated_at
        )
        VALUES (1, NULL, 1, 5, NULL, NULL, '2026-03-26T00:00:00Z');
        ",
      )
      .expect("seed legacy schema");

    init_db(&conn).expect("migrate schema");
    let settings = get_sync_settings(&conn).expect("load settings");

    assert!(settings.show_menu_bar_daily_api_value);
    assert!(settings.show_menu_bar_logo);
    assert!(!settings.show_menu_bar_live_quota_percent);
    assert_eq!(settings.menu_bar_live_quota_metric, "remaining_percent");
    assert_eq!(settings.menu_bar_live_quota_bucket, "five_hour");
    assert_eq!(settings.menu_bar_bucket, "day");
    assert_eq!(settings.live_quota_refresh_interval_seconds, 60);
    assert!(settings.menu_bar_speed_show_emoji);
    assert_eq!(settings.menu_bar_speed_fast_threshold_percent, 85);
    assert_eq!(settings.menu_bar_speed_slow_threshold_percent, 115);
    assert_eq!(settings.menu_bar_speed_healthy_emoji, "🟢");
    assert_eq!(settings.menu_bar_speed_fast_emoji, "🔥");
    assert_eq!(settings.menu_bar_speed_slow_emoji, "🐢");
    assert!(settings.menu_bar_popup_enabled);
    assert_eq!(
      settings.menu_bar_popup_modules,
      default_menu_bar_popup_modules()
    );
    assert!(settings.menu_bar_popup_show_reset_timeline);
    assert!(settings.menu_bar_popup_show_actions);
    assert!(!settings.hide_dock_icon_when_menu_bar_visible);
  }

  #[test]
  fn init_db_copies_existing_menu_bar_visibility_into_logo_flag() {
    let conn = Connection::open_in_memory().expect("open in-memory database");

    conn
      .execute_batch(
        "
        CREATE TABLE sync_settings (
          singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
          codex_home TEXT,
          auto_scan_enabled INTEGER NOT NULL,
          auto_scan_interval_minutes INTEGER NOT NULL,
          show_menu_bar_daily_api_value INTEGER NOT NULL DEFAULT 1,
          last_scan_started_at TEXT,
          last_scan_completed_at TEXT,
          updated_at TEXT NOT NULL
        );

        INSERT INTO sync_settings (
          singleton_id, codex_home, auto_scan_enabled, auto_scan_interval_minutes,
          show_menu_bar_daily_api_value, last_scan_started_at, last_scan_completed_at, updated_at
        )
        VALUES (1, NULL, 1, 5, 0, NULL, NULL, '2026-03-26T00:00:00Z');
        ",
      )
      .expect("seed pre-logo schema");

    init_db(&conn).expect("migrate schema");
    let settings = get_sync_settings(&conn).expect("load settings");

    assert!(!settings.show_menu_bar_daily_api_value);
    assert!(!settings.show_menu_bar_logo);
    assert!(!settings.hide_dock_icon_when_menu_bar_visible);
  }

  #[test]
  fn save_sync_settings_round_trips_dock_visibility_preference() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init database");

    save_sync_settings(
      &conn,
      &SyncSettings {
        hide_dock_icon_when_menu_bar_visible: true,
        ..SyncSettings::default()
      },
    )
    .expect("save settings");

    let settings = get_sync_settings(&conn).expect("load settings");

    assert!(settings.hide_dock_icon_when_menu_bar_visible);
  }

  #[test]
  fn subscription_profile_is_normalized_to_usd() {
    let conn = Connection::open_in_memory().expect("open in-memory database");

    init_db(&conn).expect("init database");
    save_subscription_profile(
      &conn,
      &SubscriptionProfile {
        plan_type: "pro".to_string(),
        currency: "eur".to_string(),
        monthly_price: 42.0,
        billing_anchor_day: 9,
        updated_at: "2026-04-07T00:00:00Z".to_string(),
      },
    )
    .expect("save profile");

    let profile = get_subscription_profile(&conn).expect("load profile");

    assert_eq!(profile.currency, "USD");
    assert_eq!(profile.monthly_price, 42.0);
    assert_eq!(profile.billing_anchor_day, 9);
  }
}

pub fn set_last_scan_started(conn: &Connection, timestamp: &str) -> rusqlite::Result<()> {
  conn.execute(
    "
    UPDATE sync_settings
    SET last_scan_started_at = ?1, updated_at = ?1
    WHERE singleton_id = 1
    ",
    params![timestamp],
  )?;
  Ok(())
}

pub fn set_last_scan_completed(conn: &Connection, timestamp: &str) -> rusqlite::Result<()> {
  conn.execute(
    "
    UPDATE sync_settings
    SET last_scan_completed_at = ?1, updated_at = ?1
    WHERE singleton_id = 1
    ",
    params![timestamp],
  )?;
  Ok(())
}

pub fn get_subscription_profile(conn: &Connection) -> rusqlite::Result<SubscriptionProfile> {
  conn.query_row(
    "
    SELECT plan_type, currency, monthly_price, billing_anchor_day, updated_at
    FROM subscription_profile
    WHERE singleton_id = 1
    ",
    [],
    |row| {
      Ok(SubscriptionProfile {
        plan_type: row.get(0)?,
        currency: {
          let _: String = row.get(1)?;
          canonical_subscription_currency().to_string()
        },
        monthly_price: row.get(2)?,
        billing_anchor_day: row.get(3)?,
        updated_at: row.get(4)?,
      })
    },
  )
}

pub fn save_subscription_profile(
  conn: &Connection,
  profile: &SubscriptionProfile,
) -> rusqlite::Result<SubscriptionProfile> {
  let updated_at = now_utc_string();
  conn.execute(
    "
    INSERT INTO subscription_profile (
      singleton_id, plan_type, currency, monthly_price, billing_anchor_day, updated_at
    )
    VALUES (1, ?1, ?2, ?3, ?4, ?5)
    ON CONFLICT(singleton_id) DO UPDATE SET
      plan_type = excluded.plan_type,
      currency = excluded.currency,
      monthly_price = excluded.monthly_price,
      billing_anchor_day = excluded.billing_anchor_day,
      updated_at = excluded.updated_at
    ",
    params![
      profile.plan_type,
      canonical_subscription_currency(),
      profile.monthly_price.max(0.0),
      profile.billing_anchor_day.clamp(1, 28),
      updated_at,
    ],
  )?;
  get_subscription_profile(conn)
}

pub fn get_fast_mode_override(conn: &Connection, session_id: &str) -> rusqlite::Result<Option<bool>> {
  conn
    .query_row(
      "
      SELECT fast_mode_override
      FROM session_overrides
      WHERE session_id = ?1
      ",
      params![session_id],
      |row| {
        let value: Option<i64> = row.get(0)?;
        Ok(value.map(i64_to_bool))
      },
    )
    .optional()
    .map(|value| value.flatten())
}

pub fn save_fast_mode_override(
  conn: &Connection,
  session_id: &str,
  override_value: Option<bool>,
) -> rusqlite::Result<()> {
  let updated_at = now_utc_string();
  conn.execute(
    "
    INSERT INTO session_overrides (session_id, fast_mode_override, updated_at)
    VALUES (?1, ?2, ?3)
    ON CONFLICT(session_id) DO UPDATE SET
      fast_mode_override = excluded.fast_mode_override,
      updated_at = excluded.updated_at
    ",
    params![session_id, override_value.map(bool_to_i64), updated_at],
  )?;
  Ok(())
}

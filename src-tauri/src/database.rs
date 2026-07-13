use std::path::Path;
use std::time::Duration;

use chrono::Utc;
use rusqlite::{params, Connection};

#[allow(dead_code)]
mod epoch_backfill;
mod rate_limit_samples;
mod subscriptions;
mod sync_settings;
mod usage_events;

#[allow(unused_imports)]
pub use epoch_backfill::{
    backfill_epoch_batch, backfill_epoch_batch_cancellable, epoch_backfill_pending,
    parse_epoch_millis, EpochBackfillProgress,
};
#[allow(unused_imports)]
pub use rate_limit_samples::{
    append_session_rate_limit_samples, insert_live_rate_limit_snapshot, load_latest_rate_limits,
    replace_session_rate_limit_samples, RateLimitWriteStats,
};
pub use subscriptions::{
    canonical_subscription_currency, get_subscription_profile, save_subscription_profile,
};
pub use sync_settings::{
    get_last_full_scan_completed, get_sync_settings, save_sync_settings,
    set_scan_completed_for_source,
};
pub use usage_events::{
    append_session_usage_events, replace_session_usage_events, NewUsageEvent,
};
pub(crate) use sync_settings::{
    preview_scan_freshness_for_source, set_last_scan_started_for_source_in_transaction,
};
#[cfg(test)]
pub use sync_settings::{set_last_full_scan_completed, set_last_scan_started_for_source};

pub fn now_utc_string() -> String {
    Utc::now().to_rfc3339()
}

pub fn bool_to_i64(value: bool) -> i64 {
    if value {
        1
    } else {
        0
    }
}

pub fn i64_to_bool(value: i64) -> bool {
    value != 0
}

pub fn open_connection(db_path: &Path) -> rusqlite::Result<Connection> {
    open_connection_with_busy_timeout(db_path, Duration::from_secs(10))
}

pub(crate) fn open_epoch_maintenance_connection(
    db_path: &Path,
) -> rusqlite::Result<Connection> {
    open_connection_with_busy_timeout(db_path, Duration::from_millis(200))
}

fn open_connection_with_busy_timeout(
    db_path: &Path,
    busy_timeout: Duration,
) -> rusqlite::Result<Connection> {
    let conn = Connection::open(db_path)?;
    conn.busy_timeout(busy_timeout)?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}

pub fn init_db(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(include_str!("../sql/schema.sql"))?;
    ensure_import_state_schema(conn)?;
    epoch_backfill::ensure_epoch_schema(conn)?;
    sync_settings::ensure_sync_settings_schema(conn)?;
    ensure_singletons(conn)?;
    conn.execute_batch(include_str!("../sql/indexes.sql"))?;
    Ok(())
}

fn ensure_import_state_schema(conn: &Connection) -> rusqlite::Result<()> {
    let mut statement = conn.prepare("PRAGMA table_info(import_state)")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !columns.iter().any(|column| column == "parser_checkpoint") {
        conn.execute("ALTER TABLE import_state ADD COLUMN parser_checkpoint TEXT", [])?;
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
      singleton_id, sync_settings_schema_version,
      codex_home, auto_scan_enabled, auto_scan_interval_minutes,
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
      last_scan_started_at, last_scan_completed_at, last_full_scan_completed_at, updated_at
    )
    VALUES (1, 2, NULL, 1, 5, 300, 0, 0, 1, 1, 0, 'remaining_percent', 'five_hour', 'day', 1, 85, 115, '🟢', '🔥', '🐢', 1, ?2, 1, 1, NULL, NULL, NULL, ?1)
    ON CONFLICT(singleton_id) DO NOTHING
    ",
        params![now, sync_settings::default_menu_bar_popup_modules_json()],
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{SubscriptionProfile, SyncSettings};

    #[test]
    fn epoch_maintenance_connection_uses_short_busy_timeout_and_normal_pragmas() {
        let directory = tempfile::tempdir().expect("create maintenance connection directory");
        let path = directory.path().join("maintenance.sqlite3");

        let conn = open_epoch_maintenance_connection(&path)
            .expect("open epoch maintenance connection");

        let busy_timeout: i64 = conn
            .query_row("PRAGMA busy_timeout", [], |row| row.get(0))
            .expect("read busy timeout");
        let foreign_keys: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
            .expect("read foreign key mode");
        let journal_mode: String = conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("read journal mode");
        let synchronous: i64 = conn
            .query_row("PRAGMA synchronous", [], |row| row.get(0))
            .expect("read synchronous mode");
        assert_eq!(busy_timeout, 200);
        assert_eq!(foreign_keys, 1);
        assert_eq!(journal_mode.to_ascii_lowercase(), "wal");
        assert_eq!(synchronous, 1, "SQLite NORMAL synchronous mode");
    }

    #[test]
    fn init_db_adds_parser_checkpoint_to_legacy_import_state() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        conn.execute_batch(
            "
            CREATE TABLE import_state (
              source_path TEXT PRIMARY KEY,
              session_id TEXT,
              source_bucket TEXT NOT NULL,
              file_size INTEGER NOT NULL,
              file_mtime_ms INTEGER NOT NULL,
              last_imported_at TEXT NOT NULL
            );
            ",
        )
        .expect("seed legacy import state");

        init_db(&conn).expect("migrate database");
        let columns = conn
            .prepare("PRAGMA table_info(import_state)")
            .expect("prepare column query")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("collect columns");
        assert!(columns.iter().any(|column| column == "parser_checkpoint"));
    }

    #[test]
    fn init_db_adds_scan_commit_revision_to_existing_sync_settings() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        conn.execute_batch(
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
            VALUES (1, NULL, 1, 5, NULL, NULL, '2026-07-10T00:00:00Z');
            ",
        )
        .expect("seed legacy schema");

        init_db(&conn).expect("migrate schema");
        let revision: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load scan commit revision");

        assert_eq!(revision, 0);
    }

    #[test]
    fn init_db_adds_menu_bar_flag_to_existing_sync_settings() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        conn.execute_batch(
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
        assert_eq!(settings.live_quota_refresh_interval_seconds, 300);
        assert!(settings.menu_bar_speed_show_emoji);
        assert_eq!(settings.menu_bar_speed_fast_threshold_percent, 85);
        assert_eq!(settings.menu_bar_speed_slow_threshold_percent, 115);
        assert_eq!(settings.menu_bar_speed_healthy_emoji, "🟢");
        assert_eq!(settings.menu_bar_speed_fast_emoji, "🔥");
        assert_eq!(settings.menu_bar_speed_slow_emoji, "🐢");
        assert!(settings.menu_bar_popup_enabled);
        assert_eq!(
            settings.menu_bar_popup_modules,
            sync_settings::default_menu_bar_popup_modules()
        );
        assert!(settings.menu_bar_popup_show_reset_timeline);
        assert!(settings.menu_bar_popup_show_actions);
        assert!(get_last_full_scan_completed(&conn)
            .expect("load last full scan")
            .is_none());
        assert!(!settings.hide_dock_icon_when_menu_bar_visible);
    }

    #[test]
    fn init_db_adds_resolved_scan_source_to_existing_sync_settings() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        conn.execute_batch(
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
        VALUES (
          1, NULL, 1, 5,
          '2026-07-09T23:00:00Z', '2026-07-09T23:01:00Z',
          '2026-07-10T00:00:00Z'
        );
        ",
        )
        .expect("seed legacy schema");

        init_db(&conn).expect("migrate schema");

        let (resolved_source, started, completed, full_completed): (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "
                SELECT last_scan_codex_home, last_scan_started_at,
                       last_scan_completed_at, last_full_scan_completed_at
                FROM sync_settings
                WHERE singleton_id = 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load resolved scan source");

        assert_eq!(resolved_source, None);
        assert_eq!(started, None);
        assert_eq!(completed, None);
        assert_eq!(full_completed, None);
    }

    #[test]
    fn sync_settings_tracks_last_full_scan_completion() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        assert!(get_last_full_scan_completed(&conn)
            .expect("load initial value")
            .is_none());

        set_last_full_scan_completed(&conn, "2026-03-27T00:00:00Z")
            .expect("set full scan timestamp");

        assert_eq!(
            get_last_full_scan_completed(&conn).expect("load saved value"),
            Some("2026-03-27T00:00:00Z".to_string())
        );
    }

    #[test]
    fn scan_freshness_tracks_resolved_source_when_default_selector_moves() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        let first = set_last_scan_started_for_source(
            &conn,
            "2026-07-10T00:00:00Z",
            None,
            "/tmp/codex-home-a",
        )
        .expect("start first scan");
        assert!(first.recorded);
        assert!(first.source_changed);

        assert!(set_scan_completed_for_source(
            &conn,
            "2026-07-10T00:01:00Z",
            None,
            "/tmp/codex-home-a",
            true,
            false,
        )
        .expect("complete first scan"));

        let second = set_last_scan_started_for_source(
            &conn,
            "2026-07-10T01:00:00Z",
            None,
            "/tmp/codex-home-b",
        )
        .expect("start second scan");
        assert!(second.recorded);
        assert!(second.source_changed);
        assert!(second.full_scan_required);

        let (resolved_source, started, completed, full_completed): (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "
                SELECT last_scan_codex_home, last_scan_started_at,
                       last_scan_completed_at, last_full_scan_completed_at
                FROM sync_settings
                WHERE singleton_id = 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load moved scan source");

        assert_eq!(resolved_source.as_deref(), Some("/tmp/codex-home-b"));
        assert_eq!(started.as_deref(), Some("2026-07-10T01:00:00Z"));
        assert_eq!(completed, None);
        assert_eq!(full_completed, None);

        let retry = set_last_scan_started_for_source(
            &conn,
            "2026-07-10T01:00:30Z",
            None,
            "/tmp/codex-home-b",
        )
        .expect("retry second scan");
        assert!(retry.recorded);
        assert!(!retry.source_changed);
        assert!(retry.full_scan_required);

        assert!(!set_scan_completed_for_source(
            &conn,
            "2026-07-10T01:01:00Z",
            None,
            "/tmp/codex-home-a",
            true,
            false,
        )
        .expect("reject completion from first source"));
        assert!(set_scan_completed_for_source(
            &conn,
            "2026-07-10T01:02:00Z",
            None,
            "/tmp/codex-home-b",
            true,
            false,
        )
        .expect("complete second scan"));

        let next = set_last_scan_started_for_source(
            &conn,
            "2026-07-10T02:00:00Z",
            None,
            "/tmp/codex-home-b",
        )
        .expect("start next incremental scan");
        assert!(next.recorded);
        assert!(!next.source_changed);
        assert!(!next.full_scan_required);
    }

    #[test]
    fn init_db_copies_existing_menu_bar_visibility_into_logo_flag() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        conn.execute_batch(
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
    fn save_sync_settings_honors_long_background_refresh_intervals() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        save_sync_settings(
            &conn,
            &SyncSettings {
                auto_scan_interval_minutes: 180,
                ..SyncSettings::default()
            },
        )
        .expect("save settings");

        let settings = get_sync_settings(&conn).expect("load settings");

        assert_eq!(settings.auto_scan_interval_minutes, 180);
        assert_eq!(settings.live_quota_refresh_interval_seconds, 10800);
    }

    #[test]
    fn settings_save_does_not_overwrite_newer_scan_freshness() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        let mut stale_settings = save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-a".to_string()),
                ..SyncSettings::default()
            },
        )
        .expect("save initial settings");

        set_last_scan_started_for_source(
            &conn,
            "2026-07-11T01:00:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/codex-home-a",
        )
        .expect("record newer scan start");
        assert!(set_scan_completed_for_source(
            &conn,
            "2026-07-11T01:01:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/codex-home-a",
            true,
            false,
        )
        .expect("record newer scan completion"));

        stale_settings.auto_scan_interval_minutes = 17;
        save_sync_settings(&conn, &stale_settings).expect("save stale config snapshot");

        let saved = get_sync_settings(&conn).expect("reload settings");
        assert_eq!(
            saved.last_scan_started_at.as_deref(),
            Some("2026-07-11T01:00:00Z")
        );
        assert_eq!(
            saved.last_scan_completed_at.as_deref(),
            Some("2026-07-11T01:01:00Z")
        );
    }

    #[test]
    fn home_change_clears_all_scan_freshness_in_one_transaction() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        let settings = save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-a".to_string()),
                ..SyncSettings::default()
            },
        )
        .expect("save first Codex home");
        set_last_scan_started_for_source(
            &conn,
            "2026-07-11T02:00:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/resolved-home-a",
        )
        .expect("record scan start");
        assert!(set_scan_completed_for_source(
            &conn,
            "2026-07-11T02:01:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/resolved-home-a",
            true,
            false,
        )
        .expect("record full scan completion"));
        let revision_before: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load revision before home change");

        save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-b".to_string()),
                ..settings
            },
        )
        .expect("change Codex home");

        let (started, completed, full_completed, resolved_home, revision): (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
        ) = conn
            .query_row(
                "
                SELECT last_scan_started_at, last_scan_completed_at,
                       last_full_scan_completed_at, last_scan_codex_home,
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
                    ))
                },
            )
            .expect("load freshness after home change");

        assert_eq!(
            (started, completed, full_completed, resolved_home),
            (None, None, None, None)
        );
        assert_eq!(revision, revision_before + 1);
    }

    #[test]
    fn codex_home_aba_advances_scan_commit_revision() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        let initial_revision: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load initial revision");
        let settings_a = save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-a".to_string()),
                ..SyncSettings::default()
            },
        )
        .expect("save home A");
        let revision_a: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load home A revision");
        let settings_b = save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-b".to_string()),
                ..settings_a
            },
        )
        .expect("save home B");
        let revision_b: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load home B revision");
        save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-a".to_string()),
                ..settings_b
            },
        )
        .expect("return to home A");
        let final_revision: i64 = conn
            .query_row(
                "SELECT scan_commit_revision FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("load final revision");

        assert_eq!(revision_a, initial_revision + 1);
        assert_eq!(revision_b, revision_a + 1);
        assert_eq!(final_revision, revision_b + 1);
    }

    #[test]
    fn unchanged_home_config_save_preserves_revision_and_hidden_freshness_columns() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");

        let mut settings = save_sync_settings(
            &conn,
            &SyncSettings {
                codex_home: Some("/tmp/codex-home-a".to_string()),
                ..SyncSettings::default()
            },
        )
        .expect("save Codex home");
        set_last_scan_started_for_source(
            &conn,
            "2026-07-11T03:00:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/resolved-home-a",
        )
        .expect("record scan start");
        assert!(set_scan_completed_for_source(
            &conn,
            "2026-07-11T03:01:00Z",
            Some("/tmp/codex-home-a"),
            "/tmp/resolved-home-a",
            true,
            false,
        )
        .expect("record full scan completion"));
        conn.execute(
            "UPDATE sync_settings SET scan_commit_revision = 41 WHERE singleton_id = 1",
            [],
        )
        .expect("seed revision");
        let before: (i64, Option<String>, Option<String>) = conn
            .query_row(
                "
                SELECT scan_commit_revision, last_scan_codex_home,
                       last_full_scan_completed_at
                FROM sync_settings
                WHERE singleton_id = 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load hidden freshness before save");

        settings.auto_scan_interval_minutes = 19;
        save_sync_settings(&conn, &settings).expect("save unchanged-home config");

        let after: (i64, Option<String>, Option<String>) = conn
            .query_row(
                "
                SELECT scan_commit_revision, last_scan_codex_home,
                       last_full_scan_completed_at
                FROM sync_settings
                WHERE singleton_id = 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load hidden freshness after save");
        assert_eq!(after, before);
    }

    #[test]
    fn settings_insert_ignores_payload_freshness() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("init database");
        conn.execute("DELETE FROM sync_settings WHERE singleton_id = 1", [])
            .expect("remove singleton to exercise insert path");

        save_sync_settings(
            &conn,
            &SyncSettings {
                last_scan_started_at: Some("stale-start".to_string()),
                last_scan_completed_at: Some("stale-complete".to_string()),
                ..SyncSettings::default()
            },
        )
        .expect("insert settings singleton");

        let freshness: (Option<String>, Option<String>) = conn
            .query_row(
                "
                SELECT last_scan_started_at, last_scan_completed_at
                FROM sync_settings
                WHERE singleton_id = 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load inserted freshness");
        assert_eq!(freshness, (None, None));
    }

    #[test]
    fn init_db_migrates_old_default_refresh_and_disables_legacy_fast_mode_once() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        init_db(&conn).expect("init database");
        conn.execute(
            "
        UPDATE sync_settings
        SET
          sync_settings_schema_version = 1,
          live_quota_refresh_interval_seconds = 60,
          default_fast_mode_for_new_gpt54_sessions = 1
        WHERE singleton_id = 1
        ",
            [],
        )
        .expect("seed old defaults");

        init_db(&conn).expect("migrate defaults");
        let settings = get_sync_settings(&conn).expect("load settings");
        let schema_version = conn
            .query_row(
                "SELECT sync_settings_schema_version FROM sync_settings WHERE singleton_id = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("load schema version");
        let legacy_fast_mode_default = conn
      .query_row(
        "SELECT default_fast_mode_for_new_gpt54_sessions FROM sync_settings WHERE singleton_id = 1",
        [],
        |row| row.get::<_, i64>(0),
      )
      .expect("load legacy fast mode default");

        assert_eq!(settings.live_quota_refresh_interval_seconds, 300);
        assert_eq!(legacy_fast_mode_default, 0);
        assert_eq!(schema_version, 2);

        save_sync_settings(
            &conn,
            &SyncSettings {
                auto_scan_interval_minutes: 10,
                live_quota_refresh_interval_seconds: 60,
                ..SyncSettings::default()
            },
        )
        .expect("save user preferences");

        init_db(&conn).expect("run init again");
        let settings = get_sync_settings(&conn).expect("reload settings");

        assert_eq!(settings.auto_scan_interval_minutes, 10);
        assert_eq!(settings.live_quota_refresh_interval_seconds, 600);
    }

    fn assert_release_upgrade_preserves_user_data(legacy_schema: &str) {
        let conn = Connection::open_in_memory().expect("open legacy release database");
        conn.execute_batch(legacy_schema)
            .expect("install historical release schema");
        conn.execute_batch(
            "
            INSERT INTO sessions (
              session_id, root_session_id, title, source_state,
              created_at, imported_at
            ) VALUES (
              'legacy-session', 'legacy-session', 'Legacy conversation', 'active',
              '2026-04-01T00:00:00Z', '2026-04-01T00:01:00Z'
            );
            INSERT INTO conversation_links (
              session_id, root_session_id, parent_session_id, depth
            ) VALUES ('legacy-session', 'legacy-session', NULL, 0);
            INSERT INTO usage_events (
              session_id, timestamp, model_id,
              input_tokens, cached_input_tokens, output_tokens,
              reasoning_output_tokens, total_tokens, value_usd,
              fast_mode_auto, fast_mode_effective
            ) VALUES (
              'legacy-session', '2026-04-01T00:02:00Z', 'gpt-5.4',
              100, 20, 25, 0, 125, 0.42, 0, 0
            );
            INSERT INTO pricing_catalog (
              model_id, display_name,
              input_price_per_million, cached_input_price_per_million,
              output_price_per_million, effective_model_id,
              is_official, note, source_url, updated_at
            ) VALUES (
              'legacy-model', 'Legacy model', 1.0, 0.1, 2.0,
              'legacy-model', 1, 'release fixture',
              'https://example.invalid/pricing', '2026-04-01T00:00:00Z'
            );
            INSERT INTO subscription_profile (
              singleton_id, plan_type, currency,
              monthly_price, billing_anchor_day, updated_at
            ) VALUES (1, 'pro', 'USD', 42.0, 9, '2026-04-01T00:00:00Z');
            INSERT INTO session_overrides (
              session_id, fast_mode_override, updated_at
            ) VALUES ('legacy-session', 1, '2026-04-01T00:00:00Z');
            INSERT INTO sync_settings (
              singleton_id, codex_home, auto_scan_enabled,
              auto_scan_interval_minutes, last_scan_started_at,
              last_scan_completed_at, updated_at
            ) VALUES (
              1, '/legacy/codex-home', 1, 17,
              '2026-04-01T00:03:00Z', '2026-04-01T00:04:00Z',
              '2026-04-01T00:05:00Z'
            );
            INSERT INTO import_state (
              source_path, session_id, source_bucket,
              file_size, file_mtime_ms, last_imported_at
            ) VALUES (
              '/legacy/session.jsonl', 'legacy-session', 'active',
              512, 1775000000000, '2026-04-01T00:05:00Z'
            );
            INSERT INTO rate_limit_samples (
              source_kind, source_session_id, bucket,
              sample_timestamp, limit_id, limit_name, plan_type,
              window_start, resets_at, used_percent,
              remaining_percent, created_at
            ) VALUES (
              'session', 'legacy-session', 'five_hour',
              '2026-04-01T00:06:00Z', 'legacy-limit', 'Legacy limit', 'pro',
              '2026-04-01T00:00:00Z', '2026-04-01T05:00:00Z',
              25, 75, '2026-04-01T00:06:00Z'
            );
            ",
        )
        .expect("seed historical user data");

        init_db(&conn).expect("upgrade historical release database");
        let progress = backfill_epoch_batch(&conn, 1_000)
            .expect("backfill historical epoch values");
        assert!(progress.complete);
        init_db(&conn).expect("repeat upgrade idempotently");

        let session: (String, String) = conn
            .query_row(
                "SELECT title, source_state FROM sessions WHERE session_id = 'legacy-session'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load preserved session");
        assert_eq!(session, ("Legacy conversation".to_string(), "active".to_string()));

        let usage: (i64, i64, Option<i64>) = conn
            .query_row(
                "
                SELECT COUNT(*), total_tokens, timestamp_ms
                FROM usage_events
                WHERE session_id = 'legacy-session'
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load preserved usage");
        assert_eq!(usage.0, 1);
        assert_eq!(usage.1, 125);
        assert!(usage.2.is_some());

        let quota: (i64, i64, i64, Option<i64>) = conn
            .query_row(
                "
                SELECT COUNT(*), used_percent, remaining_percent, sample_timestamp_ms
                FROM rate_limit_samples
                WHERE source_session_id = 'legacy-session'
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load preserved quota");
        assert_eq!((quota.0, quota.1, quota.2), (1, 25, 75));
        assert!(quota.3.is_some());

        let profile = get_subscription_profile(&conn).expect("load preserved subscription");
        assert_eq!(profile.plan_type, "pro");
        assert_eq!(profile.monthly_price, 42.0);
        assert_eq!(profile.billing_anchor_day, 9);

        let settings = get_sync_settings(&conn).expect("load preserved settings");
        assert_eq!(settings.codex_home.as_deref(), Some("/legacy/codex-home"));
        assert_eq!(settings.auto_scan_interval_minutes, 17);

        let import_state: (i64, Option<String>) = conn
            .query_row(
                "
                SELECT file_size, parser_checkpoint
                FROM import_state
                WHERE source_path = '/legacy/session.jsonl'
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load preserved import state");
        assert_eq!(import_state, (512, None));

        let repair_tables: i64 = conn
            .query_row(
                "
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table'
                  AND name IN (
                    'data_repair_progress',
                    'data_repair_quarantine',
                    'latest_rate_limits'
                  )
                ",
                [],
                |row| row.get(0),
            )
            .expect("load upgraded tables");
        assert_eq!(repair_tables, 3);

        let integrity: String = conn
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .expect("check upgraded database integrity");
        assert_eq!(integrity, "ok");
    }

    #[test]
    fn upgrades_v1_1_1_database_without_losing_user_data() {
        assert_release_upgrade_preserves_user_data(include_str!(
            "../tests/fixtures/v1.1.1-schema.sql"
        ));
    }

    #[test]
    fn upgrades_v1_1_2_database_without_losing_user_data() {
        assert_release_upgrade_preserves_user_data(include_str!(
            "../tests/fixtures/v1.1.2-schema.sql"
        ));
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

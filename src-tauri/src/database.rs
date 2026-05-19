use std::path::Path;
use std::time::Duration;

use chrono::Utc;
use rusqlite::{params, Connection};

mod rate_limit_samples;
mod subscriptions;
mod sync_settings;

pub use rate_limit_samples::{insert_live_rate_limit_snapshot, replace_session_rate_limit_samples};
pub use subscriptions::{
    canonical_subscription_currency, get_subscription_profile, save_subscription_profile,
};
pub use sync_settings::{
    get_sync_settings, save_sync_settings, set_last_scan_completed, set_last_scan_started,
};

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
    let conn = Connection::open(db_path)?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}

pub fn init_db(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(include_str!("../sql/schema.sql"))?;
    sync_settings::ensure_sync_settings_schema(conn)?;
    ensure_singletons(conn)?;
    conn.execute_batch(include_str!("../sql/indexes.sql"))?;
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
      last_scan_started_at, last_scan_completed_at, updated_at
    )
    VALUES (1, 2, NULL, 1, 5, 300, 0, 0, 1, 1, 0, 'remaining_percent', 'five_hour', 'day', 1, 85, 115, '🟢', '🔥', '🐢', 1, ?2, 1, 1, NULL, NULL, ?1)
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
        assert!(!settings.hide_dock_icon_when_menu_bar_visible);
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
                live_quota_refresh_interval_seconds: 600,
                ..SyncSettings::default()
            },
        )
        .expect("save user preferences");

        init_db(&conn).expect("run init again");
        let settings = get_sync_settings(&conn).expect("reload settings");

        assert_eq!(settings.live_quota_refresh_interval_seconds, 600);
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

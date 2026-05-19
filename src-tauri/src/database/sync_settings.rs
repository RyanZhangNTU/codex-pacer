use rusqlite::{params, Connection, OptionalExtension};

use crate::models::SyncSettings;

use super::{bool_to_i64, i64_to_bool, now_utc_string};

pub fn default_menu_bar_popup_modules() -> Vec<String> {
    vec!["api_value".to_string(), "scan_freshness".to_string()]
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

pub(super) fn default_menu_bar_popup_modules_json() -> String {
    serde_json::to_string(&default_menu_bar_popup_modules())
        .expect("serialize default popup modules")
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

pub(super) fn ensure_sync_settings_schema(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(sync_settings)")?;
    let column_names = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    if !column_names
        .iter()
        .any(|name| name == "sync_settings_schema_version")
    {
        conn.execute(
            "
      ALTER TABLE sync_settings
      ADD COLUMN sync_settings_schema_version INTEGER NOT NULL DEFAULT 1
      ",
            [],
        )?;
    }

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

    if !column_names.iter().any(|name| name == "show_menu_bar_logo") {
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
      ADD COLUMN live_quota_refresh_interval_seconds INTEGER NOT NULL DEFAULT 300
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
      ADD COLUMN default_fast_mode_for_new_gpt54_sessions INTEGER NOT NULL DEFAULT 0
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

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_speed_show_emoji")
    {
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

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_speed_fast_emoji")
    {
        conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_fast_emoji TEXT NOT NULL DEFAULT '🔥'",
      [],
    )?;
    }

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_speed_slow_emoji")
    {
        conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_speed_slow_emoji TEXT NOT NULL DEFAULT '🐢'",
      [],
    )?;
    }

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_popup_enabled")
    {
        conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_enabled INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
    }

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_popup_modules")
    {
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

    if !column_names
        .iter()
        .any(|name| name == "menu_bar_popup_show_actions")
    {
        conn.execute(
      "ALTER TABLE sync_settings ADD COLUMN menu_bar_popup_show_actions INTEGER NOT NULL DEFAULT 1",
      [],
    )?;
    }

    migrate_sync_settings_defaults_to_minutes(conn)?;

    Ok(())
}

fn migrate_sync_settings_defaults_to_minutes(conn: &Connection) -> rusqlite::Result<()> {
    let schema_version = conn
        .query_row(
            "SELECT sync_settings_schema_version FROM sync_settings WHERE singleton_id = 1",
            [],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(2);

    if schema_version >= 2 {
        return Ok(());
    }

    conn.execute(
        "
    UPDATE sync_settings
    SET
      live_quota_refresh_interval_seconds = CASE
        WHEN live_quota_refresh_interval_seconds = 60 THEN 300
        ELSE live_quota_refresh_interval_seconds
      END,
      default_fast_mode_for_new_gpt54_sessions = CASE
        WHEN default_fast_mode_for_new_gpt54_sessions = 1 THEN 0
        ELSE default_fast_mode_for_new_gpt54_sessions
      END,
      sync_settings_schema_version = 2
    WHERE singleton_id = 1
    ",
        [],
    )?;

    Ok(())
}

pub fn get_sync_settings(conn: &Connection) -> rusqlite::Result<SyncSettings> {
    conn.query_row(
        "
    SELECT codex_home, auto_scan_enabled, auto_scan_interval_minutes,
           live_quota_refresh_interval_seconds,
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
                hide_dock_icon_when_menu_bar_visible: i64_to_bool(row.get::<_, i64>(4)?),
                show_menu_bar_logo: i64_to_bool(row.get::<_, i64>(5)?),
                show_menu_bar_daily_api_value: i64_to_bool(row.get::<_, i64>(6)?),
                show_menu_bar_live_quota_percent: i64_to_bool(row.get::<_, i64>(7)?),
                menu_bar_live_quota_metric: row.get(8)?,
                menu_bar_live_quota_bucket: row.get(9)?,
                menu_bar_bucket: row.get(10)?,
                menu_bar_speed_show_emoji: i64_to_bool(row.get::<_, i64>(11)?),
                menu_bar_speed_fast_threshold_percent: row.get(12)?,
                menu_bar_speed_slow_threshold_percent: row.get(13)?,
                menu_bar_speed_healthy_emoji: row.get(14)?,
                menu_bar_speed_fast_emoji: row.get(15)?,
                menu_bar_speed_slow_emoji: row.get(16)?,
                menu_bar_popup_enabled: i64_to_bool(row.get::<_, i64>(17)?),
                menu_bar_popup_modules: deserialize_menu_bar_popup_modules(row.get(18)?),
                menu_bar_popup_show_reset_timeline: i64_to_bool(row.get::<_, i64>(19)?),
                menu_bar_popup_show_actions: i64_to_bool(row.get::<_, i64>(20)?),
                last_scan_started_at: row.get(21)?,
                last_scan_completed_at: row.get(22)?,
                updated_at: row.get(23)?,
            })
        },
    )
}

pub fn save_sync_settings(
    conn: &Connection,
    settings: &SyncSettings,
) -> rusqlite::Result<SyncSettings> {
    let updated_at = now_utc_string();
    conn.execute(
    "
    INSERT INTO sync_settings (
      singleton_id, codex_home, auto_scan_enabled, auto_scan_interval_minutes,
      live_quota_refresh_interval_seconds,
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
    VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)
    ON CONFLICT(singleton_id) DO UPDATE SET
      codex_home = excluded.codex_home,
      auto_scan_enabled = excluded.auto_scan_enabled,
      auto_scan_interval_minutes = excluded.auto_scan_interval_minutes,
      live_quota_refresh_interval_seconds = excluded.live_quota_refresh_interval_seconds,
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
      settings.live_quota_refresh_interval_seconds.clamp(60, 3600),
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

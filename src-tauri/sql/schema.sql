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

CREATE TABLE IF NOT EXISTS subscription_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  paid_at TEXT NOT NULL CHECK (paid_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  service_start TEXT NOT NULL CHECK (service_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  service_end TEXT NOT NULL CHECK (service_end GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  amount_usd REAL NOT NULL CHECK (amount_usd > 0),
  billing_mode TEXT NOT NULL DEFAULT 'one_time' CHECK (billing_mode IN ('one_time', 'monthly_recurring')),
  plan_type TEXT NOT NULL,
  note TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (service_end > service_start)
);

CREATE TABLE IF NOT EXISTS session_overrides (
  session_id TEXT PRIMARY KEY,
  fast_mode_override INTEGER,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_settings (
  singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
  sync_settings_schema_version INTEGER NOT NULL DEFAULT 2,
  codex_home TEXT,
  auto_scan_enabled INTEGER NOT NULL,
  auto_scan_interval_minutes INTEGER NOT NULL,
  live_quota_refresh_interval_seconds INTEGER NOT NULL DEFAULT 300,
  default_fast_mode_for_new_gpt54_sessions INTEGER NOT NULL DEFAULT 0,
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
  menu_bar_popup_modules TEXT NOT NULL DEFAULT '["api_value","scan_freshness"]',
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

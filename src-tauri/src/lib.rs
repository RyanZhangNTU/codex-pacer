mod database;
mod importer;
mod models;
mod pricing;
mod queries;
mod rate_limits;

use std::fs;
use std::path::PathBuf;
use std::sync::{
  atomic::{AtomicBool, Ordering},
  Arc, Mutex,
};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Local};
use rusqlite::params;
use database::{
  canonical_subscription_currency, get_subscription_profile, get_sync_settings, init_db,
  insert_live_rate_limit_snapshot, open_connection, save_fast_mode_override,
  save_subscription_profile, save_sync_settings,
};
use importer::{perform_scan, recalculate_all_session_values, recalculate_session_values};
use models::{
  ConversationDetail, ConversationFilters, ConversationListItem, DashboardSnapshot,
  LiveRateLimitSnapshot, MenuBarPopupQuotaSnapshot, MenuBarPopupSnapshot,
  MenuBarPopupSuggestedSpeed, OverviewResponse, PricingCatalogEntry, RateLimitWindowSnapshot,
  ScanResult, SubscriptionProfile, SyncSettings,
};
use pricing::{load_catalog, seed_pricing_catalog};
use queries::{get_conversation_detail, get_overview, list_conversations, load_dashboard_data};
use rate_limits::query_live_rate_limits;
use tauri::{
  Emitter, Manager, PhysicalPosition, Position, Rect, WebviewUrl, WebviewWindow,
  WebviewWindowBuilder,
  menu::{Menu, MenuItem, PredefinedMenuItem},
  tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent},
  AppHandle, State,
};

const DAILY_VALUE_TRAY_ID: &str = "daily-api-value";
const DAILY_VALUE_SHOW_WINDOW_MENU_ID: &str = "daily-api-value.show-window";
const DAILY_VALUE_QUIT_MENU_ID: &str = "daily-api-value.quit";
const MAIN_WINDOW_LABEL: &str = "main";
const MENU_BAR_POPUP_WINDOW_LABEL: &str = "menu-bar-popup";
const MENU_BAR_POPUP_OPEN_SETTINGS_EVENT: &str = "codex-counter://open-settings";
const MENU_BAR_POPUP_REFRESH_EVENT: &str = "codex-counter://menu-bar-popup-refresh";
const MENU_BAR_POPUP_WIDTH: f64 = 420.0;
const MENU_BAR_POPUP_HEIGHT: f64 = 620.0;
const MENU_BAR_POPUP_OFFSET_Y: i32 = 8;
#[derive(Clone)]
struct CachedRateLimitSnapshot {
  fetched_at: Instant,
  snapshot: LiveRateLimitSnapshot,
}

#[derive(Clone)]
struct AppState {
  db_path: PathBuf,
  scan_in_progress: Arc<AtomicBool>,
  daily_value_tray: Option<TrayIcon>,
  live_rate_limits: Arc<Mutex<Option<CachedRateLimitSnapshot>>>,
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn scanCodexUsage(state: State<'_, AppState>, codex_home: Option<String>) -> Result<ScanResult, String> {
  run_scan_if_idle(state.inner().clone(), codex_home)
}

#[allow(non_snake_case)]
#[tauri::command]
fn getScanInProgress(state: State<'_, AppState>) -> bool {
  state.inner().scan_in_progress.load(Ordering::SeqCst)
}

#[allow(non_snake_case)]
#[tauri::command]
fn refreshPricing(state: State<'_, AppState>) -> Result<Vec<PricingCatalogEntry>, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  seed_pricing_catalog(&conn).map_err(|error| error.to_string())?;
  recalculate_all_session_values(&conn).map_err(|error| error.to_string())?;
  let catalog = load_catalog(&conn).map_err(|error| error.to_string())?;
  refresh_daily_value_menu_bar(state.inner());
  Ok(catalog)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn getOverview(
  state: State<'_, AppState>,
  bucket: Option<String>,
  anchor: Option<String>,
  live_window_offset: Option<i64>,
) -> Result<OverviewResponse, String> {
  let live_rate_limits = maybe_live_rate_limits_for_bucket(state.inner(), bucket.as_deref(), live_window_offset)?;
  get_overview(&state.db_path, bucket, anchor, live_rate_limits, live_window_offset)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn listConversations(
  state: State<'_, AppState>,
  filters: Option<ConversationFilters>,
) -> Result<Vec<ConversationListItem>, String> {
  let live_rate_limits = maybe_live_rate_limits_for_bucket(
    state.inner(),
    filters.as_ref().and_then(|value| value.bucket.as_deref()),
    filters.as_ref().and_then(|value| value.live_window_offset),
  )?;
  list_conversations(&state.db_path, filters, live_rate_limits)
}

#[allow(non_snake_case)]
#[tauri::command]
fn getLiveRateLimits(state: State<'_, AppState>) -> Result<LiveRateLimitSnapshot, String> {
  get_live_rate_limits_cached(state.inner())
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn getMenuBarPopupSnapshot(
  state: State<'_, AppState>,
  force_refresh: Option<bool>,
) -> Result<MenuBarPopupSnapshot, String> {
  build_menu_bar_popup_snapshot(state.inner(), force_refresh.unwrap_or(false))
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
async fn loadDashboard(
  state: State<'_, AppState>,
  bucket: Option<String>,
  anchor: Option<String>,
  search: Option<String>,
  live_window_offset: Option<i64>,
) -> Result<DashboardSnapshot, String> {
  let state = state.inner().clone();
  tauri::async_runtime::spawn_blocking(move || {
    let normalized_bucket = bucket.clone().unwrap_or_else(|| "subscription_month".to_string());
    let live_rate_limits =
      maybe_live_rate_limits_for_bucket(&state, Some(&normalized_bucket), live_window_offset)?;
    let snapshot = load_dashboard_data(
      &state.db_path,
      Some(normalized_bucket.clone()),
      anchor.clone(),
      search,
      live_rate_limits.clone(),
      live_window_offset,
    )?;
    let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
    let sync_settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;

    Ok(DashboardSnapshot {
      overview: snapshot.overview,
      conversations: snapshot.conversations,
      sync_settings,
      subscription_profile: snapshot.subscription_profile,
      live_rate_limits,
    })
  })
  .await
  .map_err(|error| format!("Failed to load dashboard: {error}"))?
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn getConversationDetail(
  state: State<'_, AppState>,
  root_session_id: String,
) -> Result<ConversationDetail, String> {
  get_conversation_detail(&state.db_path, &root_session_id)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn handleMenuBarPopupAction(
  app: AppHandle,
  state: State<'_, AppState>,
  action: String,
) -> Result<bool, String> {
  match action.as_str() {
    "open_dashboard" => {
      hide_menu_bar_popup(&app);
      show_main_window(&app);
      Ok(true)
    }
    "open_settings" => {
      hide_menu_bar_popup(&app);
      show_main_window(&app);
      app
        .emit_to(MAIN_WINDOW_LABEL, MENU_BAR_POPUP_OPEN_SETTINGS_EVENT, ())
        .map_err(|error| error.to_string())?;
      Ok(true)
    }
    "hide" => {
      hide_menu_bar_popup(&app);
      Ok(true)
    }
    "refresh" => {
      let _ = build_menu_bar_popup_snapshot(state.inner(), true)?;
      refresh_daily_value_menu_bar(state.inner());
      Ok(true)
    }
    _ => Err(format!("Unsupported popup action: {action}")),
  }
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn setFastModeOverride(
  state: State<'_, AppState>,
  session_id: String,
  override_value: Option<bool>,
) -> Result<bool, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  save_fast_mode_override(&conn, &session_id, override_value).map_err(|error| error.to_string())?;
  recalculate_session_values(&conn, &session_id).map_err(|error| error.to_string())?;
  Ok(true)
}

#[allow(non_snake_case)]
#[tauri::command]
fn getSyncSettings(state: State<'_, AppState>) -> Result<SyncSettings, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  get_sync_settings(&conn).map_err(|error| error.to_string())
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn updateSyncSettings(
  app: AppHandle,
  state: State<'_, AppState>,
  payload: SyncSettings,
) -> Result<SyncSettings, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let current = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  let updated = SyncSettings {
    codex_home: payload.codex_home,
    auto_scan_enabled: payload.auto_scan_enabled,
    auto_scan_interval_minutes: payload.auto_scan_interval_minutes.max(1),
    live_quota_refresh_interval_seconds: payload.live_quota_refresh_interval_seconds.clamp(5, 3600),
    default_fast_mode_for_new_gpt54_sessions: payload.default_fast_mode_for_new_gpt54_sessions,
    hide_dock_icon_when_menu_bar_visible: payload.hide_dock_icon_when_menu_bar_visible,
    show_menu_bar_logo: payload.show_menu_bar_logo,
    show_menu_bar_daily_api_value: payload.show_menu_bar_daily_api_value,
    show_menu_bar_live_quota_percent: payload.show_menu_bar_live_quota_percent,
    menu_bar_live_quota_metric: normalize_menu_bar_live_quota_metric(&payload.menu_bar_live_quota_metric),
    menu_bar_live_quota_bucket: normalize_menu_bar_live_quota_bucket(&payload.menu_bar_live_quota_bucket),
    menu_bar_bucket: normalize_menu_bar_bucket(&payload.menu_bar_bucket),
    menu_bar_speed_show_emoji: payload.menu_bar_speed_show_emoji,
    menu_bar_speed_fast_threshold_percent: payload.menu_bar_speed_fast_threshold_percent.clamp(0, 1000),
    menu_bar_speed_slow_threshold_percent: payload.menu_bar_speed_slow_threshold_percent.clamp(0, 1000),
    menu_bar_speed_healthy_emoji: normalize_menu_bar_speed_emoji(&payload.menu_bar_speed_healthy_emoji, "🟢"),
    menu_bar_speed_fast_emoji: normalize_menu_bar_speed_emoji(&payload.menu_bar_speed_fast_emoji, "🔥"),
    menu_bar_speed_slow_emoji: normalize_menu_bar_speed_emoji(&payload.menu_bar_speed_slow_emoji, "🐢"),
    menu_bar_popup_enabled: payload.menu_bar_popup_enabled,
    menu_bar_popup_modules: normalize_menu_bar_popup_modules(&payload.menu_bar_popup_modules),
    menu_bar_popup_show_reset_timeline: payload.menu_bar_popup_show_reset_timeline,
    menu_bar_popup_show_actions: payload.menu_bar_popup_show_actions,
    last_scan_started_at: current.last_scan_started_at,
    last_scan_completed_at: current.last_scan_completed_at,
    updated_at: current.updated_at,
  };
  let saved = save_sync_settings(&conn, &updated).map_err(|error| error.to_string())?;
  refresh_daily_value_menu_bar(state.inner());
  apply_dock_icon_visibility(&app, &saved, state.daily_value_tray.is_some());
  Ok(saved)
}

#[allow(non_snake_case)]
#[tauri::command]
fn getSubscriptionProfile(state: State<'_, AppState>) -> Result<SubscriptionProfile, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  get_subscription_profile(&conn).map_err(|error| error.to_string())
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn updateSubscriptionProfile(
  state: State<'_, AppState>,
  payload: SubscriptionProfile,
) -> Result<SubscriptionProfile, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let updated = SubscriptionProfile {
    plan_type: payload.plan_type,
    currency: canonical_subscription_currency().to_string(),
    monthly_price: payload.monthly_price.max(0.0),
    billing_anchor_day: payload.billing_anchor_day.clamp(1, 28),
    updated_at: payload.updated_at,
  };
  save_subscription_profile(&conn, &updated).map_err(|error| error.to_string())
}

fn run_scan_if_idle(state: AppState, codex_home: Option<String>) -> Result<ScanResult, String> {
  if state
    .scan_in_progress
    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
    .is_err()
  {
    return Err("A scan is already running.".to_string());
  }

  let result = perform_scan(&state.db_path, codex_home);
  state.scan_in_progress.store(false, Ordering::SeqCst);
  refresh_daily_value_menu_bar(&state);
  result
}

fn refresh_daily_value_menu_bar(state: &AppState) {
  if let Err(error) = update_daily_value_menu_bar(state) {
    log::warn!("Failed to update menu bar display: {error}");
  }
}

fn update_daily_value_menu_bar(state: &AppState) -> Result<(), String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  let Some(tray) = state.daily_value_tray.as_ref() else {
    return Ok(());
  };

  if !menu_bar_has_visible_content(&settings) {
    tray.set_visible(false).map_err(|error| error.to_string())?;
    return Ok(());
  }

  apply_menu_bar_icon(tray, settings.show_menu_bar_logo)?;
  let (api_value_title, live_metric_title) = current_menu_bar_title_parts(state, &settings)?;
  match menu_bar_title(api_value_title.as_deref(), live_metric_title.as_deref()) {
    Some(title) => tray.set_title(Some(&title)).map_err(|error| error.to_string())?,
    None => tray
      .set_title(None::<String>)
      .map_err(|error| error.to_string())?,
  }
  tray
    .set_tooltip(Some(menu_bar_tooltip(&settings, api_value_title.as_deref(), state)?))
    .map_err(|error| error.to_string())?;
  tray.set_visible(true).map_err(|error| error.to_string())?;
  Ok(())
}

fn menu_bar_has_visible_content(settings: &SyncSettings) -> bool {
  settings.show_menu_bar_logo
    || settings.show_menu_bar_daily_api_value
    || settings.show_menu_bar_live_quota_percent
}

fn should_hide_dock_icon(settings: &SyncSettings) -> bool {
  settings.hide_dock_icon_when_menu_bar_visible && menu_bar_has_visible_content(settings)
}

#[cfg(target_os = "macos")]
fn apply_dock_icon_visibility(app: &AppHandle, settings: &SyncSettings, menu_bar_available: bool) {
  let activation_policy = if menu_bar_available && should_hide_dock_icon(settings) {
    tauri::ActivationPolicy::Accessory
  } else {
    tauri::ActivationPolicy::Regular
  };

  if let Err(error) = app.set_activation_policy(activation_policy) {
    log::warn!("Failed to update macOS Dock visibility: {error}");
  }
}

#[cfg(not(target_os = "macos"))]
fn apply_dock_icon_visibility(_: &AppHandle, _: &SyncSettings, _: bool) {}

fn apply_menu_bar_icon(tray: &TrayIcon, show_logo: bool) -> Result<(), String> {
  if show_logo {
    if let Some(icon) = tray.app_handle().default_window_icon().cloned() {
      tray.set_icon(Some(icon)).map_err(|error| error.to_string())?;
      #[cfg(target_os = "macos")]
      tray
        .set_icon_as_template(true)
        .map_err(|error| error.to_string())?;
    }
  } else {
    tray.set_icon(None).map_err(|error| error.to_string())?;
  }
  Ok(())
}

fn current_menu_bar_title_parts(
  state: &AppState,
  settings: &SyncSettings,
) -> Result<(Option<String>, Option<String>), String> {
  let bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let anchor = Local::now().format("%Y-%m-%d").to_string();
  let live_rate_limits = if settings.show_menu_bar_live_quota_percent
    || (settings.show_menu_bar_daily_api_value && bucket_uses_live_rate_limits(&bucket))
  {
    maybe_live_rate_limits_for_bucket(state, Some(&bucket), None)?
  } else {
    None
  };
  let api_value_title = if settings.show_menu_bar_daily_api_value {
    let overview = get_overview(
      &state.db_path,
      Some(bucket.clone()),
      if bucket_uses_anchor(&bucket) { Some(anchor) } else { None },
      live_rate_limits.clone(),
      None,
    )?;
    Some(format!("${:.1}", overview.stats.api_value_usd))
  } else {
    None
  };
  let live_metric_title = if settings.show_menu_bar_live_quota_percent {
    menu_bar_live_quota_snapshot(
      state,
      settings,
      &settings.menu_bar_live_quota_bucket,
      &settings.menu_bar_live_quota_metric,
      live_rate_limits,
      Local::now(),
    )?
  } else {
    None
  };
  Ok((api_value_title, live_metric_title))
}

fn menu_bar_title(api_value_title: Option<&str>, live_metric_title: Option<&str>) -> Option<String> {
  let mut segments = Vec::new();
  if let Some(value) = api_value_title.filter(|value| !value.trim().is_empty()) {
    segments.push(value.to_string());
  }
  if let Some(value) = live_metric_title.filter(|value| !value.trim().is_empty()) {
    segments.push(value.to_string());
  }
  if segments.is_empty() {
    None
  } else {
    Some(segments.join(" "))
  }
}

fn normalize_menu_bar_bucket(bucket: &str) -> String {
  match bucket {
    "day" | "week" | "five_hour" | "seven_day" | "subscription_month" | "month" | "year" | "total" => {
      bucket.to_string()
    }
    _ => "day".to_string(),
  }
}

fn normalize_menu_bar_live_quota_bucket(bucket: &str) -> String {
  match bucket {
    "five_hour" | "seven_day" => bucket.to_string(),
    _ => "five_hour".to_string(),
  }
}

fn normalize_menu_bar_live_quota_metric(metric: &str) -> String {
  match metric {
    "remaining_percent" | "suggested_usage_speed" => metric.to_string(),
    _ => "remaining_percent".to_string(),
  }
}

fn normalize_menu_bar_speed_emoji(value: &str, fallback: &str) -> String {
  let trimmed = value.trim();
  if trimmed.is_empty() {
    fallback.to_string()
  } else {
    trimmed.chars().take(4).collect()
  }
}

fn normalize_menu_bar_popup_modules(modules: &[String]) -> Vec<String> {
  let mut normalized = Vec::new();
  for module in modules {
    let candidate = match module.as_str() {
      "api_value"
      | "token_count"
      | "scan_freshness"
      | "live_quota_freshness"
      | "payoff_ratio"
      | "conversation_count" => module.clone(),
      _ => continue,
    };

    if !normalized.iter().any(|existing| existing == &candidate) {
      normalized.push(candidate);
    }
  }
  normalized
}

fn menu_bar_tooltip(
  settings: &SyncSettings,
  api_value_title: Option<&str>,
  state: &AppState,
) -> Result<String, String> {
  let bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let mut fragments = Vec::new();
  if let Some(title) = api_value_title.filter(|value| !value.trim().is_empty()) {
    fragments.push(format!("{}累计 API 价值：{title}", menu_bar_bucket_label(&bucket)));
  }
  if settings.show_menu_bar_live_quota_percent {
    let snapshot = get_live_rate_limits_cached(state)?;
    if let Some(fragment) = menu_bar_live_quota_tooltip(
      &snapshot,
      settings,
      &settings.menu_bar_live_quota_bucket,
      &settings.menu_bar_live_quota_metric,
      Local::now(),
    ) {
      fragments.push(fragment);
    }
  }
  if fragments.is_empty() {
    Ok("Codex Pacer".to_string())
  } else {
    Ok(fragments.join(" · "))
  }
}

fn menu_bar_bucket_label(bucket: &str) -> &'static str {
  match bucket {
    "week" => "本周",
    "five_hour" => "近 5 小时",
    "seven_day" => "近 7 天",
    "subscription_month" => "本订阅月",
    "month" => "本月",
    "year" => "本年",
    "total" => "总计",
    _ => "今日",
  }
}

fn bucket_uses_live_rate_limits(bucket: &str) -> bool {
  matches!(bucket, "five_hour" | "seven_day")
}

fn bucket_uses_anchor(bucket: &str) -> bool {
  !matches!(bucket, "total" | "five_hour" | "seven_day")
}

fn menu_bar_live_quota_snapshot(
  state: &AppState,
  settings: &SyncSettings,
  bucket: &str,
  metric: &str,
  existing_snapshot: Option<LiveRateLimitSnapshot>,
  now: DateTime<Local>,
) -> Result<Option<String>, String> {
  let snapshot = match existing_snapshot {
    Some(snapshot) => snapshot,
    None => get_live_rate_limits_cached(state)?,
  };
  Ok(menu_bar_live_quota_title(&snapshot, settings, bucket, metric, now))
}

fn selected_menu_bar_live_quota_window<'a>(
  snapshot: &'a LiveRateLimitSnapshot,
  bucket: &str,
) -> Option<(&'static str, &'a RateLimitWindowSnapshot)> {
  match normalize_menu_bar_live_quota_bucket(bucket).as_str() {
    "seven_day" => snapshot.secondary.as_ref().map(|window| ("7天", window)),
    _ => snapshot.primary.as_ref().map(|window| ("5小时", window)),
  }
}

fn menu_bar_live_quota_title(
  snapshot: &LiveRateLimitSnapshot,
  settings: &SyncSettings,
  bucket: &str,
  metric: &str,
  now: DateTime<Local>,
) -> Option<String> {
  let (_, window) = selected_menu_bar_live_quota_window(snapshot, bucket)?;
  match normalize_menu_bar_live_quota_metric(metric).as_str() {
    "suggested_usage_speed" => {
      let velocity = suggested_usage_velocity(window, now, settings)?;
      Some(velocity.rendered_value())
    }
    _ => Some(format!("{}%", window.remaining_percent.clamp(0, 100))),
  }
}

fn menu_bar_live_quota_tooltip(
  snapshot: &LiveRateLimitSnapshot,
  settings: &SyncSettings,
  bucket: &str,
  metric: &str,
  now: DateTime<Local>,
) -> Option<String> {
  let (label, window) = selected_menu_bar_live_quota_window(snapshot, bucket)?;
  match normalize_menu_bar_live_quota_metric(metric).as_str() {
    "suggested_usage_speed" => {
      let velocity = suggested_usage_velocity(window, now, settings)?;
      Some(format!(
        "{label}建议使用速度 {} {} · 剩余额度 {}% / 剩余时间 {:.1}%",
        velocity.emoji,
        velocity.display_value,
        window.remaining_percent.clamp(0, 100),
        velocity.remaining_time_percent,
      ))
    }
    _ => Some(format!("{label}剩余 {}%", window.remaining_percent.clamp(0, 100))),
  }
}

#[derive(Debug, Clone, PartialEq)]
struct SuggestedUsageVelocityDisplay {
  emoji: String,
  display_value: String,
  remaining_time_percent: f64,
}

impl SuggestedUsageVelocityDisplay {
  fn rendered_value(&self) -> String {
    if self.emoji.is_empty() {
      self.display_value.clone()
    } else {
      format!("{} {}", self.emoji, self.display_value)
    }
  }
}

fn suggested_usage_velocity(
  window: &RateLimitWindowSnapshot,
  now: DateTime<Local>,
  settings: &SyncSettings,
) -> Option<SuggestedUsageVelocityDisplay> {
  let (window_start, reset_at) = quota_window_bounds(window)?;
  let total_seconds = reset_at.signed_duration_since(window_start).num_seconds();
  if total_seconds <= 0 {
    return None;
  }

  let remaining_seconds = reset_at.signed_duration_since(now).num_seconds() as f64;
  let remaining_time_percent = ((remaining_seconds / total_seconds as f64) * 100.0).clamp(0.0, 100.0);
  let remaining_percent = window.remaining_percent.clamp(0, 100) as f64;
  let ratio = if remaining_time_percent <= 0.0 {
    if remaining_percent <= 0.0 { 1.0 } else { 10.0 }
  } else {
    remaining_percent / remaining_time_percent
  };
  let capped_ratio = ratio.clamp(0.0, 10.0);
  let percent = capped_ratio * 100.0;
  let display_value = if ratio > 10.0 {
    "1000%+".to_string()
  } else {
    format!("{percent:.0}%")
  };

  let fast_threshold = settings.menu_bar_speed_fast_threshold_percent.clamp(0, 1000) as f64;
  let slow_threshold = settings
    .menu_bar_speed_slow_threshold_percent
    .clamp(0, 1000)
    .max(settings.menu_bar_speed_fast_threshold_percent.clamp(0, 1000)) as f64;

  Some(SuggestedUsageVelocityDisplay {
    emoji: usage_velocity_emoji(percent, fast_threshold, slow_threshold, settings),
    display_value,
    remaining_time_percent,
  })
}

fn usage_velocity_emoji(
  percent: f64,
  fast_threshold: f64,
  slow_threshold: f64,
  settings: &SyncSettings,
) -> String {
  if !settings.menu_bar_speed_show_emoji {
    String::new()
  } else if percent < fast_threshold {
    settings.menu_bar_speed_fast_emoji.clone()
  } else if percent <= slow_threshold {
    settings.menu_bar_speed_healthy_emoji.clone()
  } else {
    settings.menu_bar_speed_slow_emoji.clone()
  }
}

fn quota_window_bounds(window: &RateLimitWindowSnapshot) -> Option<(DateTime<Local>, DateTime<Local>)> {
  let reset_at = window.resets_at.as_deref().and_then(parse_rfc3339_local)?;
  let window_start = match window.window_start.as_deref().and_then(parse_rfc3339_local) {
    Some(timestamp) => timestamp,
    None => reset_at - ChronoDuration::minutes(window.window_duration_mins?),
  };
  Some((window_start, reset_at))
}

fn parse_rfc3339_local(value: &str) -> Option<DateTime<Local>> {
  DateTime::parse_from_rfc3339(value)
    .ok()
    .map(|timestamp| timestamp.with_timezone(&Local))
}

fn maybe_live_rate_limits_for_bucket(
  state: &AppState,
  bucket: Option<&str>,
  live_window_offset: Option<i64>,
) -> Result<Option<LiveRateLimitSnapshot>, String> {
  let Some(bucket) = bucket else {
    return Ok(None);
  };
  if !bucket_uses_live_rate_limits(bucket) {
    return Ok(None);
  }
  if live_window_offset.unwrap_or(0) > 0 {
    return Ok(None);
  }
  Ok(Some(get_live_rate_limits_cached(state)?))
}

fn get_live_rate_limits_cached(state: &AppState) -> Result<LiveRateLimitSnapshot, String> {
  get_live_rate_limits(state, false)
}

fn get_live_rate_limits(state: &AppState, force_refresh: bool) -> Result<LiveRateLimitSnapshot, String> {
  let mut cache = state
    .live_rate_limits
    .lock()
    .map_err(|_| "Live rate-limit cache is unavailable.".to_string())?;
  let ttl = live_rate_limit_cache_ttl(state);

  if !force_refresh {
    if let Some(snapshot) = cache.as_ref() {
      if snapshot.fetched_at.elapsed() <= ttl {
        return Ok(snapshot.snapshot.clone());
      }
    }
  }

  let snapshot = query_live_rate_limits()?;
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  insert_live_rate_limit_snapshot(&conn, &snapshot).map_err(|error| error.to_string())?;
  *cache = Some(CachedRateLimitSnapshot {
    fetched_at: Instant::now(),
    snapshot: snapshot.clone(),
  });
  Ok(snapshot)
}

#[derive(Clone)]
struct PersistedRateLimitWindow {
  snapshot: RateLimitWindowSnapshot,
  fetched_at: String,
  limit_id: Option<String>,
  limit_name: Option<String>,
  plan_type: Option<String>,
}

fn load_latest_persisted_rate_limit_window(
  conn: &rusqlite::Connection,
  bucket: &str,
) -> Result<Option<PersistedRateLimitWindow>, String> {
  let mut stmt = conn
    .prepare(
      "
      SELECT sample_timestamp, limit_id, limit_name, plan_type, window_start, resets_at, used_percent, remaining_percent
      FROM rate_limit_samples
      WHERE bucket = ?1
      ORDER BY sample_timestamp DESC
      LIMIT 1
      ",
    )
    .map_err(|error| error.to_string())?;

  let mut rows = stmt.query(params![bucket]).map_err(|error| error.to_string())?;
  let Some(row) = rows.next().map_err(|error| error.to_string())? else {
    return Ok(None);
  };

  let sample_timestamp = row.get::<_, String>(0).map_err(|error| error.to_string())?;
  let limit_id = row
    .get::<_, String>(1)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let limit_name = row
    .get::<_, String>(2)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let plan_type = row
    .get::<_, String>(3)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let window_start = row.get::<_, String>(4).map_err(|error| error.to_string())?;
  let resets_at = row.get::<_, String>(5).map_err(|error| error.to_string())?;
  let used_percent = row.get::<_, i64>(6).map_err(|error| error.to_string())?;
  let remaining_percent = row.get::<_, i64>(7).map_err(|error| error.to_string())?;

  let window_duration_mins = match (
    parse_rfc3339_local(&window_start),
    parse_rfc3339_local(&resets_at),
  ) {
    (Some(start), Some(end)) => Some(end.signed_duration_since(start).num_minutes().max(0)),
    _ => None,
  };

  Ok(Some(PersistedRateLimitWindow {
    snapshot: RateLimitWindowSnapshot {
      used_percent,
      remaining_percent,
      window_duration_mins,
      resets_at: Some(resets_at),
      window_start: Some(window_start),
    },
    fetched_at: sample_timestamp,
    limit_id,
    limit_name,
    plan_type,
  }))
}

fn load_persisted_live_rate_limits(state: &AppState) -> Option<LiveRateLimitSnapshot> {
  let conn = open_connection(&state.db_path).ok()?;
  let primary = load_latest_persisted_rate_limit_window(&conn, "five_hour").ok().flatten();
  let secondary = load_latest_persisted_rate_limit_window(&conn, "seven_day").ok().flatten();
  if primary.is_none() && secondary.is_none() {
    return None;
  }

  let fetched_at = primary
    .as_ref()
    .map(|window| window.fetched_at.clone())
    .or_else(|| secondary.as_ref().map(|window| window.fetched_at.clone()))
    .unwrap_or_else(|| Local::now().to_rfc3339());

  Some(LiveRateLimitSnapshot {
    limit_id: primary
      .as_ref()
      .and_then(|window| window.limit_id.clone())
      .or_else(|| secondary.as_ref().and_then(|window| window.limit_id.clone())),
    limit_name: primary
      .as_ref()
      .and_then(|window| window.limit_name.clone())
      .or_else(|| secondary.as_ref().and_then(|window| window.limit_name.clone())),
    plan_type: primary
      .as_ref()
      .and_then(|window| window.plan_type.clone())
      .or_else(|| secondary.as_ref().and_then(|window| window.plan_type.clone())),
    primary: primary.map(|window| window.snapshot),
    secondary: secondary.map(|window| window.snapshot),
    fetched_at,
  })
}

fn get_live_rate_limits_local(state: &AppState) -> Option<LiveRateLimitSnapshot> {
  state
    .live_rate_limits
    .lock()
    .ok()
    .and_then(|cache| cache.as_ref().map(|snapshot| snapshot.snapshot.clone()))
    .or_else(|| load_persisted_live_rate_limits(state))
}

fn best_effort_live_rate_limits(state: &AppState, force_refresh: bool) -> Option<LiveRateLimitSnapshot> {
  match get_live_rate_limits(state, force_refresh) {
    Ok(snapshot) => Some(snapshot),
    Err(error) => {
      log::warn!("Failed to refresh live rate limits for popup: {error}");
      get_live_rate_limits_local(state)
    }
  }
}

fn build_menu_bar_popup_snapshot(
  state: &AppState,
  force_refresh: bool,
) -> Result<MenuBarPopupSnapshot, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  let live_rate_limits = if force_refresh {
    best_effort_live_rate_limits(state, true)
  } else {
    get_live_rate_limits_local(state)
  };
  let selected_bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let anchor = bucket_uses_anchor(&selected_bucket).then(|| Local::now().format("%Y-%m-%d").to_string());
  let overview = get_overview(
    &state.db_path,
    Some(selected_bucket.clone()),
    anchor,
    if bucket_uses_live_rate_limits(&selected_bucket) {
      live_rate_limits.clone()
    } else {
      None
    },
    None,
  )
  .ok();

  Ok(MenuBarPopupSnapshot {
    fetched_at: Local::now().to_rfc3339(),
    refresh_interval_seconds: settings.live_quota_refresh_interval_seconds,
    selected_bucket,
    quota_5h: live_rate_limits
      .as_ref()
      .and_then(|snapshot| snapshot.primary.as_ref().map(menu_bar_popup_quota_snapshot)),
    quota_7d: live_rate_limits
      .as_ref()
      .and_then(|snapshot| snapshot.secondary.as_ref().map(menu_bar_popup_quota_snapshot)),
    suggested_speed_7d: live_rate_limits
      .as_ref()
      .and_then(|snapshot| snapshot.secondary.as_ref())
      .and_then(|window| menu_bar_popup_suggested_speed(window, &settings, Local::now())),
    speed_fast_threshold_percent: settings.menu_bar_speed_fast_threshold_percent,
    speed_slow_threshold_percent: settings.menu_bar_speed_slow_threshold_percent,
    api_value_selected_bucket: overview.as_ref().map(|value| value.stats.api_value_usd).unwrap_or(0.0),
    total_tokens_selected_bucket: overview.as_ref().map(|value| value.stats.total_tokens).unwrap_or(0),
    conversation_count_selected_bucket: overview
      .as_ref()
      .map(|value| value.stats.conversation_count)
      .unwrap_or(0),
    payoff_ratio: overview.as_ref().map(|value| value.stats.payoff_ratio).unwrap_or(0.0),
    last_scan_completed_at: settings.last_scan_completed_at,
    live_quota_fetched_at: live_rate_limits.as_ref().map(|snapshot| snapshot.fetched_at.clone()),
    visible_modules: normalize_menu_bar_popup_modules(&settings.menu_bar_popup_modules),
    show_reset_timeline: settings.menu_bar_popup_show_reset_timeline,
    show_actions: settings.menu_bar_popup_show_actions,
  })
}

fn menu_bar_popup_quota_snapshot(window: &RateLimitWindowSnapshot) -> MenuBarPopupQuotaSnapshot {
  MenuBarPopupQuotaSnapshot {
    used_percent: window.used_percent,
    remaining_percent: window.remaining_percent,
    window_duration_mins: window.window_duration_mins,
    resets_at: window.resets_at.clone(),
    window_start: window.window_start.clone(),
  }
}

fn menu_bar_popup_suggested_speed(
  window: &RateLimitWindowSnapshot,
  settings: &SyncSettings,
  now: DateTime<Local>,
) -> Option<MenuBarPopupSuggestedSpeed> {
  let velocity = suggested_usage_velocity(window, now, settings)?;
  let fast_threshold = settings.menu_bar_speed_fast_threshold_percent.clamp(0, 1000) as f64;
  let slow_threshold = settings
    .menu_bar_speed_slow_threshold_percent
    .clamp(0, 1000)
    .max(settings.menu_bar_speed_fast_threshold_percent.clamp(0, 1000)) as f64;
  let percent = velocity_ratio_percent(window, now);

  Some(MenuBarPopupSuggestedSpeed {
    percent: percent.round() as i64,
    display_value: velocity.display_value,
    emoji: velocity.emoji,
    status: usage_velocity_status(percent, fast_threshold, slow_threshold).to_string(),
    remaining_time_percent: velocity.remaining_time_percent,
    remaining_percent: window.remaining_percent.clamp(0, 100),
  })
}

fn velocity_ratio_percent(window: &RateLimitWindowSnapshot, now: DateTime<Local>) -> f64 {
  let Some((window_start, reset_at)) = quota_window_bounds(window) else {
    return 0.0;
  };
  let total_seconds = reset_at.signed_duration_since(window_start).num_seconds();
  if total_seconds <= 0 {
    return 0.0;
  }

  let remaining_seconds = reset_at.signed_duration_since(now).num_seconds() as f64;
  let remaining_time_percent = ((remaining_seconds / total_seconds as f64) * 100.0).clamp(0.0, 100.0);
  if remaining_time_percent <= 0.0 {
    if window.remaining_percent <= 0 { 100.0 } else { 1000.0 }
  } else {
    ((window.remaining_percent.clamp(0, 100) as f64 / remaining_time_percent) * 100.0).clamp(0.0, 1000.0)
  }
}

fn usage_velocity_status(percent: f64, fast_threshold: f64, slow_threshold: f64) -> &'static str {
  if percent < fast_threshold {
    "fast"
  } else if percent <= slow_threshold {
    "healthy"
  } else {
    "slow"
  }
}

fn live_rate_limit_cache_ttl(state: &AppState) -> Duration {
  open_connection(&state.db_path)
    .ok()
    .and_then(|conn| get_sync_settings(&conn).ok())
    .map(|settings| Duration::from_secs(settings.live_quota_refresh_interval_seconds.clamp(5, 3600) as u64))
    .unwrap_or(Duration::from_secs(60))
}

fn build_menu_bar_popup_window(app: &AppHandle) -> Result<WebviewWindow, String> {
  if let Some(window) = app.get_webview_window(MENU_BAR_POPUP_WINDOW_LABEL) {
    return Ok(window);
  }

  WebviewWindowBuilder::new(app, MENU_BAR_POPUP_WINDOW_LABEL, WebviewUrl::App("index.html".into()))
    .title("Codex Pacer Popup")
    .inner_size(MENU_BAR_POPUP_WIDTH, MENU_BAR_POPUP_HEIGHT)
    .resizable(false)
    .visible(false)
    .focused(false)
    .decorations(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .accept_first_mouse(true)
    .shadow(true)
    .initialization_script("window.__CODEX_COUNTER_SURFACE__ = 'menu-bar-popup';")
    .build()
    .map_err(|error| error.to_string())
}

fn hide_menu_bar_popup(app: &AppHandle) {
  if let Some(window) = app.get_webview_window(MENU_BAR_POPUP_WINDOW_LABEL) {
    let _ = window.hide();
  }
}

fn toggle_menu_bar_popup(
  app: &AppHandle,
  rect: Rect,
  click_position: PhysicalPosition<f64>,
) -> Result<(), String> {
  let state = app.state::<AppState>();
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  if !settings.menu_bar_popup_enabled {
    show_main_window(app);
    return Ok(());
  }

  let window = build_menu_bar_popup_window(app)?;
  if window.is_visible().map_err(|error| error.to_string())? {
    window.hide().map_err(|error| error.to_string())?;
    return Ok(());
  }

  position_menu_bar_popup(&window, rect, click_position)?;
  window.show().map_err(|error| error.to_string())?;
  window.set_focus().map_err(|error| error.to_string())?;
  window
    .emit(MENU_BAR_POPUP_REFRESH_EVENT, ())
    .map_err(|error| error.to_string())?;
  Ok(())
}

fn position_menu_bar_popup(
  window: &WebviewWindow,
  rect: Rect,
  click_position: PhysicalPosition<f64>,
) -> Result<(), String> {
  if let Some(monitor) = window
    .monitor_from_point(click_position.x, click_position.y)
    .map_err(|error| error.to_string())?
  {
    let scale_factor = monitor.scale_factor();
    let rect_position = tray_rect_position_to_physical(rect.position, scale_factor);
    let rect_size = tray_rect_size_to_physical(rect.size, scale_factor);
    let mut x = rect_position.x + rect_size.width as i32 / 2 - MENU_BAR_POPUP_WIDTH as i32 / 2;
    let mut y = rect_position.y + rect_size.height as i32 + MENU_BAR_POPUP_OFFSET_Y;
    let monitor_position = monitor.position();
    let monitor_size = monitor.size();
    let max_x = monitor_position.x + monitor_size.width as i32 - MENU_BAR_POPUP_WIDTH as i32;
    let max_y = monitor_position.y + monitor_size.height as i32 - MENU_BAR_POPUP_HEIGHT as i32;
    x = x.clamp(monitor_position.x, max_x.max(monitor_position.x));
    y = y.clamp(monitor_position.y, max_y.max(monitor_position.y));
    return window
      .set_position(Position::Physical(PhysicalPosition::new(x, y)))
      .map_err(|error| error.to_string());
  }

  let rect_position = tray_rect_position_to_physical(rect.position, 1.0);
  let rect_size = tray_rect_size_to_physical(rect.size, 1.0);
  let anchor_x = if rect_size.width > 0 {
    rect_position.x + rect_size.width as i32 / 2
  } else {
    click_position.x.round() as i32
  };
  let anchor_y = if rect_size.height > 0 {
    rect_position.y + rect_size.height as i32
  } else {
    click_position.y.round() as i32
  };
  let x = (anchor_x - MENU_BAR_POPUP_WIDTH as i32 / 2).max(0);
  let y = (anchor_y + MENU_BAR_POPUP_OFFSET_Y).max(0);
  window
    .set_position(Position::Physical(PhysicalPosition::new(x, y)))
    .map_err(|error| error.to_string())
}

fn tray_rect_position_to_physical(position: Position, scale_factor: f64) -> PhysicalPosition<i32> {
  match position {
    Position::Physical(position) => position,
    Position::Logical(position) => position.to_physical(scale_factor),
  }
}

fn tray_rect_size_to_physical(size: tauri::Size, scale_factor: f64) -> tauri::PhysicalSize<u32> {
  match size {
    tauri::Size::Physical(size) => size,
    tauri::Size::Logical(size) => size.to_physical(scale_factor),
  }
}

fn build_daily_value_menu_bar(app: &AppHandle, db_path: &PathBuf) -> Result<TrayIcon, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  let initial_title = String::new();

  let show_window = MenuItem::with_id(
    app,
    DAILY_VALUE_SHOW_WINDOW_MENU_ID,
    "Open Codex Pacer",
    true,
    None::<&str>,
  )
  .map_err(|error| error.to_string())?;
  let separator = PredefinedMenuItem::separator(app).map_err(|error| error.to_string())?;
  let quit = MenuItem::with_id(app, DAILY_VALUE_QUIT_MENU_ID, "Quit", true, None::<&str>)
    .map_err(|error| error.to_string())?;
  let menu = Menu::with_items(app, &[&show_window, &separator, &quit]).map_err(|error| error.to_string())?;

  let mut builder = TrayIconBuilder::with_id(DAILY_VALUE_TRAY_ID)
    .menu(&menu)
    .title(&initial_title)
    .tooltip(menu_bar_bucket_label(&settings.menu_bar_bucket))
    .show_menu_on_left_click(false)
    .on_menu_event(|app, event| {
      if event.id() == DAILY_VALUE_SHOW_WINDOW_MENU_ID {
        show_main_window(app);
      } else if event.id() == DAILY_VALUE_QUIT_MENU_ID {
        app.exit(0);
      }
    })
    .on_tray_icon_event(|tray, event| {
      if let TrayIconEvent::Click {
        position,
        button,
        button_state,
        rect,
        ..
      } = event
      {
        if button == MouseButton::Left && button_state == MouseButtonState::Up {
          if let Err(error) = toggle_menu_bar_popup(tray.app_handle(), rect, position) {
            log::warn!("Failed to toggle menu bar popup: {error}");
          }
        }
      }
    });

  if settings.show_menu_bar_logo {
    if let Some(icon) = app.default_window_icon().cloned() {
      builder = builder.icon(icon);
    }
  }
  #[cfg(target_os = "macos")]
  {
    builder = builder.icon_as_template(true);
  }

  let tray = builder.build(app).map_err(|error| error.to_string())?;
  tray
    .set_visible(menu_bar_has_visible_content(&settings))
    .map_err(|error| error.to_string())?;
  Ok(tray)
}

fn show_main_window(app: &AppHandle) {
  if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
  }
}

fn spawn_initial_scan(state: AppState) {
  tauri::async_runtime::spawn(async move {
    let _ = run_scan_if_idle(state, None);
  });
}

fn spawn_scheduler(state: AppState) {
  tauri::async_runtime::spawn(async move {
    loop {
      tokio::time::sleep(std::time::Duration::from_secs(30)).await;

      if state.scan_in_progress.load(Ordering::SeqCst) {
        continue;
      }

      let Ok(conn) = open_connection(&state.db_path) else {
        continue;
      };
      let Ok(settings) = get_sync_settings(&conn) else {
        continue;
      };
      if menu_bar_has_visible_content(&settings) {
        refresh_daily_value_menu_bar(&state);
      }
      if !settings.auto_scan_enabled {
        continue;
      }

      let should_scan = match settings.last_scan_completed_at.as_deref() {
        Some(last_completed_at) => {
          chrono::DateTime::parse_from_rfc3339(last_completed_at)
            .ok()
            .map(|last| {
              let elapsed = chrono::Utc::now().signed_duration_since(last.with_timezone(&chrono::Utc));
              elapsed.num_minutes() >= settings.auto_scan_interval_minutes.max(1)
            })
            .unwrap_or(true)
        }
        None => true,
      };

      if should_scan {
        let _ = run_scan_if_idle(state.clone(), settings.codex_home.clone());
      }
    }
  });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .plugin(
      tauri_plugin_log::Builder::default()
        .level(if cfg!(debug_assertions) {
          log::LevelFilter::Info
        } else {
          log::LevelFilter::Warn
        })
        .build(),
    )
    .on_window_event(|window, event| {
      if window.label() == MENU_BAR_POPUP_WINDOW_LABEL {
        match event {
          tauri::WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            let _ = window.hide();
          }
          tauri::WindowEvent::Focused(false) => {
            let _ = window.hide();
          }
          _ => {}
        }
        return;
      }

      if window.label() != MAIN_WINDOW_LABEL {
        return;
      }

      let tauri::WindowEvent::CloseRequested { api, .. } = event else {
        return;
      };

      let state = window.state::<AppState>();
      let should_hide_to_menu_bar = state
        .daily_value_tray
        .as_ref()
        .and_then(|_| open_connection(&state.db_path).ok())
        .and_then(|conn| get_sync_settings(&conn).ok())
        .map(|settings| menu_bar_has_visible_content(&settings))
        .unwrap_or(false);

      if should_hide_to_menu_bar {
        api.prevent_close();
        let _ = window.hide();
      }
    })
    .setup(|app| {
      let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("Failed to resolve app data dir: {error}"))?;
      fs::create_dir_all(&app_data_dir)
        .map_err(|error| format!("Failed to create app data dir {}: {error}", app_data_dir.display()))?;
      let db_path = app_data_dir.join("codex-counter.sqlite");

      let conn = open_connection(&db_path).map_err(|error| error.to_string())?;
      init_db(&conn).map_err(|error| error.to_string())?;
      seed_pricing_catalog(&conn).map_err(|error| error.to_string())?;
      recalculate_all_session_values(&conn).map_err(|error| error.to_string())?;

      let app_handle = app.app_handle();
      let daily_value_tray = match build_daily_value_menu_bar(&app_handle, &db_path) {
        Ok(tray) => Some(tray),
        Err(error) => {
          log::warn!("Failed to set up menu bar API value: {error}");
          None
        }
      };
      let state = AppState {
        db_path,
        scan_in_progress: Arc::new(AtomicBool::new(false)),
        daily_value_tray,
        live_rate_limits: Arc::new(Mutex::new(None)),
      };
      app.manage(state.clone());
      if let Ok(settings) = get_sync_settings(&conn) {
        apply_dock_icon_visibility(&app_handle, &settings, state.daily_value_tray.is_some());
      }
      if let Err(error) = build_menu_bar_popup_window(&app_handle) {
        log::warn!("Failed to set up menu bar popup window: {error}");
      }
      refresh_daily_value_menu_bar(&state);
      spawn_initial_scan(state.clone());
      spawn_scheduler(state);

      Ok(())
    })
    .invoke_handler(tauri::generate_handler![
      scanCodexUsage,
      getScanInProgress,
      refreshPricing,
      getOverview,
      listConversations,
      getLiveRateLimits,
      getMenuBarPopupSnapshot,
      loadDashboard,
      getConversationDetail,
      handleMenuBarPopupAction,
      setFastModeOverride,
      getSyncSettings,
      updateSyncSettings,
      getSubscriptionProfile,
      updateSubscriptionProfile,
    ])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
  use super::*;

  fn speed_test_settings() -> SyncSettings {
    SyncSettings {
      show_menu_bar_logo: true,
      menu_bar_speed_show_emoji: true,
      menu_bar_speed_fast_threshold_percent: 85,
      menu_bar_speed_slow_threshold_percent: 115,
      menu_bar_speed_healthy_emoji: "🟢".to_string(),
      menu_bar_speed_fast_emoji: "🔥".to_string(),
      menu_bar_speed_slow_emoji: "🐢".to_string(),
      ..SyncSettings::default()
    }
  }

  fn local_time(value: &str) -> DateTime<Local> {
    DateTime::parse_from_rfc3339(value)
      .expect("parse test timestamp")
      .with_timezone(&Local)
  }

  #[test]
  fn suggested_usage_speed_is_balanced_at_one() {
    let window = RateLimitWindowSnapshot {
      used_percent: 0,
      remaining_percent: 100,
      window_duration_mins: Some(300),
      resets_at: Some("2026-03-27T05:00:00+08:00".to_string()),
      window_start: Some("2026-03-27T00:00:00+08:00".to_string()),
    };

    let settings = speed_test_settings();
    let velocity =
      suggested_usage_velocity(&window, local_time("2026-03-27T00:00:00+08:00"), &settings)
        .expect("calculate velocity");

    assert_eq!(velocity.emoji, "🟢");
    assert_eq!(velocity.display_value, "100%");
  }

  #[test]
  fn suggested_usage_speed_caps_at_ten_plus() {
    let window = RateLimitWindowSnapshot {
      used_percent: 10,
      remaining_percent: 90,
      window_duration_mins: Some(10080),
      resets_at: Some("2026-03-27T00:00:00+08:00".to_string()),
      window_start: Some("2026-03-20T00:00:00+08:00".to_string()),
    };

    let settings = speed_test_settings();
    let velocity =
      suggested_usage_velocity(&window, local_time("2026-03-26T22:19:12+08:00"), &settings)
        .expect("calculate velocity");

    assert_eq!(velocity.emoji, "🐢");
    assert_eq!(velocity.display_value, "1000%+");
  }

  #[test]
  fn suggested_usage_speed_marks_fast_usage() {
    let window = RateLimitWindowSnapshot {
      used_percent: 80,
      remaining_percent: 20,
      window_duration_mins: Some(300),
      resets_at: Some("2026-03-27T05:00:00+08:00".to_string()),
      window_start: Some("2026-03-27T00:00:00+08:00".to_string()),
    };

    let settings = speed_test_settings();
    let velocity =
      suggested_usage_velocity(&window, local_time("2026-03-27T03:00:00+08:00"), &settings)
        .expect("calculate velocity");

    assert_eq!(velocity.emoji, "🔥");
    assert_eq!(velocity.display_value, "50%");
  }

  #[test]
  fn suggested_usage_speed_respects_custom_thresholds_and_hidden_emoji() {
    let window = RateLimitWindowSnapshot {
      used_percent: 30,
      remaining_percent: 70,
      window_duration_mins: Some(300),
      resets_at: Some("2026-03-27T05:00:00+08:00".to_string()),
      window_start: Some("2026-03-27T00:00:00+08:00".to_string()),
    };

    let settings = SyncSettings {
      menu_bar_speed_show_emoji: false,
      menu_bar_speed_fast_threshold_percent: 60,
      menu_bar_speed_slow_threshold_percent: 90,
      menu_bar_speed_healthy_emoji: "OK".to_string(),
      menu_bar_speed_fast_emoji: "FAST".to_string(),
      menu_bar_speed_slow_emoji: "SLOW".to_string(),
      ..SyncSettings::default()
    };

    let velocity =
      suggested_usage_velocity(&window, local_time("2026-03-27T03:00:00+08:00"), &settings)
        .expect("calculate velocity");

    assert_eq!(velocity.emoji, "");
    assert_eq!(velocity.rendered_value(), "175%");
  }

  #[test]
  fn menu_bar_title_joins_visible_segments_without_extra_spacing() {
    assert_eq!(menu_bar_title(None, None), None);
    assert_eq!(menu_bar_title(Some("$12.4"), None), Some("$12.4".to_string()));
    assert_eq!(menu_bar_title(None, Some("67%")), Some("67%".to_string()));
    assert_eq!(
      menu_bar_title(Some("$12.4"), Some("67%")),
      Some("$12.4 67%".to_string())
    );
  }

  #[test]
  fn menu_bar_can_show_live_metric_without_logo_or_api_value() {
    let settings = SyncSettings {
      show_menu_bar_logo: false,
      show_menu_bar_daily_api_value: false,
      show_menu_bar_live_quota_percent: true,
      menu_bar_live_quota_metric: "remaining_percent".to_string(),
      menu_bar_live_quota_bucket: "five_hour".to_string(),
      ..SyncSettings::default()
    };

    assert!(menu_bar_has_visible_content(&settings));
    assert_eq!(menu_bar_title(None, Some("42%")), Some("42%".to_string()));
  }

  #[test]
  fn menu_bar_can_hide_completely_when_all_display_content_is_disabled() {
    let settings = SyncSettings {
      show_menu_bar_logo: false,
      show_menu_bar_daily_api_value: false,
      show_menu_bar_live_quota_percent: false,
      ..SyncSettings::default()
    };

    assert!(!menu_bar_has_visible_content(&settings));
  }

  #[test]
  fn dock_icon_hides_only_when_enabled_and_menu_bar_has_content() {
    let enabled_with_menu_bar = SyncSettings {
      hide_dock_icon_when_menu_bar_visible: true,
      show_menu_bar_logo: true,
      show_menu_bar_daily_api_value: false,
      show_menu_bar_live_quota_percent: false,
      ..SyncSettings::default()
    };
    let enabled_without_menu_bar = SyncSettings {
      hide_dock_icon_when_menu_bar_visible: true,
      show_menu_bar_logo: false,
      show_menu_bar_daily_api_value: false,
      show_menu_bar_live_quota_percent: false,
      ..SyncSettings::default()
    };
    let disabled_with_menu_bar = SyncSettings {
      hide_dock_icon_when_menu_bar_visible: false,
      show_menu_bar_logo: true,
      show_menu_bar_daily_api_value: false,
      show_menu_bar_live_quota_percent: false,
      ..SyncSettings::default()
    };

    assert!(should_hide_dock_icon(&enabled_with_menu_bar));
    assert!(!should_hide_dock_icon(&enabled_without_menu_bar));
    assert!(!should_hide_dock_icon(&disabled_with_menu_bar));
  }

  #[test]
  fn tray_popup_position_keeps_physical_tray_coordinates_unscaled() {
    let position = tray_rect_position_to_physical(Position::Physical((1440.0, 12.0).into()), 2.0);
    let size = tray_rect_size_to_physical(tauri::Size::Physical((24u32, 24u32).into()), 2.0);

    assert_eq!(position, PhysicalPosition::new(1440, 12));
    assert_eq!(size.width, 24);
    assert_eq!(size.height, 24);
  }

  #[test]
  fn tray_popup_position_scales_logical_coordinates_once() {
    let position = tray_rect_position_to_physical(Position::Logical((720.0, 6.0).into()), 2.0);
    let size = tray_rect_size_to_physical(tauri::Size::Logical((12.0, 12.0).into()), 2.0);

    assert_eq!(position, PhysicalPosition::new(1440, 12));
    assert_eq!(size.width, 24);
    assert_eq!(size.height, 24);
  }
}

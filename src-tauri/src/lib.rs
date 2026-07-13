mod database;
mod importer;
mod models;
mod pricing;
mod queries;
mod rate_limits;
mod refresh;

#[global_allocator]
static GLOBAL_ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{
  atomic::{AtomicBool, AtomicU8, Ordering},
  Arc, Mutex,
};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Local, Utc};
use rusqlite::params;
use database::{
  canonical_subscription_currency, get_last_full_scan_completed, get_subscription_profile, get_sync_settings, init_db,
  insert_live_rate_limit_snapshot, load_latest_rate_limits, open_connection,
  save_subscription_profile, save_sync_settings,
};
use importer::{commit_prepared_scan, prepare_scan, recalculate_all_session_values, ScanKind};
use models::{
  ConversationDetail, ConversationFilters, ConversationPage, DashboardSnapshot,
  LiveRateLimitSnapshot, MenuBarPopupQuotaSnapshot, MenuBarPopupSnapshot,
  MenuBarPopupSuggestedSpeed, OverviewResponse, PricingCatalogEntry, RateLimitWindowSnapshot,
  ScanResult, SubscriptionProfile, SyncSettings,
};
use pricing::{
  apply_pricing_catalog_refresh, fetch_official_pricing_catalog, load_catalog,
  seed_pricing_catalog, OPENAI_API_PRICING_URL,
};
use queries::{
  get_conversation_detail, get_overview, get_quota_trend, get_window_api_value, list_conversations, load_dashboard_data,
};
use rate_limits::LiveRateLimitClient;
use tauri::{
  Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, Position, Rect, WebviewUrl, WebviewWindow,
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
const MENU_BAR_POPUP_INITIAL_HEIGHT: f64 = MENU_BAR_POPUP_MIN_HEIGHT;
const MENU_BAR_POPUP_MIN_HEIGHT: f64 = 260.0;
const MENU_BAR_POPUP_MAX_HEIGHT: f64 = 760.0;
const MENU_BAR_POPUP_OFFSET_Y: i32 = 8;
const TRAY_ICON_MIN_LOGICAL_HEIGHT: f64 = 16.0;
const TRAY_ICON_MAX_LOGICAL_HEIGHT: f64 = 40.0;
const FULL_SCAN_MAINTENANCE_INTERVAL_SECONDS: i64 = 24 * 60 * 60;
const PRICING_VALUE_RESOLUTION_REPAIR_KEY: &str = "pricing_value_resolution_v2";
const MENU_RENDER_IDLE: u8 = 0;
const MENU_RENDER_RUNNING: u8 = 1;
const MENU_RENDER_PENDING: u8 = 2;

#[derive(Clone)]
struct MenuBarPopupAnchor {
  rect: Rect,
  click_position: PhysicalPosition<f64>,
}

#[derive(Clone)]
struct AppState {
  app_handle: Option<AppHandle>,
  db_path: PathBuf,
  refresh: AppRefreshHandle,
  usage_mutations: refresh::UsageMutationCoordinator,
  menu_bar_render_state: Arc<AtomicU8>,
  daily_value_tray: Option<TrayIcon>,
  live_rate_limits: refresh::LiveQuotaCache,
  menu_bar_popup_visible: Arc<AtomicBool>,
  menu_bar_popup_anchor: Arc<Mutex<Option<MenuBarPopupAnchor>>>,
}

#[cfg(not(test))]
type AppRefreshHandle = refresh::RefreshCoordinatorHandle;
#[cfg(test)]
type AppRefreshHandle = Option<refresh::RefreshCoordinatorHandle>;

#[cfg(not(test))]
fn installed_refresh_handle(handle: refresh::RefreshCoordinatorHandle) -> AppRefreshHandle {
  handle
}

#[cfg(test)]
fn installed_refresh_handle(handle: refresh::RefreshCoordinatorHandle) -> AppRefreshHandle {
  Some(handle)
}

#[derive(Clone)]
struct AppTokenRefreshExecutor {
  db_path: PathBuf,
}

impl refresh::TokenRefreshExecutor for AppTokenRefreshExecutor {
  fn parse(
    &self,
    request: refresh::TokenExecutionRequest,
  ) -> Result<refresh::PreparedTokenRefresh, String> {
    let started_at = Utc::now();
    let scan_kind = effective_token_scan_kind(
      &self.db_path,
      request.request.kind,
      started_at,
    )?;
    let prepared_scan = prepare_scan(
      &self.db_path,
      request.request.codex_home,
      scan_kind,
    )?;
    Ok(refresh::PreparedTokenRefresh::new(
      request.generation,
      request.source_generation,
      started_at,
      prepared_scan,
    ))
  }

  fn commit(&self, prepared: refresh::PreparedTokenRefresh) -> Result<ScanResult, String> {
    commit_prepared_scan(prepared.prepared_scan)
  }
}

#[derive(Clone)]
struct AppLiveQuotaFetcher {
  db_path: PathBuf,
  live_cache: refresh::LiveQuotaCache,
  client: Arc<LiveRateLimitClient>,
}

impl refresh::LiveQuotaFetcher for AppLiveQuotaFetcher {
  fn fetch(&self, timeout: Duration) -> Result<LiveRateLimitSnapshot, String> {
    self.client.query(timeout)
  }

  fn fallback(&self) -> Option<LiveRateLimitSnapshot> {
    load_display_live_rate_limit_fallback(&self.db_path, &self.live_cache)
  }
}

#[derive(Clone)]
struct AppLiveQuotaPersister {
  db_path: PathBuf,
}

impl refresh::LiveQuotaPersister for AppLiveQuotaPersister {
  fn persist(&self, snapshot: &LiveRateLimitSnapshot) -> Result<(), String> {
    let conn = open_connection(&self.db_path).map_err(|error| error.to_string())?;
    insert_live_rate_limit_snapshot(&conn, snapshot)
      .map(|_| ())
      .map_err(|error| error.to_string())
  }
}

struct AppEpochMaintenanceExecutor {
  db_path: PathBuf,
  connection: Mutex<Option<rusqlite::Connection>>,
  #[cfg(test)]
  open_count: AtomicUsize,
}

impl AppEpochMaintenanceExecutor {
  fn new(db_path: PathBuf) -> Self {
    Self {
      db_path,
      connection: Mutex::new(None),
      #[cfg(test)]
      open_count: AtomicUsize::new(0),
    }
  }

  #[cfg(test)]
  fn open_count_for_test(&self) -> usize {
    self.open_count.load(Ordering::Acquire)
  }

  #[cfg(test)]
  fn connection_is_open_for_test(&self) -> bool {
    self
      .connection
      .lock()
      .unwrap_or_else(std::sync::PoisonError::into_inner)
      .is_some()
  }
}

impl refresh::EpochMaintenanceExecutor for AppEpochMaintenanceExecutor {
  fn run_batch(
    &self,
    limit: usize,
    cancellation: Arc<AtomicBool>,
  ) -> Result<refresh::EpochMaintenanceBatch, String> {
    if cancellation.load(Ordering::Acquire) {
      return Ok(refresh::EpochMaintenanceBatch::Cancelled);
    }
    let mut connection = self
      .connection
      .lock()
      .unwrap_or_else(std::sync::PoisonError::into_inner);
    if connection.is_none() {
      let opened = database::open_epoch_maintenance_connection(&self.db_path)
        .map_err(|error| error.to_string())?;
      #[cfg(test)]
      self.open_count.fetch_add(1, Ordering::AcqRel);
      *connection = Some(opened);
    }
    let progress = database::backfill_epoch_batch_cancellable(
      connection
        .as_ref()
        .expect("epoch maintenance connection was initialized"),
      limit,
      cancellation.as_ref(),
    )
    .map_err(|error| error.to_string())?;
    Ok(match progress {
      Some(progress) => {
        let result = refresh::EpochMaintenanceBatch::Progress {
          processed_rows: progress
            .usage_rows_updated
            .saturating_add(progress.quota_rows_updated),
          complete: progress.complete,
        };
        if progress.complete {
          *connection = None;
        }
        result
      }
      None => refresh::EpochMaintenanceBatch::Cancelled,
    })
  }
}

fn configure_epoch_maintenance(
  dependencies: refresh::RefreshRuntimeDependencies,
  db_path: PathBuf,
  pending: bool,
) -> refresh::RefreshRuntimeDependencies {
  if pending {
    dependencies.with_epoch_maintenance(Arc::new(AppEpochMaintenanceExecutor::new(db_path)))
  } else {
    dependencies
  }
}

#[derive(Clone)]
struct TauriRefreshEventSink {
  app_handle: AppHandle,
}

impl refresh::RefreshEventSink for TauriRefreshEventSink {
  fn publish_invalidation(&self, _: refresh::DisplayInvalidation) {
    let Some(state) = self.app_handle.try_state::<AppState>() else {
      return;
    };
    let popup_visible = state.menu_bar_popup_visible.load(Ordering::Acquire);
    refresh_daily_value_menu_bar(state.inner());
    if popup_visible {
      if let Some(window) = self.app_handle.get_webview_window(MENU_BAR_POPUP_WINDOW_LABEL) {
        let _ = window.emit(MENU_BAR_POPUP_REFRESH_EVENT, ());
      }
    }
  }

  fn publish_completion(&self, value: refresh::RefreshCompletedEvent) {
    if let Err(error) = self
      .app_handle
      .emit("codex-counter://refresh-completed", value)
    {
      log::warn!("Failed to emit refresh completion: {error}");
    }
  }
}

#[cfg(not(test))]
fn refresh_handle(state: &AppState) -> Result<&refresh::RefreshCoordinatorHandle, String> {
  Ok(&state.refresh)
}

#[cfg(test)]
fn refresh_handle(state: &AppState) -> Result<&refresh::RefreshCoordinatorHandle, String> {
  state
    .refresh
    .as_ref()
    .ok_or_else(|| "Refresh coordinator is unavailable.".to_string())
}

fn refresh_error_message(error: refresh::RefreshError) -> String {
  format!("{error:?}")
}

fn run_manual_scan_with_coordinator(
  refresh: &refresh::RefreshCoordinatorHandle,
  codex_home: Option<String>,
) -> Result<ScanResult, String> {
  let ticket = refresh
    .request_manual_token(codex_home)
    .map_err(refresh_error_message)?;
  ticket
    .wait()
    .map(|result| result.as_ref().clone())
    .map_err(refresh_error_message)
}

fn get_passive_live_rate_limits(
  cache: &refresh::LiveQuotaCache,
) -> Result<LiveRateLimitSnapshot, String> {
  cache
    .rate_limits()
    .map(|snapshot| snapshot.as_ref().clone())
    .ok_or_else(|| "Live rate limits are unavailable.".to_string())
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
async fn scanCodexUsage(
  state: State<'_, AppState>,
  codex_home: Option<String>,
) -> Result<ScanResult, String> {
  let refresh = refresh_handle(state.inner())?.clone();
  tauri::async_runtime::spawn_blocking(move || {
    run_manual_scan_with_coordinator(&refresh, codex_home)
  })
  .await
  .map_err(|error| format!("Failed to join manual refresh: {error}"))?
}

#[allow(non_snake_case)]
#[tauri::command]
fn getScanInProgress(state: State<'_, AppState>) -> bool {
  refresh_handle(state.inner())
    .map(|refresh| {
      let status = refresh.status();
      status.token.running || status.token.pending
    })
    .unwrap_or(false)
}

#[allow(non_snake_case)]
#[tauri::command]
fn getRefreshStatus(state: State<'_, AppState>) -> Result<refresh::RefreshStatus, String> {
  Ok(refresh_handle(state.inner())?.status())
}

#[allow(non_snake_case)]
#[tauri::command]
fn refreshBackgroundData(state: State<'_, AppState>) -> Result<Option<ScanResult>, String> {
  match refresh_handle(state.inner())?.wake() {
    Ok(()) | Err(refresh::RefreshError::Busy) => Ok(None),
    Err(error) => Err(refresh_error_message(error)),
  }
}

#[allow(non_snake_case)]
#[tauri::command]
fn refreshPricing(state: State<'_, AppState>) -> Result<Vec<PricingCatalogEntry>, String> {
  let official_entries = match fetch_official_pricing_catalog() {
    Ok(entries) => Some(entries),
    Err(error) => {
      log::warn!(
        "Failed to refresh OpenAI API pricing from {OPENAI_API_PRICING_URL}: {error}; using bundled fallback pricing."
      );
      None
    }
  };
  let catalog = refresh_pricing_catalog_for_state(state.inner(), official_entries.as_deref())?;
  refresh_daily_value_menu_bar(state.inner());
  Ok(catalog)
}

fn refresh_pricing_catalog_for_state(
  state: &AppState,
  official_entries: Option<&[PricingCatalogEntry]>,
) -> Result<Vec<PricingCatalogEntry>, String> {
  refresh_pricing_catalog_with_runner(
    &state.db_path,
    official_entries,
    |priority, mutation| state.usage_mutations.run(priority, mutation).value,
  )
}

fn refresh_pricing_catalog_with_runner(
  db_path: &Path,
  official_entries: Option<&[PricingCatalogEntry]>,
  run: impl FnOnce(
    refresh::MutationPriority,
    &mut dyn FnMut() -> Result<Vec<PricingCatalogEntry>, String>,
  ) -> Result<Vec<PricingCatalogEntry>, String>,
) -> Result<Vec<PricingCatalogEntry>, String> {
  let mut mutation = || {
    let mut conn = open_connection(db_path).map_err(|error| error.to_string())?;
    refresh_pricing_catalog_atomically(&mut conn, official_entries)
  };
  run(refresh::MutationPriority::Pricing, &mut mutation)
}

fn refresh_pricing_catalog_atomically(
  conn: &mut rusqlite::Connection,
  official_entries: Option<&[PricingCatalogEntry]>,
) -> Result<Vec<PricingCatalogEntry>, String> {
  let transaction = conn
    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
    .map_err(|error| error.to_string())?;
  apply_pricing_catalog_refresh(&transaction, official_entries)?;
  recalculate_all_session_values(&transaction).map_err(|error| error.to_string())?;
  mark_pricing_value_resolution_repair_complete(&transaction)
    .map_err(|error| error.to_string())?;
  let catalog = load_catalog(&transaction).map_err(|error| error.to_string())?;
  transaction.commit().map_err(|error| error.to_string())?;
  Ok(catalog)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn getOverview(
  state: State<'_, AppState>,
  bucket: Option<String>,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  live_window_offset: Option<i64>,
) -> Result<OverviewResponse, String> {
  let live_rate_limits = maybe_live_rate_limits_for_bucket(state.inner(), bucket.as_deref(), live_window_offset)?;
  get_overview(
    &state.db_path,
    bucket,
    anchor,
    custom_start,
    custom_end,
    live_rate_limits,
    live_window_offset,
  )
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn listConversations(
  state: State<'_, AppState>,
  filters: Option<ConversationFilters>,
) -> Result<ConversationPage, String> {
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
  get_passive_live_rate_limits(&state.live_rate_limits)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
async fn getMenuBarPopupSnapshot(
  state: State<'_, AppState>,
  force_refresh: Option<bool>,
) -> Result<MenuBarPopupSnapshot, String> {
  let state = state.inner().clone();
  tauri::async_runtime::spawn_blocking(move || {
    if force_refresh.unwrap_or(false) {
      refresh_popup_data(&state)?;
    }
    build_passive_menu_bar_popup_snapshot(&state.db_path, &state.live_rate_limits)
  })
  .await
  .map_err(|error| format!("Failed to join popup refresh: {error}"))?
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn resizeMenuBarPopup(app: AppHandle, state: State<'_, AppState>, height: f64) -> Result<bool, String> {
  let Some(window) = app.get_webview_window(MENU_BAR_POPUP_WINDOW_LABEL) else {
    return Ok(false);
  };
  let (height, position) = match latest_menu_bar_popup_anchor(state.inner()) {
    Some(anchor) => menu_bar_popup_geometry(&window, anchor.rect, anchor.click_position, height)?,
    None => (height.clamp(MENU_BAR_POPUP_MIN_HEIGHT, MENU_BAR_POPUP_MAX_HEIGHT), None),
  };
  window
    .set_size(tauri::Size::Logical(tauri::LogicalSize::new(
      MENU_BAR_POPUP_WIDTH,
      height,
    )))
    .map_err(|error| error.to_string())?;
  if let Some(position) = position {
    window
      .set_position(Position::Physical(position))
      .map_err(|error| error.to_string())?;
  }
  Ok(true)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
async fn loadDashboard(
  state: State<'_, AppState>,
  bucket: Option<String>,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  search: Option<String>,
  live_window_offset: Option<i64>,
) -> Result<DashboardSnapshot, String> {
  let state = state.inner().clone();
  tauri::async_runtime::spawn_blocking(move || {
    let normalized_bucket = bucket.clone().unwrap_or_else(|| "seven_day".to_string());
    let live_rate_limits =
      maybe_live_rate_limits_for_bucket(&state, Some(&normalized_bucket), live_window_offset)?;
    let snapshot = load_dashboard_data(
      &state.db_path,
      Some(normalized_bucket.clone()),
      anchor.clone(),
      custom_start.clone(),
      custom_end.clone(),
      search,
      live_rate_limits.clone(),
      live_window_offset,
    )?;
    let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
    let sync_settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;

    Ok(DashboardSnapshot {
      overview: snapshot.overview,
      conversation_page: snapshot.conversation_page,
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
  turn_cursor: Option<usize>,
) -> Result<ConversationDetail, String> {
  get_conversation_detail(&state.db_path, &root_session_id, turn_cursor)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
async fn handleMenuBarPopupAction(
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
      let refresh_state = state.inner().clone();
      tauri::async_runtime::spawn_blocking(move || refresh_popup_data(&refresh_state))
        .await
        .map_err(|error| format!("Failed to join popup refresh: {error}"))??;
      refresh_daily_value_menu_bar(state.inner());
      Ok(true)
    }
    _ => Err(format!("Unsupported popup action: {action}")),
  }
}

#[allow(non_snake_case)]
#[tauri::command]
fn getSyncSettings(state: State<'_, AppState>) -> Result<SyncSettings, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  get_sync_settings(&conn).map_err(|error| error.to_string())
}

fn save_normalized_sync_settings(
  conn: &rusqlite::Connection,
  payload: SyncSettings,
) -> rusqlite::Result<SyncSettings> {
  let auto_scan_interval_minutes = payload.auto_scan_interval_minutes.max(1);
  let updated = SyncSettings {
    codex_home: payload.codex_home,
    auto_scan_enabled: payload.auto_scan_enabled,
    auto_scan_interval_minutes,
    live_quota_refresh_interval_seconds: unified_refresh_interval_seconds(auto_scan_interval_minutes),
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
    last_scan_started_at: payload.last_scan_started_at,
    last_scan_completed_at: payload.last_scan_completed_at,
    updated_at: payload.updated_at,
  };
  save_sync_settings(conn, &updated)
}

fn refresh_config_from_saved_settings(
  settings: &SyncSettings,
  live_last_success_at: Option<&str>,
) -> refresh::RefreshConfig {
  refresh::RefreshConfig {
    auto_scan_enabled: settings.auto_scan_enabled,
    interval: Duration::from_secs(
      unified_refresh_interval_seconds(settings.auto_scan_interval_minutes) as u64,
    ),
    codex_home: settings.codex_home.clone(),
    token_last_success_wall: refresh::parse_persisted_success_wall(
      settings.last_scan_completed_at.as_deref(),
    ),
    live_last_success_wall: refresh::parse_persisted_success_wall(live_last_success_at),
  }
}

fn update_coordinator_from_saved_settings(
  coordinator: &refresh::RefreshCoordinatorHandle,
  settings: &SyncSettings,
) -> Result<(), String> {
  let live_last_success_at = coordinator.status().live.last_success_at;
  coordinator
    .update_settings(refresh_config_from_saved_settings(
      settings,
      live_last_success_at.as_deref(),
    ))
    .map_err(refresh_error_message)
}

#[allow(non_snake_case)]
#[tauri::command(rename_all = "camelCase")]
fn updateSyncSettings(
  app: AppHandle,
  state: State<'_, AppState>,
  payload: SyncSettings,
) -> Result<SyncSettings, String> {
  let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
  let saved = save_normalized_sync_settings(&conn, payload).map_err(|error| error.to_string())?;
  drop(conn);
  update_coordinator_from_saved_settings(refresh_handle(state.inner())?, &saved)?;
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

fn prepare_app_database(db_path: &Path) -> Result<(), String> {
  let mut conn = open_connection(db_path).map_err(|error| error.to_string())?;
  init_db(&conn).map_err(|error| error.to_string())?;
  let transaction = conn
    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
    .map_err(|error| error.to_string())?;
  let resolver_repair_pending =
    pricing_value_resolution_repair_pending(&transaction).map_err(|error| error.to_string())?;
  let pricing_signature_before =
    load_pricing_value_signature(&transaction).map_err(|error| error.to_string())?;
  seed_pricing_catalog(&transaction).map_err(|error| error.to_string())?;
  let pricing_signature_after =
    load_pricing_value_signature(&transaction).map_err(|error| error.to_string())?;
  if resolver_repair_pending || pricing_signature_before != pricing_signature_after {
    recalculate_all_session_values(&transaction).map_err(|error| error.to_string())?;
    mark_pricing_value_resolution_repair_complete(&transaction)
      .map_err(|error| error.to_string())?;
  }
  transaction.commit().map_err(|error| error.to_string())?;
  Ok(())
}

fn pricing_value_resolution_repair_pending(conn: &rusqlite::Connection) -> rusqlite::Result<bool> {
  let completed: i64 = conn.query_row(
    "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
    params![PRICING_VALUE_RESOLUTION_REPAIR_KEY],
    |row| row.get(0),
  )?;
  Ok(completed == 0)
}

fn mark_pricing_value_resolution_repair_complete(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
  conn.execute(
    "
    INSERT INTO data_repairs (repair_key, completed_at)
    VALUES (?1, ?2)
    ON CONFLICT(repair_key) DO UPDATE SET completed_at = excluded.completed_at
    ",
    params![PRICING_VALUE_RESOLUTION_REPAIR_KEY, database::now_utc_string()],
  )?;
  Ok(())
}

#[derive(Debug, PartialEq)]
struct PricingValueSignatureEntry {
  model_id: String,
  input_price_per_million: f64,
  cached_input_price_per_million: f64,
  output_price_per_million: f64,
  effective_model_id: String,
}

fn load_pricing_value_signature(conn: &rusqlite::Connection) -> rusqlite::Result<Vec<PricingValueSignatureEntry>> {
  let mut stmt = conn.prepare(
    "
    SELECT model_id, input_price_per_million, cached_input_price_per_million,
           output_price_per_million, effective_model_id
    FROM pricing_catalog
    ORDER BY model_id
    ",
  )?;
  let rows = stmt.query_map([], |row| {
    Ok(PricingValueSignatureEntry {
      model_id: row.get(0)?,
      input_price_per_million: row.get(1)?,
      cached_input_price_per_million: row.get(2)?,
      output_price_per_million: row.get(3)?,
      effective_model_id: row.get(4)?,
    })
  })?;

  rows.collect()
}

fn claim_menu_bar_render(state: &AtomicU8) -> bool {
  claim_menu_bar_render_with_hook(state, |_| {})
}

fn claim_menu_bar_render_with_hook(
  state: &AtomicU8,
  mut before_transition: impl FnMut(u8),
) -> bool {
  loop {
    let current = state.load(Ordering::Acquire);
    before_transition(current);
    match current {
      MENU_RENDER_IDLE => {
        if state
          .compare_exchange(
            MENU_RENDER_IDLE,
            MENU_RENDER_RUNNING,
            Ordering::AcqRel,
            Ordering::Acquire,
          )
          .is_ok()
        {
          return true;
        }
      }
      MENU_RENDER_RUNNING => {
        if state
          .compare_exchange(
            MENU_RENDER_RUNNING,
            MENU_RENDER_PENDING,
            Ordering::AcqRel,
            Ordering::Acquire,
          )
          .is_ok()
        {
          return false;
        }
      }
      MENU_RENDER_PENDING => return false,
      _ => {
        state.store(MENU_RENDER_PENDING, Ordering::Release);
        return false;
      }
    }
  }
}

fn complete_menu_bar_render(state: &AtomicU8) -> bool {
  state.swap(MENU_RENDER_IDLE, Ordering::AcqRel) == MENU_RENDER_PENDING
}

fn refresh_daily_value_menu_bar(state: &AppState) {
  let Some(app_handle) = state.app_handle.as_ref().cloned() else {
    if let Err(error) = update_daily_value_menu_bar(state) {
      log::warn!("Failed to update menu bar display: {error}");
    }
    return;
  };

  if !claim_menu_bar_render(&state.menu_bar_render_state) {
    return;
  }
  let state = state.clone();
  let scheduled_state = state.clone();
  if let Err(error) = app_handle.run_on_main_thread(move || {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| update_daily_value_menu_bar(&state)));
    let pending = complete_menu_bar_render(&state.menu_bar_render_state);
    match result {
      Ok(Ok(())) => {}
      Ok(Err(error)) => log::warn!("Failed to update menu bar display: {error}"),
      Err(_) => log::warn!("Menu bar display update panicked."),
    }
    if pending {
      refresh_daily_value_menu_bar(&state);
    }
  }) {
    let pending = complete_menu_bar_render(&scheduled_state.menu_bar_render_state);
    log::warn!("Failed to schedule menu bar display update: {error}");
    if pending {
      refresh_daily_value_menu_bar(&scheduled_state);
    }
  }
}

fn update_daily_value_menu_bar(state: &AppState) -> Result<(), String> {
  let result = (|| {
    let conn = open_connection(&state.db_path).map_err(|error| error.to_string())?;
    let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
    render_daily_value_menu_bar(state, &settings)
  })();
  importer::release_unused_process_memory();
  result
}

fn render_daily_value_menu_bar(
  state: &AppState,
  settings: &SyncSettings,
) -> Result<(), String> {
  let Some(tray) = state.daily_value_tray.as_ref() else {
    return Ok(());
  };

  if !menu_bar_has_visible_content(settings) {
    tray.set_visible(false).map_err(|error| error.to_string())?;
    return Ok(());
  }

  apply_menu_bar_icon(tray, settings.show_menu_bar_logo)?;
  let live_rate_limits = state.live_rate_limits.rate_limits();
  let (api_value_title, live_metric_title) = current_menu_bar_title_parts(
    state,
    settings,
    live_rate_limits.as_deref(),
  )?;
  match menu_bar_title(api_value_title.as_deref(), live_metric_title.as_deref()) {
    Some(title) => tray.set_title(Some(&title)).map_err(|error| error.to_string())?,
    None => tray
      .set_title(None::<String>)
      .map_err(|error| error.to_string())?,
  }
  tray
    .set_tooltip(Some(menu_bar_tooltip(
      settings,
      api_value_title.as_deref(),
      live_rate_limits.as_deref(),
    )?))
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
  cached_live_rate_limits: Option<&LiveRateLimitSnapshot>,
) -> Result<(Option<String>, Option<String>), String> {
  let configured_bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let anchor = Local::now().format("%Y-%m-%d").to_string();
  let live_rate_limits = if settings.show_menu_bar_live_quota_percent
    || (settings.show_menu_bar_daily_api_value && bucket_uses_live_rate_limits(&configured_bucket))
  {
    cached_live_rate_limits
  } else {
    None
  };
  let bucket = effective_menu_bar_api_bucket(&configured_bucket, live_rate_limits);
  let api_value_title = if settings.show_menu_bar_daily_api_value {
    let api_value_usd = get_window_api_value(
      &state.db_path,
      bucket.clone(),
      if bucket_uses_anchor(&bucket) { Some(anchor) } else { None },
      None,
      None,
      live_rate_limits.cloned(),
      None,
    )?;
    Some(format!("${:.1}", api_value_usd))
  } else {
    None
  };
  let live_metric_title = if settings.show_menu_bar_live_quota_percent {
    menu_bar_live_quota_snapshot(
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

fn effective_menu_bar_api_bucket(
  configured_bucket: &str,
  live_rate_limits: Option<&LiveRateLimitSnapshot>,
) -> String {
  if configured_bucket == "five_hour"
    && live_rate_limits.is_some_and(|snapshot| snapshot.primary.is_none() && snapshot.secondary.is_some())
  {
    "seven_day".to_string()
  } else {
    configured_bucket.to_string()
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
  cached_live_rate_limits: Option<&LiveRateLimitSnapshot>,
) -> Result<String, String> {
  let configured_bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let bucket = effective_menu_bar_api_bucket(&configured_bucket, cached_live_rate_limits);
  let mut fragments = Vec::new();
  if let Some(title) = api_value_title.filter(|value| !value.trim().is_empty()) {
    fragments.push(format!("{}累计 API 价值：{title}", menu_bar_bucket_label(&bucket)));
  }
  if settings.show_menu_bar_live_quota_percent {
    if let Some(snapshot) = cached_live_rate_limits {
      if let Some(fragment) = menu_bar_live_quota_tooltip(
        snapshot,
        settings,
        &settings.menu_bar_live_quota_bucket,
        &settings.menu_bar_live_quota_metric,
        Local::now(),
      ) {
        fragments.push(fragment);
      }
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
  settings: &SyncSettings,
  bucket: &str,
  metric: &str,
  existing_snapshot: Option<&LiveRateLimitSnapshot>,
  now: DateTime<Local>,
) -> Result<Option<String>, String> {
  let Some(snapshot) = existing_snapshot else {
    return Ok(None);
  };
  Ok(menu_bar_live_quota_title(snapshot, settings, bucket, metric, now))
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
  Ok(state
    .live_rate_limits
    .rate_limits()
    .map(|snapshot| snapshot.as_ref().clone()))
}

#[derive(Clone)]
struct PersistedRateLimitWindow {
  row_id: i64,
  source_kind: String,
  source_session_id: String,
  snapshot: RateLimitWindowSnapshot,
  fetched_at: String,
  limit_id: Option<String>,
  limit_name: Option<String>,
  plan_type: Option<String>,
}

fn load_latest_persisted_rate_limit_window(
  conn: &rusqlite::Connection,
  bucket: &str,
  source_kind: Option<&str>,
) -> Result<Option<PersistedRateLimitWindow>, String> {
  let mut stmt = conn
    .prepare(
      "
      SELECT id, source_kind, source_session_id, sample_timestamp, limit_id, limit_name, plan_type,
             window_start, resets_at, used_percent, remaining_percent
      FROM rate_limit_samples
      WHERE bucket = ?1 AND (?2 IS NULL OR source_kind = ?2)
      ORDER BY julianday(sample_timestamp) DESC, id DESC
      LIMIT 1
      ",
    )
    .map_err(|error| error.to_string())?;

  let mut rows = stmt
    .query(params![bucket, source_kind])
    .map_err(|error| error.to_string())?;
  let Some(row) = rows.next().map_err(|error| error.to_string())? else {
    return Ok(None);
  };

  let row_id = row.get::<_, i64>(0).map_err(|error| error.to_string())?;
  let source_kind = row.get::<_, String>(1).map_err(|error| error.to_string())?;
  let source_session_id = row.get::<_, String>(2).map_err(|error| error.to_string())?;
  let sample_timestamp = row.get::<_, String>(3).map_err(|error| error.to_string())?;
  let limit_id = row
    .get::<_, String>(4)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let limit_name = row
    .get::<_, String>(5)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let plan_type = row
    .get::<_, String>(6)
    .ok()
    .and_then(|value| (!value.is_empty()).then_some(value));
  let window_start = row.get::<_, String>(7).map_err(|error| error.to_string())?;
  let resets_at = row.get::<_, String>(8).map_err(|error| error.to_string())?;
  let used_percent = row.get::<_, i64>(9).map_err(|error| error.to_string())?;
  let remaining_percent = row.get::<_, i64>(10).map_err(|error| error.to_string())?;

  let window_duration_mins = match (
    parse_rfc3339_local(&window_start),
    parse_rfc3339_local(&resets_at),
  ) {
    (Some(start), Some(end)) => Some(end.signed_duration_since(start).num_minutes().max(0)),
    _ => None,
  };

  Ok(Some(PersistedRateLimitWindow {
    row_id,
    source_kind,
    source_session_id,
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

fn load_persisted_live_rate_limits_from_connection(
  conn: &rusqlite::Connection,
  source_kind: Option<&str>,
) -> Option<LiveRateLimitSnapshot> {
  if let Ok(Some(snapshot)) = load_latest_rate_limits(conn, source_kind) {
    return Some(normalize_live_rate_limit_snapshot(snapshot));
  }
  let mut primary = load_latest_persisted_rate_limit_window(&conn, "five_hour", source_kind)
    .ok()
    .flatten();
  let mut secondary = load_latest_persisted_rate_limit_window(&conn, "seven_day", source_kind)
    .ok()
    .flatten();
  let newest = match (primary.as_ref(), secondary.as_ref()) {
    (Some(primary), Some(secondary)) => {
      if persisted_window_is_newer(secondary, primary) { secondary } else { primary }
    }
    (Some(primary), None) => primary,
    (None, Some(secondary)) => secondary,
    (None, None) => return None,
  };
  let keep_primary = primary
    .as_ref()
    .is_some_and(|window| same_persisted_sample(window, newest));
  let keep_secondary = secondary
    .as_ref()
    .is_some_and(|window| same_persisted_sample(window, newest));

  if !keep_primary {
    primary = None;
  }
  if !keep_secondary {
    secondary = None;
  }

  let fetched_at = primary
    .as_ref()
    .map(|window| window.fetched_at.clone())
    .or_else(|| secondary.as_ref().map(|window| window.fetched_at.clone()))?;

  Some(normalize_live_rate_limit_snapshot(LiveRateLimitSnapshot {
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
  }))
}

fn normalize_live_rate_limit_snapshot(
  mut snapshot: LiveRateLimitSnapshot,
) -> LiveRateLimitSnapshot {
  if snapshot.secondary.is_none()
    && snapshot
      .primary
      .as_ref()
      .is_some_and(|window| window.window_duration_mins == Some(7 * 24 * 60))
  {
    snapshot.secondary = snapshot.primary.take();
  }
  snapshot
}

fn load_preferred_persisted_live_rate_limits(
  conn: &rusqlite::Connection,
) -> Option<LiveRateLimitSnapshot> {
  load_persisted_live_rate_limits_from_connection(conn, Some("live"))
    .or_else(|| load_persisted_live_rate_limits_from_connection(conn, Some("session")))
}

fn persisted_window_is_newer(
  candidate: &PersistedRateLimitWindow,
  current: &PersistedRateLimitWindow,
) -> bool {
  match (
    DateTime::parse_from_rfc3339(&candidate.fetched_at).ok(),
    DateTime::parse_from_rfc3339(&current.fetched_at).ok(),
  ) {
    (Some(candidate_time), Some(current_time)) if candidate_time != current_time => {
      candidate_time > current_time
    }
    (Some(_), Some(_)) => candidate.row_id > current.row_id,
    (Some(_), None) => true,
    (None, Some(_)) => false,
    (None, None) if candidate.fetched_at != current.fetched_at => {
      candidate.fetched_at > current.fetched_at
    }
    (None, None) => candidate.row_id > current.row_id,
  }
}

fn same_persisted_sample(
  left: &PersistedRateLimitWindow,
  right: &PersistedRateLimitWindow,
) -> bool {
  left.source_kind == right.source_kind
    && left.source_session_id == right.source_session_id
    && left.fetched_at == right.fetched_at
    && left.limit_id == right.limit_id
    && left.limit_name == right.limit_name
    && left.plan_type == right.plan_type
}

fn load_display_live_rate_limit_fallback(
  db_path: &Path,
  live_cache: &refresh::LiveQuotaCache,
) -> Option<LiveRateLimitSnapshot> {
  let memory = live_cache
    .rate_limits()
    .map(|snapshot| normalize_live_rate_limit_snapshot(snapshot.as_ref().clone()));
  let memory_is_live = live_cache.state().last_live_success_at.is_some();
  let Ok(conn) = open_connection(db_path) else {
    return memory;
  };
  let persisted_live = load_persisted_live_rate_limits_from_connection(&conn, Some("live"));
  if memory_is_live {
    return newest_live_rate_limit_snapshot([memory, persisted_live]);
  }
  if persisted_live.is_some() {
    return persisted_live;
  }
  memory.or_else(|| load_persisted_live_rate_limits_from_connection(&conn, Some("session")))
}

fn newest_live_rate_limit_snapshot(
  snapshots: impl IntoIterator<Item = Option<LiveRateLimitSnapshot>>,
) -> Option<LiveRateLimitSnapshot> {
  snapshots.into_iter().flatten().fold(None, |newest, candidate| {
    let Some(current) = newest else {
      return Some(candidate);
    };
    if live_snapshot_is_newer(&candidate, &current) {
      Some(candidate)
    } else {
      Some(current)
    }
  })
}

fn live_snapshot_is_newer(
  candidate: &LiveRateLimitSnapshot,
  current: &LiveRateLimitSnapshot,
) -> bool {
  match (
    DateTime::parse_from_rfc3339(&candidate.fetched_at).ok(),
    DateTime::parse_from_rfc3339(&current.fetched_at).ok(),
  ) {
    (Some(candidate), Some(current)) => candidate > current,
    (Some(_), None) => true,
    (None, Some(_)) => false,
    (None, None) => candidate.fetched_at > current.fetched_at,
  }
}

fn build_passive_menu_bar_popup_snapshot(
  db_path: &Path,
  live_cache: &refresh::LiveQuotaCache,
) -> Result<MenuBarPopupSnapshot, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
  drop(conn);
  let live_rate_limits = live_cache
    .rate_limits()
    .map(|snapshot| normalize_live_rate_limit_snapshot(snapshot.as_ref().clone()));
  let configured_bucket = normalize_menu_bar_bucket(&settings.menu_bar_bucket);
  let selected_bucket = effective_menu_bar_api_bucket(&configured_bucket, live_rate_limits.as_ref());
  let anchor = bucket_uses_anchor(&selected_bucket).then(|| Local::now().format("%Y-%m-%d").to_string());
  let overview = get_overview(
    db_path,
    Some(selected_bucket.clone()),
    anchor,
    None,
    None,
    if bucket_uses_live_rate_limits(&selected_bucket) {
      live_rate_limits.clone()
    } else {
      None
    },
    None,
  )
  .ok();
  let quota_trend_7d = if selected_bucket == "seven_day" {
    overview
      .as_ref()
      .map(|value| value.quota_trend.clone())
      .unwrap_or_default()
  } else {
    get_quota_trend(db_path, "seven_day".to_string(), live_rate_limits.clone()).unwrap_or_default()
  };

  Ok(MenuBarPopupSnapshot {
    fetched_at: Local::now().to_rfc3339(),
    refresh_interval_seconds: unified_refresh_interval_seconds(settings.auto_scan_interval_minutes),
    selected_bucket,
    quota_5h: live_rate_limits
      .as_ref()
      .and_then(|snapshot| snapshot.primary.as_ref().map(menu_bar_popup_quota_snapshot)),
    quota_7d: live_rate_limits
      .as_ref()
      .and_then(|snapshot| snapshot.secondary.as_ref().map(menu_bar_popup_quota_snapshot)),
    quota_trend_7d,
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

fn refresh_popup_data(state: &AppState) -> Result<(), String> {
  let coordinator = refresh_handle(state)?;
  let token_ticket = coordinator.request_manual_token(None);
  let live_ticket = coordinator.request_manual_live();

  let token_result = token_ticket.and_then(|ticket| ticket.wait());
  let live_result = live_ticket.and_then(|ticket| ticket.wait());
  match (token_result, live_result) {
    (Ok(_), Ok(_)) => Ok(()),
    (token, live) => Err(format!(
      "Popup refresh failed (token: {:?}, live: {:?})",
      token.err(),
      live.err()
    )),
  }
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

fn unified_refresh_interval_seconds(auto_scan_interval_minutes: i64) -> i64 {
  auto_scan_interval_minutes.max(1).saturating_mul(60).max(60)
}

fn build_menu_bar_popup_window(app: &AppHandle) -> Result<WebviewWindow, String> {
  if let Some(window) = app.get_webview_window(MENU_BAR_POPUP_WINDOW_LABEL) {
    return Ok(window);
  }

  WebviewWindowBuilder::new(app, MENU_BAR_POPUP_WINDOW_LABEL, WebviewUrl::App("index.html".into()))
    .title("Codex Pacer Popup")
    .inner_size(MENU_BAR_POPUP_WIDTH, MENU_BAR_POPUP_INITIAL_HEIGHT)
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
    if window.hide().is_ok() {
      set_menu_bar_popup_visibility(app, false);
    }
  }
}

fn set_menu_bar_popup_visibility(app: &AppHandle, visible: bool) {
  if let Some(state) = app.try_state::<AppState>() {
    state.menu_bar_popup_visible.store(visible, Ordering::Release);
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
  drop(conn);
  if !settings.menu_bar_popup_enabled {
    clear_menu_bar_popup_anchor(state.inner());
    hide_menu_bar_popup(app);
    show_main_window(app);
    return Ok(());
  }

  let window = build_menu_bar_popup_window(app)?;
  if window.is_visible().map_err(|error| error.to_string())? {
    clear_menu_bar_popup_anchor(state.inner());
    window.hide().map_err(|error| error.to_string())?;
    state.menu_bar_popup_visible.store(false, Ordering::Release);
    return Ok(());
  }

  store_menu_bar_popup_anchor(state.inner(), rect, click_position);
  position_menu_bar_popup(&window, rect, click_position)?;
  window.show().map_err(|error| error.to_string())?;
  state.menu_bar_popup_visible.store(true, Ordering::Release);
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
  if let (_, Some(position)) = menu_bar_popup_geometry(window, rect, click_position, MENU_BAR_POPUP_INITIAL_HEIGHT)? {
    return window
      .set_position(Position::Physical(position))
      .map_err(|error| error.to_string());
  }

  let anchor = tray_rect_anchor_physical(rect, click_position, 1.0);
  let anchor_x = anchor.x.round() as i32;
  let anchor_y = anchor.y.round() as i32;
  let x = (anchor_x - MENU_BAR_POPUP_WIDTH as i32 / 2).max(0);
  let y = (anchor_y + MENU_BAR_POPUP_OFFSET_Y).max(0);
  window
    .set_position(Position::Physical(PhysicalPosition::new(x, y)))
    .map_err(|error| error.to_string())
}

fn menu_bar_popup_geometry(
  window: &WebviewWindow,
  rect: Rect,
  click_position: PhysicalPosition<f64>,
  requested_height: f64,
) -> Result<(f64, Option<PhysicalPosition<i32>>), String> {
  let Some(monitor) = tray_event_monitor(window, rect, click_position)? else {
    return Ok((
      requested_height.clamp(MENU_BAR_POPUP_MIN_HEIGHT, MENU_BAR_POPUP_MAX_HEIGHT),
      None,
    ));
  };

  let geometry = menu_bar_popup_geometry_for_monitor(
    rect,
    click_position,
    *monitor.position(),
    *monitor.size(),
    monitor.scale_factor(),
    requested_height,
  );
  Ok((geometry.height, Some(geometry.position)))
}

fn store_menu_bar_popup_anchor(state: &AppState, rect: Rect, click_position: PhysicalPosition<f64>) {
  match state.menu_bar_popup_anchor.lock() {
    Ok(mut anchor) => {
      *anchor = Some(MenuBarPopupAnchor { rect, click_position });
    }
    Err(_) => {
      log::warn!("Failed to store tray popup anchor.");
    }
  }
}

fn clear_menu_bar_popup_anchor(state: &AppState) {
  match state.menu_bar_popup_anchor.lock() {
    Ok(mut anchor) => {
      *anchor = None;
    }
    Err(_) => {
      log::warn!("Failed to clear tray popup anchor.");
    }
  }
}

fn latest_menu_bar_popup_anchor(state: &AppState) -> Option<MenuBarPopupAnchor> {
  state
    .menu_bar_popup_anchor
    .lock()
    .map(|anchor| anchor.clone())
    .unwrap_or_else(|_| {
      log::warn!("Failed to read tray popup anchor.");
      None
    })
}

fn tray_event_monitor(
  window: &WebviewWindow,
  rect: Rect,
  click_position: PhysicalPosition<f64>,
) -> Result<Option<Monitor>, String> {
  let monitors = window.available_monitors().map_err(|error| error.to_string())?;
  let mut best_match: Option<(Monitor, f64)> = None;

  for monitor in monitors {
    let scale_factor = normalized_scale_factor(monitor.scale_factor());
    // macOS tray events report scaled global positions; monitor_from_point expects CoreGraphics coordinates.
    let lookup_point = tray_event_monitor_lookup_point(rect, click_position, scale_factor);
    let Some(candidate) = window
      .monitor_from_point(lookup_point.x, lookup_point.y)
      .map_err(|error| error.to_string())?
    else {
      continue;
    };

    if !same_monitor(&candidate, &monitor) {
      continue;
    }

    let score = tray_monitor_scale_score(rect, scale_factor);
    let is_better_match = match best_match.as_ref() {
      Some((_, best_score)) => score < *best_score,
      None => true,
    };
    if is_better_match {
      best_match = Some((monitor, score));
    }
  }

  if let Some((monitor, _)) = best_match {
    return Ok(Some(monitor));
  }

  window
    .monitor_from_point(click_position.x, click_position.y)
    .map_err(|error| error.to_string())
}

fn same_monitor(left: &Monitor, right: &Monitor) -> bool {
  left.position() == right.position()
    && left.size() == right.size()
    && (left.scale_factor() - right.scale_factor()).abs() < 0.01
}

fn normalized_scale_factor(scale_factor: f64) -> f64 {
  if scale_factor.is_finite() && scale_factor > 0.0 {
    scale_factor
  } else {
    1.0
  }
}

fn tray_event_monitor_lookup_point(
  rect: Rect,
  click_position: PhysicalPosition<f64>,
  scale_factor: f64,
) -> PhysicalPosition<f64> {
  let anchor = tray_rect_anchor_physical(rect, click_position, scale_factor);
  PhysicalPosition::new(anchor.x / scale_factor, anchor.y / scale_factor)
}

fn tray_monitor_scale_score(rect: Rect, scale_factor: f64) -> f64 {
  let rect_size = tray_rect_size_to_physical(rect.size, scale_factor);
  if rect_size.height == 0 {
    return TRAY_ICON_MAX_LOGICAL_HEIGHT;
  }

  let logical_height = rect_size.height as f64 / scale_factor;
  if (TRAY_ICON_MIN_LOGICAL_HEIGHT..=TRAY_ICON_MAX_LOGICAL_HEIGHT).contains(&logical_height) {
    0.0
  } else if logical_height < TRAY_ICON_MIN_LOGICAL_HEIGHT {
    TRAY_ICON_MIN_LOGICAL_HEIGHT - logical_height
  } else {
    logical_height - TRAY_ICON_MAX_LOGICAL_HEIGHT
  }
}

fn menu_bar_popup_opens_above_tray(
  tray_top: i32,
  monitor_position: PhysicalPosition<i32>,
  monitor_size: PhysicalSize<u32>,
) -> bool {
  menu_bar_popup_opens_above_tray_for_policy(
    tray_top,
    monitor_position,
    monitor_size,
    platform_allows_bottom_taskbar_popup_above(),
  )
}

#[cfg(target_os = "windows")]
fn platform_allows_bottom_taskbar_popup_above() -> bool {
  true
}

#[cfg(not(target_os = "windows"))]
fn platform_allows_bottom_taskbar_popup_above() -> bool {
  false
}

fn menu_bar_popup_opens_above_tray_for_policy(
  tray_top: i32,
  monitor_position: PhysicalPosition<i32>,
  monitor_size: PhysicalSize<u32>,
  allow_above: bool,
) -> bool {
  if !allow_above {
    return false;
  }

  let monitor_mid_y = monitor_position.y + monitor_size.height as i32 / 2;
  tray_top >= monitor_mid_y
}

struct MenuBarPopupGeometry {
  position: PhysicalPosition<i32>,
  height: f64,
}

fn menu_bar_popup_geometry_for_monitor(
  rect: Rect,
  click_position: PhysicalPosition<f64>,
  monitor_position: PhysicalPosition<i32>,
  monitor_size: PhysicalSize<u32>,
  scale_factor: f64,
  requested_height: f64,
) -> MenuBarPopupGeometry {
  let scale_factor = normalized_scale_factor(scale_factor);
  let anchor = tray_rect_anchor_physical(rect, click_position, scale_factor);
  let tray_top = tray_rect_top_physical(rect, click_position, scale_factor);
  let popup_width = logical_to_physical_i32(MENU_BAR_POPUP_WIDTH, scale_factor);
  let offset_y = logical_to_physical_i32(MENU_BAR_POPUP_OFFSET_Y as f64, scale_factor);
  let mut x = anchor.x.round() as i32 - popup_width / 2;
  let opens_above = menu_bar_popup_opens_above_tray(tray_top, monitor_position, monitor_size);
  let available_height_physical = if opens_above {
    tray_top - offset_y - monitor_position.y
  } else {
    monitor_position.y + monitor_size.height as i32 - anchor.y.round() as i32 - offset_y
  };
  let available_height = (available_height_physical.max(0) as f64 / scale_factor).max(MENU_BAR_POPUP_MIN_HEIGHT);
  let height = requested_height.clamp(MENU_BAR_POPUP_MIN_HEIGHT, MENU_BAR_POPUP_MAX_HEIGHT.min(available_height));
  let popup_height = logical_to_physical_i32(height, scale_factor);
  let mut y = if opens_above {
    tray_top - offset_y - popup_height
  } else {
    anchor.y.round() as i32 + offset_y
  };
  let max_x = monitor_position.x + monitor_size.width as i32 - popup_width;
  let max_y = monitor_position.y + monitor_size.height as i32 - popup_height;
  x = x.clamp(monitor_position.x, max_x.max(monitor_position.x));
  y = y.clamp(monitor_position.y, max_y.max(monitor_position.y));
  MenuBarPopupGeometry {
    position: PhysicalPosition::new(x, y),
    height,
  }
}

fn tray_rect_anchor_physical(
  rect: Rect,
  click_position: PhysicalPosition<f64>,
  scale_factor: f64,
) -> PhysicalPosition<f64> {
  let rect_position = tray_rect_position_to_physical(rect.position, scale_factor);
  let rect_size = tray_rect_size_to_physical(rect.size, scale_factor);
  if rect_size.width > 0 && rect_size.height > 0 {
    return PhysicalPosition::new(
      rect_position.x as f64 + rect_size.width as f64 / 2.0,
      rect_position.y as f64 + rect_size.height as f64,
    );
  }

  click_position
}

fn logical_to_physical_i32(value: f64, scale_factor: f64) -> i32 {
  (value * normalized_scale_factor(scale_factor)).round().max(1.0) as i32
}

fn tray_rect_top_physical(rect: Rect, click_position: PhysicalPosition<f64>, scale_factor: f64) -> i32 {
  let rect_position = tray_rect_position_to_physical(rect.position, scale_factor);
  let rect_size = tray_rect_size_to_physical(rect.size, scale_factor);
  if rect_size.height > 0 {
    rect_position.y
  } else {
    click_position.y.round() as i32
  }
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

fn build_daily_value_menu_bar(app: &AppHandle, settings: &SyncSettings) -> Result<TrayIcon, String> {
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

fn full_maintenance_due(last_completed_at: Option<&str>, now: chrono::DateTime<chrono::Utc>) -> bool {
  let Some(last_completed_at) = last_completed_at else {
    return true;
  };
  let Some(last_completed_at) = chrono::DateTime::parse_from_rfc3339(last_completed_at).ok() else {
    return true;
  };
  now
    .signed_duration_since(last_completed_at.with_timezone(&chrono::Utc))
    .num_seconds()
    >= FULL_SCAN_MAINTENANCE_INTERVAL_SECONDS
}

fn effective_token_scan_kind(
  db_path: &Path,
  requested: refresh::TokenScanKind,
  now: DateTime<Utc>,
) -> Result<ScanKind, String> {
  if requested == refresh::TokenScanKind::Full {
    return Ok(ScanKind::Full);
  }
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let last_full = get_last_full_scan_completed(&conn).map_err(|error| error.to_string())?;
  Ok(if full_maintenance_due(last_full.as_deref(), now) {
    ScanKind::Reconcile
  } else {
    ScanKind::Incremental
  })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  let runtime_owner = Arc::new(Mutex::new(None::<refresh::RefreshRuntime>));
  let setup_runtime_owner = Arc::clone(&runtime_owner);
  let app = tauri::Builder::default()
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
            if window.hide().is_ok() {
              set_menu_bar_popup_visibility(window.app_handle(), false);
            }
          }
          tauri::WindowEvent::Focused(false) => {
            if window.hide().is_ok() {
              set_menu_bar_popup_visibility(window.app_handle(), false);
            }
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
    .setup(move |app| {
      let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("Failed to resolve app data dir: {error}"))?;
      fs::create_dir_all(&app_data_dir)
        .map_err(|error| format!("Failed to create app data dir {}: {error}", app_data_dir.display()))?;
      let db_path = app_data_dir.join("codex-counter.sqlite");

      prepare_app_database(&db_path)?;
      let conn = open_connection(&db_path).map_err(|error| error.to_string())?;
      let settings = get_sync_settings(&conn).map_err(|error| error.to_string())?;
      let display_fallback = load_preferred_persisted_live_rate_limits(&conn);
      let live_last_success_at = load_persisted_live_rate_limits_from_connection(&conn, Some("live"))
        .map(|snapshot| snapshot.fetched_at);
      let epoch_backfill_is_pending =
        database::epoch_backfill_pending(&conn).map_err(|error| error.to_string())?;
      drop(conn);

      let live_rate_limits = refresh::LiveQuotaCache::new();
      if let Some(fallback) = display_fallback {
        live_rate_limits.publish_fallback(
          Arc::new(fallback),
          Instant::now(),
          Utc::now(),
        );
      }

      let app_handle = app.app_handle();
      let usage_mutations = refresh::UsageMutationCoordinator::new();
      let runtime_dependencies = refresh::RefreshRuntimeDependencies::with_system_defaults(
          refresh_config_from_saved_settings(&settings, live_last_success_at.as_deref()),
          Arc::new(AppTokenRefreshExecutor {
            db_path: db_path.clone(),
          }),
          Arc::new(AppLiveQuotaFetcher {
            db_path: db_path.clone(),
            live_cache: live_rate_limits.clone(),
            client: Arc::new(LiveRateLimitClient::new()),
          }),
          Arc::new(AppLiveQuotaPersister {
            db_path: db_path.clone(),
          }),
          live_rate_limits.clone(),
          Arc::new(TauriRefreshEventSink {
            app_handle: app_handle.clone(),
          }),
          usage_mutations.clone(),
        );
      let runtime_dependencies = configure_epoch_maintenance(
        runtime_dependencies,
        db_path.clone(),
        epoch_backfill_is_pending,
      );
      let runtime = refresh::RefreshRuntime::start(runtime_dependencies)?;
      let refresh = runtime.handle();
      *setup_runtime_owner
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(runtime);

      let daily_value_tray = match build_daily_value_menu_bar(&app_handle, &settings) {
        Ok(tray) => Some(tray),
        Err(error) => {
          log::warn!("Failed to set up menu bar API value: {error}");
          None
        }
      };
      let state = AppState {
        app_handle: Some(app_handle.clone()),
        db_path,
        refresh: installed_refresh_handle(refresh),
        usage_mutations,
        menu_bar_render_state: Arc::new(AtomicU8::new(MENU_RENDER_IDLE)),
        daily_value_tray,
        live_rate_limits,
        menu_bar_popup_visible: Arc::new(AtomicBool::new(false)),
        menu_bar_popup_anchor: Arc::new(Mutex::new(None)),
      };
      app.manage(state.clone());
      apply_dock_icon_visibility(&app_handle, &settings, state.daily_value_tray.is_some());
      if let Err(error) = build_menu_bar_popup_window(&app_handle) {
        log::warn!("Failed to set up menu bar popup window: {error}");
      }
      if let Err(error) = render_daily_value_menu_bar(&state, &settings) {
        log::warn!("Failed to render initial menu bar display: {error}");
      }

      Ok(())
    })
    .invoke_handler(tauri::generate_handler![
      scanCodexUsage,
      getScanInProgress,
      getRefreshStatus,
      refreshBackgroundData,
      refreshPricing,
      getOverview,
      listConversations,
      getLiveRateLimits,
      getMenuBarPopupSnapshot,
      resizeMenuBarPopup,
      loadDashboard,
      getConversationDetail,
      handleMenuBarPopupAction,
      getSyncSettings,
      updateSyncSettings,
      getSubscriptionProfile,
      updateSubscriptionProfile,
    ])
    .build(tauri::generate_context!())
    .expect("error while building tauri application");

  app.run(move |app_handle, event| match event {
    tauri::RunEvent::Resumed => {
      if let Some(state) = app_handle.try_state::<AppState>() {
        match refresh_handle(state.inner()) {
          Ok(refresh) => match refresh.try_wake() {
            Ok(()) | Err(refresh::RefreshError::Busy) => {}
            Err(error) => log::warn!("Failed to wake refresh coordinator after resume: {error:?}"),
          },
          Err(error) => log::warn!("Failed to wake refresh coordinator after resume: {error}"),
        }
      }
    }
    tauri::RunEvent::Exit => {
      let runtime = runtime_owner
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
      if let Some(runtime) = runtime {
        if let Err(error) = runtime.shutdown_and_join() {
          log::warn!("Failed to shut down refresh runtime: {error:?}");
        }
      }
    }
    _ => {}
  });
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::sync::mpsc::{self, Receiver, Sender};
  use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering as AtomicOrdering};
  use tempfile::tempdir;

  struct RecordingTokenExecutor {
    requests: Sender<refresh::TokenExecutionRequest>,
  }

  impl refresh::TokenRefreshExecutor for RecordingTokenExecutor {
    fn parse(
      &self,
      request: refresh::TokenExecutionRequest,
    ) -> Result<refresh::PreparedTokenRefresh, String> {
      self
        .requests
        .send(request)
        .map_err(|error| error.to_string())?;
      Err("recording token executor stops after parse intake".to_string())
    }

    fn commit(&self, _: refresh::PreparedTokenRefresh) -> Result<ScanResult, String> {
      Err("recording token executor does not commit".to_string())
    }
  }

  struct RecordingAppTokenExecutor {
    inner: AppTokenRefreshExecutor,
    parsed: Sender<(u64, u64, refresh::TokenScanKind)>,
    committed: Sender<u64>,
  }

  impl refresh::TokenRefreshExecutor for RecordingAppTokenExecutor {
    fn parse(
      &self,
      request: refresh::TokenExecutionRequest,
    ) -> Result<refresh::PreparedTokenRefresh, String> {
      self
        .parsed
        .send((
          request.generation,
          request.source_generation,
          request.request.kind,
        ))
        .map_err(|error| error.to_string())?;
      self.inner.parse(request)
    }

    fn commit(
      &self,
      prepared: refresh::PreparedTokenRefresh,
    ) -> Result<ScanResult, String> {
      self
        .committed
        .send(prepared.generation)
        .map_err(|error| error.to_string())?;
      self.inner.commit(prepared)
    }
  }

  struct CountingLiveFetcher {
    calls: Arc<AtomicUsize>,
  }

  impl refresh::LiveQuotaFetcher for CountingLiveFetcher {
    fn fetch(&self, _: Duration) -> Result<LiveRateLimitSnapshot, String> {
      self.calls.fetch_add(1, AtomicOrdering::AcqRel);
      Err("counting live fetcher should not run".to_string())
    }
  }

  struct NoopLivePersister;

  impl refresh::LiveQuotaPersister for NoopLivePersister {
    fn persist(&self, _: &LiveRateLimitSnapshot) -> Result<(), String> {
      Ok(())
    }
  }

  struct NoopRefreshEvents;

  impl refresh::RefreshEventSink for NoopRefreshEvents {
    fn publish_invalidation(&self, _: refresh::DisplayInvalidation) {}

    fn publish_completion(&self, _: refresh::RefreshCompletedEvent) {}
  }

  #[test]
  fn production_epoch_maintenance_adapter_is_bounded_and_resumes_from_cursor() {
    let directory = tempdir().expect("create adapter test directory");
    let db_path = directory.path().join("epoch-maintenance.sqlite3");
    let conn = open_connection(&db_path).expect("open adapter database");
    init_db(&conn).expect("initialize adapter database");
    conn.execute_batch(
      "
      WITH RECURSIVE rows(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM rows WHERE value < 2501
      )
      INSERT INTO usage_events (
        session_id, timestamp, timestamp_ms, model_id,
        input_tokens, cached_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, value_usd,
        fast_mode_auto, fast_mode_effective
      )
      SELECT
        'legacy-' || value, '2026-07-10T03:00:00Z', NULL, 'gpt-5',
        1, 0, 1, 0, 2, 0.01, 0, 0
      FROM rows;
      ",
    )
    .expect("seed legacy epoch rows");
    assert!(database::epoch_backfill_pending(&conn).expect("read repair marker"));
    drop(conn);

    let first_adapter = AppEpochMaintenanceExecutor::new(db_path.clone());
    let first = refresh::EpochMaintenanceExecutor::run_batch(
      &first_adapter,
      1_000,
      Arc::new(AtomicBool::new(false)),
    )
    .expect("run first production slice");
    assert_eq!(
      first,
      refresh::EpochMaintenanceBatch::Progress {
        processed_rows: 1_000,
        complete: false,
      }
    );
    assert_eq!(first_adapter.open_count_for_test(), 1);
    assert!(first_adapter.connection_is_open_for_test());

    let second = refresh::EpochMaintenanceExecutor::run_batch(
      &first_adapter,
      1_000,
      Arc::new(AtomicBool::new(false)),
    )
    .expect("run second production slice on the same adapter");
    assert_eq!(
      second,
      refresh::EpochMaintenanceBatch::Progress {
        processed_rows: 1_000,
        complete: false,
      }
    );
    assert_eq!(
      first_adapter.open_count_for_test(),
      1,
      "incomplete slices reuse one WAL connection"
    );
    assert!(first_adapter.connection_is_open_for_test());

    let reopened = open_connection(&db_path).expect("reopen after first slice");
    let cursor: i64 = reopened
      .query_row(
        "SELECT progress_value FROM data_repair_progress WHERE repair_key = 'epoch_timestamp_backfill_v1' AND stream_key = 'usage_events'",
        [],
        |row| row.get(0),
      )
      .expect("load persisted cursor");
    assert_eq!(cursor, 2_000);
    drop(reopened);
    drop(first_adapter);

    let resumed_adapter = AppEpochMaintenanceExecutor::new(db_path);
    let resumed = refresh::EpochMaintenanceExecutor::run_batch(
      &resumed_adapter,
      1_000,
      Arc::new(AtomicBool::new(false)),
    )
    .expect("resume production slice");
    assert_eq!(
      resumed,
      refresh::EpochMaintenanceBatch::Progress {
        processed_rows: 501,
        complete: true,
      }
    );
    assert_eq!(resumed_adapter.open_count_for_test(), 1);
    assert!(
      !resumed_adapter.connection_is_open_for_test(),
      "completed repair releases its WAL connection"
    );
  }

  #[test]
  fn pre_cancelled_epoch_maintenance_adapter_does_not_open_database() {
    let directory = tempdir().expect("create cancelled adapter directory");
    let adapter = AppEpochMaintenanceExecutor::new(
      directory.path().join("pre-cancelled.sqlite3"),
    );

    let result = refresh::EpochMaintenanceExecutor::run_batch(
      &adapter,
      1_000,
      Arc::new(AtomicBool::new(true)),
    )
    .expect("observe pre-cancelled adapter call");

    assert_eq!(result, refresh::EpochMaintenanceBatch::Cancelled);
    assert_eq!(adapter.open_count_for_test(), 0);
    assert!(!adapter.connection_is_open_for_test());
  }

  #[test]
  fn failed_epoch_maintenance_slice_keeps_connection_for_retry() {
    let directory = tempdir().expect("create retry adapter directory");
    let db_path = directory.path().join("retry.sqlite3");
    let conn = open_connection(&db_path).expect("open retry database");
    init_db(&conn).expect("initialize retry database");
    conn.execute_batch(
      "
      INSERT INTO usage_events (
        session_id, timestamp, timestamp_ms, model_id,
        input_tokens, cached_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, value_usd,
        fast_mode_auto, fast_mode_effective
      )
      VALUES (
        'legacy', '2026-07-10T03:00:00Z', NULL, 'gpt-5',
        1, 0, 1, 0, 2, 0.01, 0, 0
      );
      CREATE TRIGGER fail_epoch_retry
      BEFORE UPDATE OF timestamp_ms ON usage_events
      BEGIN
        SELECT RAISE(ABORT, 'injected epoch retry failure');
      END;
      ",
    )
    .expect("seed retry failure");
    drop(conn);
    let adapter = AppEpochMaintenanceExecutor::new(db_path.clone());

    let error = refresh::EpochMaintenanceExecutor::run_batch(
      &adapter,
      1_000,
      Arc::new(AtomicBool::new(false)),
    )
    .expect_err("inject first slice failure");
    assert!(error.contains("injected epoch retry failure"));
    assert_eq!(adapter.open_count_for_test(), 1);
    assert!(adapter.connection_is_open_for_test());

    let repair = open_connection(&db_path).expect("open trigger repair connection");
    repair
      .execute_batch("DROP TRIGGER fail_epoch_retry;")
      .expect("remove injected failure");
    drop(repair);
    let retried = refresh::EpochMaintenanceExecutor::run_batch(
      &adapter,
      1_000,
      Arc::new(AtomicBool::new(false)),
    )
    .expect("retry with retained connection");

    assert_eq!(
      retried,
      refresh::EpochMaintenanceBatch::Progress {
        processed_rows: 1,
        complete: true,
      }
    );
    assert_eq!(adapter.open_count_for_test(), 1);
    assert!(!adapter.connection_is_open_for_test());
  }

  #[test]
  fn completed_epoch_repair_does_not_inject_a_runtime_worker() {
    let directory = tempdir().expect("create completed repair directory");
    let db_path = directory.path().join("completed.sqlite3");
    let conn = open_connection(&db_path).expect("open completed database");
    init_db(&conn).expect("initialize completed database");
    conn.execute(
      "INSERT INTO data_repairs (repair_key, completed_at) VALUES ('epoch_timestamp_backfill_v1', '2026-07-11T00:00:00Z')",
      [],
    )
    .expect("mark epoch repair complete");
    let pending = database::epoch_backfill_pending(&conn).expect("check completion marker");
    drop(conn);
    let (requests, _) = mpsc::channel();
    let dependencies = refresh::RefreshRuntimeDependencies::with_system_defaults(
      refresh::RefreshConfig {
        auto_scan_enabled: false,
        interval: Duration::from_secs(60),
        codex_home: None,
        token_last_success_wall: None,
        live_last_success_wall: None,
      },
      Arc::new(RecordingTokenExecutor { requests }),
      Arc::new(CountingLiveFetcher {
        calls: Arc::new(AtomicUsize::new(0)),
      }),
      Arc::new(NoopLivePersister),
      refresh::LiveQuotaCache::new(),
      Arc::new(NoopRefreshEvents),
      refresh::UsageMutationCoordinator::new(),
    );

    let dependencies = configure_epoch_maintenance(dependencies, db_path, pending);

    assert!(!pending);
    assert!(dependencies.epoch_maintenance_executor.is_none());
  }

  struct GatedFailingTokenExecutor {
    entered: Sender<()>,
    release: Mutex<Receiver<()>>,
  }

  impl refresh::TokenRefreshExecutor for GatedFailingTokenExecutor {
    fn parse(
      &self,
      _: refresh::TokenExecutionRequest,
    ) -> Result<refresh::PreparedTokenRefresh, String> {
      self.entered.send(()).map_err(|error| error.to_string())?;
      self
        .release
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .recv()
        .map_err(|error| error.to_string())?;
      Err("injected popup token failure".to_string())
    }

    fn commit(&self, _: refresh::PreparedTokenRefresh) -> Result<ScanResult, String> {
      Err("injected popup token commit failure".to_string())
    }
  }

  struct GatedFailingLiveFetcher {
    entered: Sender<()>,
    release: Mutex<Receiver<()>>,
  }

  impl refresh::LiveQuotaFetcher for GatedFailingLiveFetcher {
    fn fetch(&self, _: Duration) -> Result<LiveRateLimitSnapshot, String> {
      self.entered.send(()).map_err(|error| error.to_string())?;
      self
        .release
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .recv()
        .map_err(|error| error.to_string())?;
      Err("injected popup live failure".to_string())
    }
  }

  fn start_recording_runtime(
    config: refresh::RefreshConfig,
  ) -> (
    refresh::RefreshRuntime,
    Receiver<refresh::TokenExecutionRequest>,
    Arc<AtomicUsize>,
  ) {
    let (requests, received) = mpsc::channel();
    let live_calls = Arc::new(AtomicUsize::new(0));
    let dependencies = refresh::RefreshRuntimeDependencies::with_system_defaults(
      config,
      Arc::new(RecordingTokenExecutor { requests }),
      Arc::new(CountingLiveFetcher {
        calls: Arc::clone(&live_calls),
      }),
      Arc::new(NoopLivePersister),
      refresh::LiveQuotaCache::new(),
      Arc::new(NoopRefreshEvents),
      refresh::UsageMutationCoordinator::new(),
    );
    let runtime = refresh::RefreshRuntime::start(dependencies).expect("start recording runtime");
    (runtime, received, live_calls)
  }

  fn disabled_refresh_config(codex_home: Option<String>) -> refresh::RefreshConfig {
    refresh::RefreshConfig {
      auto_scan_enabled: false,
      interval: Duration::from_secs(3600),
      codex_home,
      token_last_success_wall: None,
      live_last_success_wall: None,
    }
  }

  fn test_app_state(
    db_path: PathBuf,
    refresh: refresh::RefreshCoordinatorHandle,
    usage_mutations: refresh::UsageMutationCoordinator,
    live_rate_limits: refresh::LiveQuotaCache,
  ) -> AppState {
    AppState {
      app_handle: None,
      db_path,
      refresh: Some(refresh),
      usage_mutations,
      menu_bar_render_state: Arc::new(AtomicU8::new(MENU_RENDER_IDLE)),
      daily_value_tray: None,
      live_rate_limits,
      menu_bar_popup_visible: Arc::new(AtomicBool::new(false)),
      menu_bar_popup_anchor: Arc::new(Mutex::new(None)),
    }
  }

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

  fn utc_time(value: &str) -> chrono::DateTime<chrono::Utc> {
    DateTime::parse_from_rfc3339(value)
      .expect("parse test timestamp")
      .with_timezone(&chrono::Utc)
  }

  #[test]
  fn settings_change_wakes_coordinator_immediately() {
    let initial = refresh::RefreshConfig {
      auto_scan_enabled: false,
      interval: Duration::from_secs(3600),
      codex_home: None,
      token_last_success_wall: None,
      live_last_success_wall: None,
    };
    let (runtime, token_requests, _) = start_recording_runtime(initial);
    let handle = runtime.handle();
    let saved = SyncSettings {
      auto_scan_enabled: true,
      auto_scan_interval_minutes: 60,
      ..SyncSettings::default()
    };

    update_coordinator_from_saved_settings(&handle, &saved).expect("deliver settings update");

    assert!(handle.status().auto_scan_enabled);
    token_requests
      .recv_timeout(Duration::from_secs(2))
      .expect("enabled overdue settings wake token lane");
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn codex_home_change_requests_full_scan() {
    let initial = refresh::RefreshConfig {
      auto_scan_enabled: false,
      interval: Duration::from_secs(3600),
      codex_home: Some("/tmp/codex-home-before".to_string()),
      token_last_success_wall: None,
      live_last_success_wall: None,
    };
    let (runtime, token_requests, _) = start_recording_runtime(initial);
    let handle = runtime.handle();
    let source_generation_before = handle.status().source_generation;
    let saved = SyncSettings {
      codex_home: Some("/tmp/codex-home-after".to_string()),
      auto_scan_enabled: false,
      auto_scan_interval_minutes: 60,
      ..SyncSettings::default()
    };

    update_coordinator_from_saved_settings(&handle, &saved).expect("deliver source change");

    let request = token_requests
      .recv_timeout(Duration::from_secs(2))
      .expect("source change starts protected token refresh");
    assert_eq!(request.request.kind, refresh::TokenScanKind::Full);
    assert!(request
      .request
      .reasons
      .contains(refresh::RefreshReason::SettingsChanged));
    assert_eq!(
      request.request.codex_home.as_deref(),
      Some("/tmp/codex-home-after")
    );
    assert_eq!(handle.status().source_generation, source_generation_before + 1);
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn passive_live_getter_does_not_start_fetch() {
    let (runtime, token_requests, live_calls) =
      start_recording_runtime(disabled_refresh_config(None));
    let status_before = runtime.handle().status();
    let cache = refresh::LiveQuotaCache::new();
    cache.publish_fallback(
      Arc::new(LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: None,
        secondary: None,
        fetched_at: "2026-07-11T00:00:00Z".to_string(),
      }),
      Instant::now(),
      Utc::now(),
    );

    let snapshot = get_passive_live_rate_limits(&cache).expect("read cached quota");

    assert_eq!(snapshot.fetched_at, "2026-07-11T00:00:00Z");
    assert!(cache.needs_live_refresh(Duration::from_secs(3600), Instant::now()));
    assert!(matches!(token_requests.try_recv(), Err(mpsc::TryRecvError::Empty)));
    assert_eq!(live_calls.load(AtomicOrdering::Acquire), 0);
    let status_after = runtime.handle().status();
    assert_eq!(status_after.source_generation, status_before.source_generation);
    assert!(!status_after.token.running && !status_after.token.pending);
    assert!(!status_after.live.running && !status_after.live.pending);
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn popup_snapshot_read_does_not_start_scan() {
    let (runtime, token_requests, live_calls) =
      start_recording_runtime(disabled_refresh_config(None));
    let status_before = runtime.handle().status();
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let cache = refresh::LiveQuotaCache::new();

    let snapshot = build_passive_menu_bar_popup_snapshot(&db_path, &cache)
      .expect("build passive popup snapshot");

    assert_eq!(snapshot.total_tokens_selected_bucket, 0);
    let conn = open_connection(&db_path).expect("open database");
    let event_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))
      .expect("count usage events");
    assert_eq!(event_count, 0);
    assert!(matches!(token_requests.try_recv(), Err(mpsc::TryRecvError::Empty)));
    assert_eq!(live_calls.load(AtomicOrdering::Acquire), 0);
    let status_after = runtime.handle().status();
    assert_eq!(status_after.source_generation, status_before.source_generation);
    assert!(!status_after.token.running && !status_after.token.pending);
    assert!(!status_after.live.running && !status_after.live.pending);
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn popup_snapshot_uses_seven_day_bucket_when_five_hour_quota_is_absent() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    let mut settings = get_sync_settings(&conn).expect("load settings");
    settings.menu_bar_bucket = "five_hour".to_string();
    save_sync_settings(&conn, &settings).expect("save menu bar bucket");
    drop(conn);

    let cache = refresh::LiveQuotaCache::new();
    cache.publish_fallback(
      Arc::new(LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: None,
        secondary: Some(RateLimitWindowSnapshot {
          used_percent: 21,
          remaining_percent: 79,
          window_duration_mins: Some(10_080),
          resets_at: Some("2026-07-20T00:00:00+08:00".to_string()),
          window_start: Some("2026-07-13T00:00:00+08:00".to_string()),
        }),
        fetched_at: "2026-07-13T10:00:00+08:00".to_string(),
      }),
      Instant::now(),
      Utc::now(),
    );

    let snapshot = build_passive_menu_bar_popup_snapshot(&db_path, &cache)
      .expect("build popup snapshot");

    assert_eq!(snapshot.selected_bucket, "seven_day");
    assert!(snapshot.quota_5h.is_none());
    assert_eq!(
      snapshot.quota_7d.map(|window| window.remaining_percent),
      Some(79)
    );
  }

  #[test]
  fn forced_popup_requests_token_and_live_before_waiting() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let live_cache = refresh::LiveQuotaCache::new();
    live_cache.publish_fallback(
      Arc::new(LiveRateLimitSnapshot {
        limit_id: Some("cached".to_string()),
        limit_name: None,
        plan_type: None,
        primary: None,
        secondary: None,
        fetched_at: "2026-07-11T00:00:00Z".to_string(),
      }),
      Instant::now(),
      Utc::now(),
    );
    let mutation = refresh::UsageMutationCoordinator::new();
    let (token_entered_tx, token_entered_rx) = mpsc::channel();
    let (token_release_tx, token_release_rx) = mpsc::channel();
    let (live_entered_tx, live_entered_rx) = mpsc::channel();
    let (live_release_tx, live_release_rx) = mpsc::channel();
    let runtime = refresh::RefreshRuntime::start(
      refresh::RefreshRuntimeDependencies::with_system_defaults(
        disabled_refresh_config(None),
        Arc::new(GatedFailingTokenExecutor {
          entered: token_entered_tx,
          release: Mutex::new(token_release_rx),
        }),
        Arc::new(GatedFailingLiveFetcher {
          entered: live_entered_tx,
          release: Mutex::new(live_release_rx),
        }),
        Arc::new(NoopLivePersister),
        live_cache.clone(),
        Arc::new(NoopRefreshEvents),
        mutation.clone(),
      ),
    )
    .expect("start popup runtime");
    let state = test_app_state(
      db_path,
      runtime.handle(),
      mutation,
      live_cache.clone(),
    );
    let refresh_thread = std::thread::spawn(move || refresh_popup_data(&state));

    token_entered_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("token lane starts");
    live_entered_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("live lane starts before token wait completes");
    token_release_tx.send(()).expect("release token lane");
    live_release_tx.send(()).expect("release live lane");
    assert!(refresh_thread
      .join()
      .expect("join forced popup refresh")
      .is_err());
    assert_eq!(
      live_cache
        .rate_limits()
        .expect("old fallback remains cached")
        .fetched_at,
      "2026-07-11T00:00:00Z"
    );
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn manual_scan_uses_coordinator_generation() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let codex_home = directory.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).expect("create Codex home");
    prepare_app_database(&db_path).expect("prepare app database");
    let (parsed_tx, parsed_rx) = mpsc::channel();
    let (committed_tx, committed_rx) = mpsc::channel();
    let token_executor = RecordingAppTokenExecutor {
      inner: AppTokenRefreshExecutor {
        db_path: db_path.clone(),
      },
      parsed: parsed_tx,
      committed: committed_tx,
    };
    let live_calls = Arc::new(AtomicUsize::new(0));
    let dependencies = refresh::RefreshRuntimeDependencies::with_system_defaults(
      disabled_refresh_config(Some(codex_home.to_string_lossy().to_string())),
      Arc::new(token_executor),
      Arc::new(CountingLiveFetcher {
        calls: Arc::clone(&live_calls),
      }),
      Arc::new(NoopLivePersister),
      refresh::LiveQuotaCache::new(),
      Arc::new(NoopRefreshEvents),
      refresh::UsageMutationCoordinator::new(),
    );
    let runtime = refresh::RefreshRuntime::start(dependencies).expect("start runtime");
    let handle = runtime.handle();

    let result = run_manual_scan_with_coordinator(
      &handle,
      Some(codex_home.to_string_lossy().to_string()),
    )
    .expect("manual scan succeeds through coordinator");

    let (parsed_generation, source_generation, kind) = parsed_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("manual scan reaches production adapter");
    let committed_generation = committed_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("prepared generation reaches commit");
    assert!(parsed_generation > 0);
    assert_eq!(parsed_generation, committed_generation);
    assert_eq!(source_generation, handle.status().source_generation);
    assert_eq!(kind, refresh::TokenScanKind::Incremental);
    assert_eq!(result.codex_home, codex_home.to_string_lossy());
    assert_eq!(live_calls.load(AtomicOrdering::Acquire), 0);
    runtime.shutdown_and_join().expect("shutdown runtime");
  }

  #[test]
  fn pricing_recalculation_uses_lower_priority_mutation_ticket() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let coordinator = refresh::UsageMutationCoordinator::new();
    let blocker = coordinator.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker_thread = std::thread::spawn(move || {
      blocker.run(refresh::MutationPriority::Refresh, || {
        entered_tx.send(()).expect("report refresh slot");
        release_rx.recv().expect("release refresh slot");
      });
    });
    entered_rx.recv().expect("refresh mutation enters first");

    let pricing_coordinator = coordinator.clone();
    let (result_tx, result_rx) = mpsc::channel();
    let pricing_thread = std::thread::spawn(move || {
      let result = refresh_pricing_catalog_with_runner(
        &db_path,
        None,
        |priority, mutation| pricing_coordinator.run(priority, mutation).value,
      );
      result_tx.send(result).expect("send pricing result");
    });

    assert!(matches!(
      result_rx.recv_timeout(Duration::from_millis(50)),
      Err(mpsc::RecvTimeoutError::Timeout)
    ));
    release_tx.send(()).expect("release refresh mutation");
    result_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("pricing runs after refresh slot")
      .expect("pricing refresh succeeds");
    blocker_thread.join().expect("join refresh blocker");
    pricing_thread.join().expect("join pricing refresh");
  }

  #[test]
  fn menu_render_coalescer_retries_failed_running_transition() {
    let state = AtomicU8::new(MENU_RENDER_RUNNING);
    let transitioned = std::cell::Cell::new(false);

    let claimed = claim_menu_bar_render_with_hook(&state, |observed| {
      if observed == MENU_RENDER_RUNNING && !transitioned.replace(true) {
        state.store(MENU_RENDER_IDLE, Ordering::Release);
      }
    });

    assert!(claimed, "failed RUNNING to PENDING CAS must retry from IDLE");
    assert_eq!(state.load(Ordering::Acquire), MENU_RENDER_RUNNING);
    assert!(!claim_menu_bar_render(&state));
    assert_eq!(state.load(Ordering::Acquire), MENU_RENDER_PENDING);
    assert!(complete_menu_bar_render(&state));
    assert_eq!(state.load(Ordering::Acquire), MENU_RENDER_IDLE);
  }

  fn seed_scan_freshness(conn: &rusqlite::Connection, codex_home: &str) -> SyncSettings {
    let initial = SyncSettings {
      codex_home: Some(codex_home.to_string()),
      ..get_sync_settings(conn).expect("load settings")
    };
    save_sync_settings(conn, &initial).expect("save initial source");
    database::set_last_scan_started_for_source(
      conn,
      "2026-07-10T08:00:00Z",
      Some(codex_home),
      codex_home,
    )
    .expect("set scan start");
    assert!(database::set_scan_completed_for_source(
      conn,
      "2026-07-10T08:01:00Z",
      Some(codex_home),
      codex_home,
      true,
      false,
    )
    .expect("set full scan completion"));
    get_sync_settings(conn).expect("reload scan freshness")
  }

  #[test]
  fn changing_codex_home_clears_scan_freshness() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    let settings = seed_scan_freshness(&conn, "/tmp/codex-home-before");

    let changed = SyncSettings {
      codex_home: Some("/tmp/codex-home-after".to_string()),
      ..settings
    };
    let saved = save_normalized_sync_settings(&conn, changed).expect("save changed settings");

    assert_eq!(saved.last_scan_started_at, None);
    assert_eq!(saved.last_scan_completed_at, None);
    assert_eq!(get_last_full_scan_completed(&conn).expect("load full scan"), None);
  }

  #[test]
  fn unchanged_codex_home_preserves_scan_freshness() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    let settings = seed_scan_freshness(&conn, "/tmp/codex-home");

    let saved = save_normalized_sync_settings(&conn, settings).expect("save unchanged source");

    assert_eq!(saved.last_scan_started_at.as_deref(), Some("2026-07-10T08:00:00Z"));
    assert_eq!(saved.last_scan_completed_at.as_deref(), Some("2026-07-10T08:01:00Z"));
    assert_eq!(
      get_last_full_scan_completed(&conn).expect("load full scan").as_deref(),
      Some("2026-07-10T08:01:00Z")
    );
  }

  #[test]
  fn full_maintenance_is_due_without_previous_full_scan() {
    assert!(full_maintenance_due(None, utc_time("2026-03-27T00:00:00Z")));
  }

  #[test]
  fn full_maintenance_waits_until_daily_interval() {
    assert!(!full_maintenance_due(
      Some("2026-03-27T00:00:00Z"),
      utc_time("2026-03-27T23:59:59Z")
    ));
    assert!(full_maintenance_due(
      Some("2026-03-27T00:00:00Z"),
      utc_time("2026-03-28T00:00:00Z")
    ));
  }

  #[test]
  fn automatic_incremental_request_upgrades_to_full_after_daily_maintenance() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    database::set_last_full_scan_completed(&conn, "2026-07-10T00:00:00Z")
      .expect("seed full scan freshness");
    drop(conn);

    assert_eq!(
      effective_token_scan_kind(
        &db_path,
        refresh::TokenScanKind::Incremental,
        utc_time("2026-07-11T00:00:00Z"),
      )
      .expect("select scan kind"),
      ScanKind::Reconcile
    );
    assert_eq!(
      effective_token_scan_kind(
        &db_path,
        refresh::TokenScanKind::Incremental,
        utc_time("2026-07-10T23:59:59Z"),
      )
      .expect("select recent scan kind"),
      ScanKind::Incremental
    );
  }

  #[test]
  fn startup_database_prepare_does_not_recalculate_usage_values() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    seed_pricing_catalog(&conn).expect("seed pricing");
    mark_pricing_value_resolution_repair_complete(&conn).expect("mark resolver repair complete");
    let created_at = database::now_utc_string();
    conn
      .execute(
        "
        INSERT INTO sessions (
          session_id, root_session_id, parent_session_id, title, source_state, source_path,
          source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
          fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
        )
        VALUES ('startup-session', 'startup-session', NULL, NULL, 'active', NULL, 'active',
          NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.4', 0, ?1, ?1)
        ",
        params![created_at],
      )
      .expect("insert session");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens, value_usd,
          fast_mode_auto, fast_mode_effective
        )
        VALUES ('startup-session', '2026-03-26T04:30:00Z', 'gpt-5.4',
          100, 0, 10, 0, 110, 123.45, 0, 0)
        ",
        [],
      )
      .expect("insert usage event");
    drop(conn);

    prepare_app_database(&db_path).expect("prepare app database");

    let conn = open_connection(&db_path).expect("reopen database");
    let value_usd: f64 = conn
      .query_row(
        "SELECT value_usd FROM usage_events WHERE session_id = 'startup-session'",
        [],
        |row| row.get(0),
      )
      .expect("load usage value");

    assert_eq!(value_usd, 123.45);
  }

  #[test]
  fn startup_database_prepare_recalculates_gpt_56_aliases_when_resolver_repair_is_pending() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    seed_pricing_catalog(&conn).expect("seed pricing");
    let created_at = database::now_utc_string();
    for (session_id, model_id, stale_value) in [
      ("gpt-56-alias-exact", "gpt-5.6", 6.25),
      ("gpt-56-alias-dated", "gpt-5.6-2026-07-09", 0.0),
    ] {
      conn
        .execute(
          "
          INSERT INTO sessions (
            session_id, root_session_id, parent_session_id, title, source_state, source_path,
            source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
            fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
          )
          VALUES (?1, ?1, NULL, NULL, 'active', NULL, 'active',
            NULL, NULL, NULL, NULL, NULL, 0, NULL, ?2, 0, ?3, ?3)
          ",
          params![session_id, model_id, created_at],
        )
        .expect("insert session");
      conn
        .execute(
          "
          INSERT INTO usage_events (
            session_id, timestamp, model_id, input_tokens, cached_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens, value_usd,
            fast_mode_auto, fast_mode_effective
          )
          VALUES (?1, '2026-07-09T00:00:00Z', ?2,
            0, 0, 1000000, 0, 1000000, ?3, 0, 0)
          ",
          params![session_id, model_id, stale_value],
        )
        .expect("insert usage event");
    }
    drop(conn);

    prepare_app_database(&db_path).expect("prepare app database");

    let conn = open_connection(&db_path).expect("reopen database");
    let values = conn
      .prepare("SELECT session_id, value_usd FROM usage_events ORDER BY session_id")
      .expect("prepare usage values")
      .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, f64>(1)?)))
      .expect("query usage values")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect usage values");
    let repair_completed: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
        params![PRICING_VALUE_RESOLUTION_REPAIR_KEY],
        |row| row.get(0),
      )
      .expect("load repair marker");

    assert_eq!(
      values,
      vec![
        ("gpt-56-alias-dated".to_string(), 30.0),
        ("gpt-56-alias-exact".to_string(), 30.0),
      ]
    );
    assert_eq!(repair_completed, 1);
  }

  #[test]
  fn startup_database_prepare_recalculates_usage_values_when_seed_pricing_changes() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    seed_pricing_catalog(&conn).expect("seed pricing");
    conn
      .execute(
        "
        UPDATE pricing_catalog
        SET input_price_per_million = 1.00
        WHERE model_id = 'gpt-5.4'
        ",
        [],
      )
      .expect("seed stale pricing");
    let created_at = database::now_utc_string();
    conn
      .execute(
        "
        INSERT INTO sessions (
          session_id, root_session_id, parent_session_id, title, source_state, source_path,
          source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
          fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
        )
        VALUES ('startup-session', 'startup-session', NULL, NULL, 'active', NULL, 'active',
          NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.4', 0, ?1, ?1)
        ",
        params![created_at],
      )
      .expect("insert session");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens, value_usd,
          fast_mode_auto, fast_mode_effective
        )
        VALUES ('startup-session', '2026-03-26T04:30:00Z', 'gpt-5.4',
          1000000, 0, 0, 0, 1000000, 123.45, 0, 0)
        ",
        [],
      )
      .expect("insert usage event");
    drop(conn);

    prepare_app_database(&db_path).expect("prepare app database");

    let conn = open_connection(&db_path).expect("reopen database");
    let value_usd: f64 = conn
      .query_row(
        "SELECT value_usd FROM usage_events WHERE session_id = 'startup-session'",
        [],
        |row| row.get(0),
      )
      .expect("load usage value");

    assert_eq!(value_usd, 2.50);
  }

  #[test]
  fn startup_database_prepare_recalculates_new_gpt_56_values() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    seed_pricing_catalog(&conn).expect("seed pricing");
    conn
      .execute(
        "
        UPDATE pricing_catalog
        SET output_price_per_million = 6.25,
            is_official = 1
        WHERE model_id = 'gpt-5.6-sol'
        ",
        [],
      )
      .expect("seed malformed GPT-5.6 Sol pricing");
    let created_at = database::now_utc_string();
    conn
      .execute(
        "
        INSERT INTO sessions (
          session_id, root_session_id, parent_session_id, title, source_state, source_path,
          source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
          fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
        )
        VALUES ('gpt-56-startup-session', 'gpt-56-startup-session', NULL, NULL, 'active', NULL, 'active',
          NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.6-sol', 0, ?1, ?1)
        ",
        params![created_at],
      )
      .expect("insert session");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens, value_usd,
          fast_mode_auto, fast_mode_effective
        )
        VALUES ('gpt-56-startup-session', '2026-07-09T00:00:00Z', 'gpt-5.6-sol',
          0, 0, 1000000, 0, 1000000, 0.0, 0, 0)
        ",
        [],
      )
      .expect("insert usage event");
    drop(conn);

    prepare_app_database(&db_path).expect("prepare app database");

    let conn = open_connection(&db_path).expect("reopen database");
    let value_usd: f64 = conn
      .query_row(
        "SELECT value_usd FROM usage_events WHERE session_id = 'gpt-56-startup-session'",
        [],
        |row| row.get(0),
      )
      .expect("load usage value");

    assert_eq!(value_usd, 30.0);
  }

  #[test]
  fn startup_database_prepare_rolls_back_pricing_when_recalculation_fails() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    seed_pricing_catalog(&conn).expect("seed pricing");
    conn
      .execute(
        "
        UPDATE pricing_catalog
        SET output_price_per_million = 6.25,
            is_official = 1,
            note = 'malformed-official',
            updated_at = 'malformed-official'
        WHERE model_id = 'gpt-5.6-sol'
        ",
        [],
      )
      .expect("seed malformed GPT-5.6 Sol pricing");
    let created_at = database::now_utc_string();
    for (session_id, sentinel_value) in [("recalc-a", 11.0), ("recalc-b", 22.0)] {
      conn
        .execute(
          "
          INSERT INTO sessions (
            session_id, root_session_id, parent_session_id, title, source_state, source_path,
            source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
            fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
          )
          VALUES (?1, ?1, NULL, NULL, 'active', NULL, 'active',
            NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.6-sol', 0, ?2, ?2)
          ",
          params![session_id, created_at],
        )
        .expect("insert session");
      conn
        .execute(
          "
          INSERT INTO usage_events (
            session_id, timestamp, model_id, input_tokens, cached_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens, value_usd,
            fast_mode_auto, fast_mode_effective
          )
          VALUES (?1, '2026-07-09T00:00:00Z', 'gpt-5.6-sol',
            0, 0, 1000000, 0, 1000000, ?2, 0, 0)
          ",
          params![session_id, sentinel_value],
        )
        .expect("insert usage event");
    }
    conn
      .execute_batch(
        "
        CREATE TRIGGER fail_second_session_recalculation
        BEFORE UPDATE OF value_usd ON usage_events
        WHEN OLD.session_id = 'recalc-b'
        BEGIN
          SELECT RAISE(ABORT, 'injected recalculation failure');
        END;
        ",
      )
      .expect("create failure trigger");
    drop(conn);

    let error = prepare_app_database(&db_path).expect_err("recalculation should fail");
    assert!(error.contains("injected recalculation failure"));

    let conn = open_connection(&db_path).expect("reopen failed database");
    let (output_price, is_official): (f64, i64) = conn
      .query_row(
        "
        SELECT output_price_per_million, is_official
        FROM pricing_catalog
        WHERE model_id = 'gpt-5.6-sol'
        ",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
      )
      .expect("load rolled back pricing");
    let failed_values = conn
      .prepare("SELECT session_id, value_usd FROM usage_events ORDER BY session_id")
      .expect("prepare failed values")
      .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, f64>(1)?)))
      .expect("query failed values")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect failed values");

    assert_eq!(output_price, 6.25);
    assert_eq!(is_official, 1);
    assert_eq!(
      failed_values,
      vec![("recalc-a".to_string(), 11.0), ("recalc-b".to_string(), 22.0)]
    );
    assert!(pricing_value_resolution_repair_pending(&conn).expect("load rolled back repair marker"));

    conn
      .execute_batch("DROP TRIGGER fail_second_session_recalculation;")
      .expect("drop failure trigger");
    drop(conn);

    prepare_app_database(&db_path).expect("retry prepare app database");

    let conn = open_connection(&db_path).expect("reopen repaired database");
    let repaired_output: f64 = conn
      .query_row(
        "SELECT output_price_per_million FROM pricing_catalog WHERE model_id = 'gpt-5.6-sol'",
        [],
        |row| row.get(0),
      )
      .expect("load repaired pricing");
    let repaired_values = conn
      .prepare("SELECT value_usd FROM usage_events ORDER BY session_id")
      .expect("prepare repaired values")
      .query_map([], |row| row.get::<_, f64>(0))
      .expect("query repaired values")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect repaired values");

    assert_eq!(repaired_output, 30.0);
    assert_eq!(repaired_values, vec![30.0, 30.0]);
    assert!(!pricing_value_resolution_repair_pending(&conn).expect("load completed repair marker"));
  }

  #[test]
  fn pricing_refresh_rolls_back_catalog_values_and_marker_before_retry() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let mut conn = open_connection(&db_path).expect("open database");
    let created_at = database::now_utc_string();
    for (session_id, sentinel_value) in [("refresh-a", 11.0), ("refresh-b", 22.0)] {
      conn
        .execute(
          "
          INSERT INTO sessions (
            session_id, root_session_id, parent_session_id, title, source_state, source_path,
            source_bucket, started_at, updated_at, agent_nickname, agent_role, explicit_fast_mode,
            fast_mode_default, latest_plan_type, last_model_id, contains_subagents, created_at, imported_at
          )
          VALUES (?1, ?1, NULL, NULL, 'active', NULL, 'active',
            NULL, NULL, NULL, NULL, NULL, 0, NULL, 'gpt-5.6-sol', 0, ?2, ?2)
          ",
          params![session_id, created_at],
        )
        .expect("insert session");
      conn
        .execute(
          "
          INSERT INTO usage_events (
            session_id, timestamp, model_id, input_tokens, cached_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens, value_usd,
            fast_mode_auto, fast_mode_effective
          )
          VALUES (?1, '2026-07-09T00:00:00Z', 'gpt-5.6-sol',
            0, 0, 1000000, 0, 1000000, ?2, 0, 0)
          ",
          params![session_id, sentinel_value],
        )
        .expect("insert usage event");
    }
    conn
      .execute(
        "DELETE FROM data_repairs WHERE repair_key = ?1",
        params![PRICING_VALUE_RESOLUTION_REPAIR_KEY],
      )
      .expect("clear repair marker");
    conn
      .execute_batch(
        "
        CREATE TRIGGER fail_second_refresh_recalculation
        BEFORE UPDATE OF value_usd ON usage_events
        WHEN OLD.session_id = 'refresh-b'
        BEGIN
          SELECT RAISE(ABORT, 'injected refresh failure');
        END;
        ",
      )
      .expect("create failure trigger");
    let mut official_sol = load_catalog(&conn)
      .expect("load catalog")
      .into_iter()
      .find(|entry| entry.model_id == "gpt-5.6-sol")
      .expect("load GPT-5.6 Sol");
    official_sol.output_price_per_million = 42.0;
    official_sol.is_official = true;
    official_sol.note = Some("atomic refresh test".to_string());
    official_sol.updated_at = "atomic-refresh-test".to_string();
    let official_entries = vec![official_sol];

    let error = refresh_pricing_catalog_atomically(&mut conn, Some(&official_entries))
      .expect_err("refresh should fail");
    assert!(error.contains("injected refresh failure"));

    let failed_output: f64 = conn
      .query_row(
        "SELECT output_price_per_million FROM pricing_catalog WHERE model_id = 'gpt-5.6-sol'",
        [],
        |row| row.get(0),
      )
      .expect("load rolled back pricing");
    let failed_values = conn
      .prepare("SELECT value_usd FROM usage_events ORDER BY session_id")
      .expect("prepare failed values")
      .query_map([], |row| row.get::<_, f64>(0))
      .expect("query failed values")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect failed values");
    assert_eq!(failed_output, 30.0);
    assert_eq!(failed_values, vec![11.0, 22.0]);
    assert!(pricing_value_resolution_repair_pending(&conn).expect("load repair marker"));

    conn
      .execute_batch("DROP TRIGGER fail_second_refresh_recalculation;")
      .expect("drop failure trigger");
    let catalog = refresh_pricing_catalog_atomically(&mut conn, Some(&official_entries))
      .expect("retry refresh");
    let refreshed_sol = catalog
      .iter()
      .find(|entry| entry.model_id == "gpt-5.6-sol")
      .expect("load refreshed GPT-5.6 Sol");
    let refreshed_values = conn
      .prepare("SELECT value_usd FROM usage_events ORDER BY session_id")
      .expect("prepare refreshed values")
      .query_map([], |row| row.get::<_, f64>(0))
      .expect("query refreshed values")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect refreshed values");

    assert_eq!(refreshed_sol.output_price_per_million, 42.0);
    assert_eq!(refreshed_values, vec![42.0, 42.0]);
    assert!(!pricing_value_resolution_repair_pending(&conn).expect("load repair marker"));
  }

  fn test_live_quota_snapshot(fetched_at: &str, remaining_percent: i64) -> LiveRateLimitSnapshot {
    LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: Some("Codex".to_string()),
      plan_type: Some("pro".to_string()),
      primary: Some(RateLimitWindowSnapshot {
        used_percent: 100 - remaining_percent,
        remaining_percent,
        window_duration_mins: Some(300),
        resets_at: Some("2026-07-12T05:00:00+08:00".to_string()),
        window_start: Some("2026-07-12T00:00:00+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: fetched_at.to_string(),
    }
  }

  fn test_session_quota_sample(
    session_id: &str,
    sample_timestamp: &str,
    remaining_percent: i64,
  ) -> crate::models::RateLimitSampleRecord {
    crate::models::RateLimitSampleRecord {
      source_kind: "session".to_string(),
      source_session_id: Some(session_id.to_string()),
      bucket: "five_hour".to_string(),
      sample_timestamp: sample_timestamp.to_string(),
      limit_id: Some("codex".to_string()),
      limit_name: Some("Codex".to_string()),
      plan_type: Some("pro".to_string()),
      window_start: "2026-07-12T00:00:00+08:00".to_string(),
      resets_at: "2026-07-12T05:00:00+08:00".to_string(),
      used_percent: 100 - remaining_percent,
      remaining_percent,
    }
  }

  #[test]
  fn background_live_rate_limit_fallback_prefers_newest_persisted_sample() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    database::replace_session_rate_limit_samples(
      &conn,
      "session-1",
      &[crate::models::RateLimitSampleRecord {
        source_kind: "session".to_string(),
        source_session_id: Some("session-1".to_string()),
        bucket: "five_hour".to_string(),
        sample_timestamp: "2026-03-27T00:00:00+08:00".to_string(),
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        window_start: "2026-03-27T00:00:00+08:00".to_string(),
        resets_at: "2026-03-27T05:00:00+08:00".to_string(),
        used_percent: 80,
        remaining_percent: 20,
      }],
    )
    .expect("insert session sample");
    insert_live_rate_limit_snapshot(
      &conn,
      &LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 12,
          remaining_percent: 88,
          window_duration_mins: Some(300),
          resets_at: Some("2026-03-27T05:05:00+08:00".to_string()),
          window_start: Some("2026-03-27T00:05:00+08:00".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-03-27T00:05:00+08:00".to_string(),
      },
    )
    .expect("insert live sample");
    drop(conn);
    let live_cache = refresh::LiveQuotaCache::new();

    let snapshot = load_display_live_rate_limit_fallback(&db_path, &live_cache)
      .expect("load fallback");

    assert_eq!(snapshot.fetched_at, "2026-03-27T00:05:00+08:00");
    assert_eq!(
      snapshot.primary.as_ref().map(|window| window.remaining_percent),
      Some(88)
    );

    live_cache.publish_live(
      Arc::new(LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 23,
          remaining_percent: 77,
          window_duration_mins: Some(300),
          resets_at: Some("2026-03-27T05:10:00+08:00".to_string()),
          window_start: Some("2026-03-27T00:10:00+08:00".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-03-27T00:10:00+08:00".to_string(),
      }),
      Instant::now(),
      Utc::now(),
    );
    let memory = load_display_live_rate_limit_fallback(&db_path, &live_cache)
      .expect("prefer newer memory");
    assert_eq!(memory.fetched_at, "2026-03-27T00:10:00+08:00");
    assert_eq!(
      memory.primary.as_ref().map(|window| window.remaining_percent),
      Some(77)
    );
  }

  #[test]
  fn persisted_primary_only_seven_day_snapshot_is_normalized_for_offline_fallback() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    insert_live_rate_limit_snapshot(
      &conn,
      &LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 21,
          remaining_percent: 79,
          window_duration_mins: Some(10_080),
          resets_at: Some("2026-04-02T00:00:00+08:00".to_string()),
          window_start: Some("2026-03-26T00:00:00+08:00".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-03-27T00:00:00+08:00".to_string(),
      },
    )
    .expect("insert legacy live sample");
    drop(conn);

    let snapshot = load_display_live_rate_limit_fallback(
      &db_path,
      &refresh::LiveQuotaCache::new(),
    )
    .expect("load offline fallback");

    assert!(snapshot.primary.is_none());
    assert_eq!(
      snapshot.secondary.map(|window| window.remaining_percent),
      Some(79)
    );
  }

  #[test]
  fn background_live_fallback_keeps_current_live_over_newer_session() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    database::replace_session_rate_limit_samples(
      &conn,
      "session-late",
      &[test_session_quota_sample(
        "session-late",
        "2026-07-12T00:10:00+08:00",
        20,
      )],
    )
    .expect("insert newer session sample");
    drop(conn);

    let live_cache = refresh::LiveQuotaCache::new();
    live_cache.publish_live(
      Arc::new(test_live_quota_snapshot(
        "2026-07-12T00:05:00+08:00",
        88,
      )),
      Instant::now(),
      Utc::now(),
    );

    let snapshot = load_display_live_rate_limit_fallback(&db_path, &live_cache)
      .expect("load fallback");

    assert_eq!(snapshot.fetched_at, "2026-07-12T00:05:00+08:00");
    assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(88));
  }

  #[test]
  fn background_live_fallback_prefers_persisted_live_over_newer_session() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    insert_live_rate_limit_snapshot(
      &conn,
      &test_live_quota_snapshot("2026-07-12T00:05:00+08:00", 88),
    )
    .expect("insert persisted live sample");
    database::replace_session_rate_limit_samples(
      &conn,
      "session-late",
      &[test_session_quota_sample(
        "session-late",
        "2026-07-12T00:10:00+08:00",
        20,
      )],
    )
    .expect("insert newer session sample");
    drop(conn);

    let snapshot = load_display_live_rate_limit_fallback(
      &db_path,
      &refresh::LiveQuotaCache::new(),
    )
    .expect("load fallback");

    assert_eq!(snapshot.fetched_at, "2026-07-12T00:05:00+08:00");
    assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(88));
  }

  #[test]
  fn background_live_fallback_uses_session_when_no_live_data_exists() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    database::replace_session_rate_limit_samples(
      &conn,
      "session-only",
      &[test_session_quota_sample(
        "session-only",
        "2026-07-12T00:10:00+08:00",
        20,
      )],
    )
    .expect("insert session sample");
    drop(conn);

    let snapshot = load_display_live_rate_limit_fallback(
      &db_path,
      &refresh::LiveQuotaCache::new(),
    )
    .expect("load history fallback");

    assert_eq!(snapshot.fetched_at, "2026-07-12T00:10:00+08:00");
    assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(20));
  }

  #[test]
  fn persisted_live_rate_limits_order_mixed_rfc3339_offsets_by_instant() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    insert_live_rate_limit_snapshot(
      &conn,
      &LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 10,
          remaining_percent: 90,
          window_duration_mins: Some(300),
          resets_at: Some("2026-07-10T14:00:00+08:00".to_string()),
          window_start: Some("2026-07-10T09:00:00+08:00".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-07-10T09:00:00+08:00".to_string(),
      },
    )
    .expect("insert earlier offset sample");
    insert_live_rate_limit_snapshot(
      &conn,
      &LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 20,
          remaining_percent: 80,
          window_duration_mins: Some(300),
          resets_at: Some("2026-07-10T07:00:00Z".to_string()),
          window_start: Some("2026-07-10T02:00:00Z".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-07-10T02:00:00Z".to_string(),
      },
    )
    .expect("insert later UTC sample");

    let snapshot = load_persisted_live_rate_limits_from_connection(&conn, None)
      .expect("load persisted sample");

    assert_eq!(snapshot.fetched_at, "2026-07-10T02:00:00Z");
    assert_eq!(
      snapshot.primary.as_ref().map(|window| window.remaining_percent),
      Some(80)
    );
  }

  #[test]
  fn persisted_live_rate_limits_do_not_combine_windows_from_different_samples() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    prepare_app_database(&db_path).expect("prepare app database");
    let conn = open_connection(&db_path).expect("open database");
    database::replace_session_rate_limit_samples(
      &conn,
      "session-same-instant",
      &[
        crate::models::RateLimitSampleRecord {
          source_kind: "session".to_string(),
          source_session_id: Some("session-same-instant".to_string()),
          bucket: "five_hour".to_string(),
          sample_timestamp: "2026-07-10T10:00:00+08:00".to_string(),
          limit_id: Some("codex".to_string()),
          limit_name: Some("Codex".to_string()),
          plan_type: Some("pro".to_string()),
          window_start: "2026-07-10T10:00:00+08:00".to_string(),
          resets_at: "2026-07-10T15:00:00+08:00".to_string(),
          used_percent: 30,
          remaining_percent: 70,
        },
        crate::models::RateLimitSampleRecord {
          source_kind: "session".to_string(),
          source_session_id: Some("session-same-instant".to_string()),
          bucket: "seven_day".to_string(),
          sample_timestamp: "2026-07-10T10:00:00+08:00".to_string(),
          limit_id: Some("codex".to_string()),
          limit_name: Some("Codex".to_string()),
          plan_type: Some("pro".to_string()),
          window_start: "2026-07-10T10:00:00+08:00".to_string(),
          resets_at: "2026-07-17T10:00:00+08:00".to_string(),
          used_percent: 40,
          remaining_percent: 60,
        },
      ],
    )
    .expect("insert complete session sample");
    insert_live_rate_limit_snapshot(
      &conn,
      &LiveRateLimitSnapshot {
        limit_id: Some("codex".to_string()),
        limit_name: Some("Codex".to_string()),
        plan_type: Some("pro".to_string()),
        primary: Some(RateLimitWindowSnapshot {
          used_percent: 25,
          remaining_percent: 75,
          window_duration_mins: Some(300),
          resets_at: Some("2026-07-10T07:00:00Z".to_string()),
          window_start: Some("2026-07-10T02:00:00Z".to_string()),
        }),
        secondary: None,
        fetched_at: "2026-07-10T02:00:00Z".to_string(),
      },
    )
    .expect("insert later primary-only row at the same instant");

    let snapshot = load_persisted_live_rate_limits_from_connection(&conn, None)
      .expect("load persisted sample");

    assert_eq!(snapshot.fetched_at, "2026-07-10T02:00:00Z");
    assert_eq!(
      snapshot.primary.as_ref().map(|window| window.remaining_percent),
      Some(75)
    );
    assert!(snapshot.secondary.is_none());
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
  fn menu_bar_api_value_falls_back_to_seven_days_when_five_hour_quota_is_absent() {
    let snapshot = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: None,
      secondary: Some(RateLimitWindowSnapshot {
        used_percent: 21,
        remaining_percent: 79,
        window_duration_mins: Some(10_080),
        resets_at: Some("2026-04-02T00:00:00+08:00".to_string()),
        window_start: Some("2026-03-26T00:00:00+08:00".to_string()),
      }),
      fetched_at: "2026-03-27T00:00:00+08:00".to_string(),
    };

    assert_eq!(
      effective_menu_bar_api_bucket("five_hour", Some(&snapshot)),
      "seven_day"
    );
  }

  #[test]
  fn menu_bar_api_value_keeps_five_hours_when_that_quota_exists() {
    let snapshot = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(RateLimitWindowSnapshot {
        used_percent: 12,
        remaining_percent: 88,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-27T05:00:00+08:00".to_string()),
        window_start: Some("2026-03-27T00:00:00+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-27T00:00:00+08:00".to_string(),
    };

    assert_eq!(
      effective_menu_bar_api_bucket("five_hour", Some(&snapshot)),
      "five_hour"
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

  #[test]
  fn tray_popup_monitor_lookup_undoes_status_item_scale() {
    let rect = Rect {
      position: Position::Physical((4000.0, 10.0).into()),
      size: tauri::Size::Physical((48u32, 48u32).into()),
    };

    let lookup_point = tray_event_monitor_lookup_point(rect, PhysicalPosition::new(4024.0, 24.0), 2.0);

    assert_eq!(lookup_point, PhysicalPosition::new(2012.0, 29.0));
  }

  #[test]
  fn tray_popup_monitor_scale_score_prefers_menu_bar_sized_rect() {
    let retina_rect = Rect {
      position: Position::Physical((4000.0, 10.0).into()),
      size: tauri::Size::Physical((48u32, 48u32).into()),
    };
    let standard_rect = Rect {
      position: Position::Physical((2000.0, 10.0).into()),
      size: tauri::Size::Physical((24u32, 24u32).into()),
    };

    assert_eq!(tray_monitor_scale_score(retina_rect, 2.0), 0.0);
    assert!(tray_monitor_scale_score(retina_rect, 1.0) > 0.0);
    assert_eq!(tray_monitor_scale_score(standard_rect, 1.0), 0.0);
    assert!(tray_monitor_scale_score(standard_rect, 2.0) > 0.0);
  }

  #[test]
  fn tray_popup_platform_policy_keeps_non_windows_menu_bar_popups_below() {
    assert!(!menu_bar_popup_opens_above_tray_for_policy(
      1040,
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      false,
    ));
  }

  #[test]
  fn tray_popup_platform_policy_allows_windows_bottom_taskbar_popups_above() {
    assert!(menu_bar_popup_opens_above_tray_for_policy(
      1040,
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      true,
    ));
    assert!(!menu_bar_popup_opens_above_tray_for_policy(
      20,
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      true,
    ));
  }

  #[test]
  fn tray_popup_position_clamps_to_selected_external_monitor() {
    let rect = Rect {
      position: Position::Physical((7250.0, 16.0).into()),
      size: tauri::Size::Physical((48u32, 48u32).into()),
    };
    let position = menu_bar_popup_geometry_for_monitor(
      rect,
      PhysicalPosition::new(7274.0, 24.0),
      PhysicalPosition::new(3840, 0),
      PhysicalSize::new(3456, 2234),
      2.0,
      MENU_BAR_POPUP_INITIAL_HEIGHT,
    )
    .position;

    assert_eq!(position.x, 6456);
    assert_eq!(position.y, 80);
  }

  #[cfg(target_os = "windows")]
  #[test]
  fn tray_popup_position_opens_above_bottom_taskbar() {
    let rect = Rect {
      position: Position::Physical((1780.0, 1040.0).into()),
      size: tauri::Size::Physical((32u32, 40u32).into()),
    };
    let position = menu_bar_popup_geometry_for_monitor(
      rect,
      PhysicalPosition::new(1796.0, 1060.0),
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      1.0,
      MENU_BAR_POPUP_INITIAL_HEIGHT,
    )
    .position;

    assert_eq!(position.x, 1500);
    assert_eq!(position.y, 772);
  }

  #[cfg(target_os = "windows")]
  #[test]
  fn tray_popup_position_grows_upward_above_bottom_taskbar() {
    let rect = Rect {
      position: Position::Physical((1780.0, 1040.0).into()),
      size: tauri::Size::Physical((32u32, 40u32).into()),
    };
    let compact = menu_bar_popup_geometry_for_monitor(
      rect,
      PhysicalPosition::new(1796.0, 1060.0),
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      1.0,
      360.0,
    );
    let expanded = menu_bar_popup_geometry_for_monitor(
      rect,
      PhysicalPosition::new(1796.0, 1060.0),
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(1920, 1080),
      1.0,
      700.0,
    );

    assert_eq!(compact.height, 360.0);
    assert_eq!(compact.position.y, 672);
    assert_eq!(expanded.height, 700.0);
    assert_eq!(expanded.position.y, 332);
    assert!(expanded.position.y < compact.position.y);
  }

  #[cfg(target_os = "windows")]
  #[test]
  fn tray_popup_position_uses_physical_window_height_on_scaled_windows_monitor() {
    let rect = Rect {
      position: Position::Physical((2370.0, 1380.0).into()),
      size: tauri::Size::Physical((48u32, 60u32).into()),
    };
    let geometry = menu_bar_popup_geometry_for_monitor(
      rect,
      PhysicalPosition::new(2394.0, 1410.0),
      PhysicalPosition::new(0, 0),
      PhysicalSize::new(2560, 1440),
      1.5,
      620.0,
    );

    assert_eq!(geometry.height, 620.0);
    assert_eq!(geometry.position.y, 438);
  }
}

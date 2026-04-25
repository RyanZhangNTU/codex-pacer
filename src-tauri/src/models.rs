use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawSession {
  pub session_id: String,
  pub parent_session_id: Option<String>,
  pub root_session_id: String,
  pub title: Option<String>,
  pub source_state: String,
  pub source_path: Option<String>,
  pub started_at: Option<String>,
  pub updated_at: Option<String>,
  pub model_ids: Vec<String>,
  pub contains_subagents: bool,
  pub agent_nickname: Option<String>,
  pub agent_role: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
  pub timestamp: String,
  pub model_id: String,
  pub usage: TokenUsage,
  pub plan_type: Option<String>,
  pub limit_id: Option<String>,
  pub limit_name: Option<String>,
  pub explicit_fast_mode: Option<bool>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvent {
  pub id: Option<i64>,
  pub session_id: String,
  pub timestamp: String,
  pub model_id: String,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub value_usd: f64,
  pub fast_mode_auto: bool,
  pub fast_mode_effective: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PricingCatalogEntry {
  pub model_id: String,
  pub display_name: String,
  pub input_price_per_million: f64,
  pub cached_input_price_per_million: f64,
  pub output_price_per_million: f64,
  pub effective_model_id: String,
  pub is_official: bool,
  pub note: Option<String>,
  pub source_url: String,
  pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncSettings {
  pub codex_home: Option<String>,
  pub auto_scan_enabled: bool,
  pub auto_scan_interval_minutes: i64,
  pub live_quota_refresh_interval_seconds: i64,
  pub default_fast_mode_for_new_gpt54_sessions: bool,
  pub hide_dock_icon_when_menu_bar_visible: bool,
  pub show_menu_bar_logo: bool,
  pub show_menu_bar_daily_api_value: bool,
  pub show_menu_bar_live_quota_percent: bool,
  pub menu_bar_live_quota_metric: String,
  pub menu_bar_live_quota_bucket: String,
  pub menu_bar_bucket: String,
  pub menu_bar_speed_show_emoji: bool,
  pub menu_bar_speed_fast_threshold_percent: i64,
  pub menu_bar_speed_slow_threshold_percent: i64,
  pub menu_bar_speed_healthy_emoji: String,
  pub menu_bar_speed_fast_emoji: String,
  pub menu_bar_speed_slow_emoji: String,
  pub menu_bar_popup_enabled: bool,
  pub menu_bar_popup_modules: Vec<String>,
  pub menu_bar_popup_show_reset_timeline: bool,
  pub menu_bar_popup_show_actions: bool,
  pub last_scan_started_at: Option<String>,
  pub last_scan_completed_at: Option<String>,
  pub updated_at: String,
}

impl Default for SyncSettings {
  fn default() -> Self {
    Self {
      codex_home: None,
      auto_scan_enabled: true,
      auto_scan_interval_minutes: 5,
      live_quota_refresh_interval_seconds: 300,
      default_fast_mode_for_new_gpt54_sessions: false,
      hide_dock_icon_when_menu_bar_visible: false,
      show_menu_bar_logo: true,
      show_menu_bar_daily_api_value: true,
      show_menu_bar_live_quota_percent: false,
      menu_bar_live_quota_metric: "remaining_percent".to_string(),
      menu_bar_live_quota_bucket: "five_hour".to_string(),
      menu_bar_bucket: "day".to_string(),
      menu_bar_speed_show_emoji: true,
      menu_bar_speed_fast_threshold_percent: 85,
      menu_bar_speed_slow_threshold_percent: 115,
      menu_bar_speed_healthy_emoji: "🟢".to_string(),
      menu_bar_speed_fast_emoji: "🔥".to_string(),
      menu_bar_speed_slow_emoji: "🐢".to_string(),
      menu_bar_popup_enabled: true,
      menu_bar_popup_modules: vec!["api_value".to_string(), "scan_freshness".to_string()],
      menu_bar_popup_show_reset_timeline: true,
      menu_bar_popup_show_actions: true,
      last_scan_started_at: None,
      last_scan_completed_at: None,
      updated_at: String::new(),
    }
  }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionProfile {
  pub plan_type: String,
  pub currency: String,
  pub monthly_price: f64,
  pub billing_anchor_day: i64,
  pub updated_at: String,
}

impl Default for SubscriptionProfile {
  fn default() -> Self {
    Self {
      plan_type: "plus".to_string(),
      currency: "USD".to_string(),
      monthly_price: 20.0,
      billing_anchor_day: 1,
      updated_at: String::new(),
    }
  }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConversationFilters {
  pub bucket: Option<String>,
  pub anchor: Option<String>,
  pub search: Option<String>,
  pub live_window_offset: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitSampleRecord {
  pub source_kind: String,
  pub source_session_id: Option<String>,
  pub bucket: String,
  pub sample_timestamp: String,
  pub limit_id: Option<String>,
  pub limit_name: Option<String>,
  pub plan_type: Option<String>,
  pub window_start: String,
  pub resets_at: String,
  pub used_percent: i64,
  pub remaining_percent: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OverviewStats {
  pub api_value_usd: f64,
  pub subscription_cost_usd: f64,
  pub payoff_ratio: f64,
  pub total_tokens: i64,
  pub conversation_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendPoint {
  pub label: String,
  pub timestamp: String,
  pub api_value_usd: f64,
  pub total_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitWindowSnapshot {
  pub used_percent: i64,
  pub remaining_percent: i64,
  pub window_duration_mins: Option<i64>,
  pub resets_at: Option<String>,
  pub window_start: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRateLimitSnapshot {
  pub limit_id: Option<String>,
  pub limit_name: Option<String>,
  pub plan_type: Option<String>,
  pub primary: Option<RateLimitWindowSnapshot>,
  pub secondary: Option<RateLimitWindowSnapshot>,
  pub fetched_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuBarPopupQuotaSnapshot {
  pub used_percent: i64,
  pub remaining_percent: i64,
  pub window_duration_mins: Option<i64>,
  pub resets_at: Option<String>,
  pub window_start: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuBarPopupSuggestedSpeed {
  pub percent: i64,
  pub display_value: String,
  pub emoji: String,
  pub status: String,
  pub remaining_time_percent: f64,
  pub remaining_percent: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuBarPopupSnapshot {
  pub fetched_at: String,
  pub refresh_interval_seconds: i64,
  pub selected_bucket: String,
  pub quota_5h: Option<MenuBarPopupQuotaSnapshot>,
  pub quota_7d: Option<MenuBarPopupQuotaSnapshot>,
  pub suggested_speed_7d: Option<MenuBarPopupSuggestedSpeed>,
  pub speed_fast_threshold_percent: i64,
  pub speed_slow_threshold_percent: i64,
  pub api_value_selected_bucket: f64,
  pub total_tokens_selected_bucket: i64,
  pub conversation_count_selected_bucket: usize,
  pub payoff_ratio: f64,
  pub last_scan_completed_at: Option<String>,
  pub live_quota_fetched_at: Option<String>,
  pub visible_modules: Vec<String>,
  pub show_reset_timeline: bool,
  pub show_actions: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaTrendPoint {
  pub label: String,
  pub timestamp: String,
  pub api_value_usd: f64,
  pub cumulative_api_value_usd: f64,
  pub total_tokens: i64,
  pub cumulative_tokens: i64,
  pub remaining_percent: Option<i64>,
  pub used_percent: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelShare {
  pub model_id: String,
  pub display_name: String,
  pub api_value_usd: f64,
  pub total_tokens: i64,
  pub conversation_count: usize,
  pub color: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompositionShare {
  pub category: String,
  pub label: String,
  pub api_value_usd: f64,
  pub total_tokens: i64,
  pub color: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OverviewResponse {
  pub bucket: String,
  pub anchor: String,
  pub window_start: String,
  pub window_end: String,
  pub live_window_offset: i64,
  pub live_window_count: usize,
  pub stats: OverviewStats,
  pub trend: Vec<TrendPoint>,
  pub quota_trend: Vec<QuotaTrendPoint>,
  pub model_shares: Vec<ModelShare>,
  pub composition_shares: Vec<CompositionShare>,
  pub live_rate_limits: Option<LiveRateLimitSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardSnapshot {
  pub overview: OverviewResponse,
  pub conversations: Vec<ConversationListItem>,
  pub sync_settings: SyncSettings,
  pub subscription_profile: SubscriptionProfile,
  pub live_rate_limits: Option<LiveRateLimitSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationListItem {
  pub root_session_id: String,
  pub title: String,
  pub started_at: Option<String>,
  pub updated_at: Option<String>,
  pub model_ids: Vec<String>,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub session_count: usize,
  pub subagent_count: usize,
  pub has_fast_mode: bool,
  pub api_value_usd: f64,
  pub subscription_share: f64,
  pub source_states: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSessionSummary {
  pub session_id: String,
  pub parent_session_id: Option<String>,
  pub agent_nickname: Option<String>,
  pub agent_role: Option<String>,
  pub model_ids: Vec<String>,
  pub started_at: Option<String>,
  pub updated_at: Option<String>,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub api_value_usd: f64,
  pub fast_mode_auto: bool,
  pub fast_mode_effective: bool,
  pub fast_mode_override: Option<bool>,
  pub source_state: String,
  pub source_path: Option<String>,
  pub is_subagent: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationTurnPoint {
  pub session_id: String,
  pub turn_id: String,
  pub started_at: Option<String>,
  pub completed_at: Option<String>,
  pub last_activity_at: String,
  pub status: String,
  pub user_message: Option<String>,
  pub assistant_message: Option<String>,
  pub model_ids: Vec<String>,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub value_usd: f64,
  pub fast_mode_effective: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationDetail {
  pub root_session_id: String,
  pub title: String,
  pub started_at: Option<String>,
  pub updated_at: Option<String>,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub api_value_usd: f64,
  pub subscription_share: f64,
  pub multiple_agent: bool,
  pub source_states: Vec<String>,
  pub sessions: Vec<ConversationSessionSummary>,
  pub turns: Vec<ConversationTurnPoint>,
  pub model_breakdown: Vec<ModelShare>,
  pub composition_breakdown: Vec<CompositionShare>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
  pub codex_home: String,
  pub scanned_files: usize,
  pub imported_sessions: usize,
  pub updated_sessions: usize,
  pub missing_sessions: usize,
  pub last_completed_at: String,
}

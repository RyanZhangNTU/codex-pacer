use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use chrono::{
  DateTime, Datelike, Days, Local, LocalResult, Months, NaiveDate, NaiveDateTime, TimeZone,
  Timelike,
};
use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use crate::database::{get_subscription_profile, open_connection};
use crate::models::{
  CompositionShare, ConversationDetail, ConversationFilters, ConversationListItem, ConversationPage,
  ConversationSessionSummary, ConversationTurnPoint, LiveRateLimitSnapshot, ModelShare,
  OverviewResponse, OverviewStats, PricingCatalogEntry, QuotaTrendPoint, SubscriptionProfile, TokenUsage,
  TrendPoint,
};
use crate::pricing::{
  calculate_value_usd, display_name_for_model, load_catalog_map, model_color, normalize_model_id,
  resolve_pricing,
};

const SQL_SESSIONS: &str = include_str!("../sql/queries/sessions.sql");
const SQL_SESSIONS_FOR_ROOT: &str = include_str!("../sql/queries/sessions_for_root.sql");
const SQL_USAGE_EVENTS_FOR_ROOT: &str = include_str!("../sql/queries/usage_events_for_root.sql");
const MAX_LIVE_RATE_LIMIT_WINDOWS: usize = 64;

#[derive(Debug, Clone)]
struct SessionRow {
  session_id: String,
  root_session_id: String,
  parent_session_id: Option<String>,
  title: String,
  source_state: String,
  source_path: Option<String>,
  started_at: Option<String>,
  updated_at: Option<String>,
  agent_nickname: Option<String>,
  agent_role: Option<String>,
}

#[derive(Debug, Clone)]
struct EventRow {
  session_id: String,
  timestamp: String,
  model_id: String,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
  reasoning_output_tokens: i64,
  total_tokens: i64,
  value_usd: f64,
  fast_mode_auto: bool,
  fast_mode_effective: bool,
}

#[derive(Debug, Clone)]
struct Window {
  bucket: String,
  anchor: String,
  start: DateTime<Local>,
  end: DateTime<Local>,
}

#[derive(Debug, Clone)]
struct ResolvedWindow {
  window: Window,
  live_window_offset: i64,
  live_window_count: usize,
}

#[derive(Debug, Clone)]
struct TrendBin {
  label: String,
  timestamp: String,
  start: DateTime<Local>,
  end: DateTime<Local>,
}

#[derive(Debug, Clone)]
struct QuotaSample {
  timestamp: DateTime<Local>,
  used_percent: i64,
}

#[derive(Debug, Clone)]
struct RateLimitWindowSummary {
  start: DateTime<Local>,
  end: DateTime<Local>,
}

#[cfg(test)]
#[allow(dead_code)]
pub struct DashboardData {
  pub overview: OverviewResponse,
  pub conversation_page: ConversationPage,
  pub subscription_profile: SubscriptionProfile,
}

pub fn get_overview_with_connection(
  conn: &Connection,
  bucket: Option<String>,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<OverviewResponse, String> {
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let resolved_window = resolve_window(
    &conn,
    bucket.clone(),
    anchor.clone(),
    custom_start.clone(),
    custom_end.clone(),
    &[],
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    live_window_offset,
  )?;
  let sessions = load_sessions(&conn).map_err(|error| error.to_string())?;
  let events = load_events_in_window(&conn, &resolved_window.window).map_err(|error| error.to_string())?;
  let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;
  build_overview(
    &conn,
    &sessions,
    &events,
    &profile,
    &catalog,
    &resolved_window,
    live_rate_limits,
  )
}

pub fn get_quota_trend(
  db_path: &Path,
  bucket: String,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
) -> Result<Vec<QuotaTrendPoint>, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let resolved_window = resolve_window(
    &conn,
    Some(bucket),
    None,
    None,
    None,
    &[],
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    None,
  )?;
  let window = &resolved_window.window;
  let filtered_events = load_events_in_window(&conn, window).map_err(|error| error.to_string())?;

  Ok(build_quota_trend(
    &conn,
    window,
    &filtered_events,
    live_rate_limits.as_ref(),
  ))
}

pub fn get_window_api_value(
  db_path: &Path,
  bucket: String,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<f64, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  if bucket == "total" {
    return sum_all_api_value(&conn).map_err(|error| error.to_string());
  }

  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let resolved_window = resolve_window(
    &conn,
    Some(bucket),
    anchor,
    custom_start,
    custom_end,
    &[],
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    live_window_offset,
  )?;
  sum_window_api_value_sql(&conn, &resolved_window.window).map_err(|error| error.to_string())
}

pub fn list_conversations(
  db_path: &Path,
  filters: Option<ConversationFilters>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
) -> Result<ConversationPage, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let filters = filters.unwrap_or_default();
  let resolved_window = resolve_window(
    &conn,
    filters.bucket.clone(),
    filters.anchor.clone(),
    filters.custom_start.clone(),
    filters.custom_end.clone(),
    &[],
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    filters.live_window_offset,
  )?;
  let limit = filters.limit.unwrap_or(50).clamp(1, 100);
  load_conversation_page_sql(
    &conn,
    &profile,
    &resolved_window.window,
    filters.search,
    filters.cursor.as_deref(),
    limit,
  )
}

#[cfg(test)]
pub fn load_dashboard_data(
  db_path: &Path,
  bucket: Option<String>,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  search: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
  include_conversations: bool,
) -> Result<DashboardData, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let resolved_window = resolve_window(
    &conn,
    bucket.clone(),
    anchor.clone(),
    custom_start.clone(),
    custom_end.clone(),
    &[],
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    live_window_offset,
  )?;
  let sessions = load_sessions(&conn).map_err(|error| error.to_string())?;
  let events = load_events_in_window(&conn, &resolved_window.window).map_err(|error| error.to_string())?;
  let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;

  let overview = build_overview(
    &conn,
    &sessions,
    &events,
    &profile,
    &catalog,
    &resolved_window,
    live_rate_limits.clone(),
  )?;
  let conversation_page = if include_conversations {
    load_conversation_page_sql(&conn, &profile, &resolved_window.window, search, None, 50)?
  } else {
    ConversationPage {
      items: Vec::new(),
      next_cursor: None,
      has_more: false,
    }
  };

  Ok(DashboardData {
    overview,
    conversation_page,
    subscription_profile: profile,
  })
}

fn load_conversation_page_sql(
  conn: &Connection,
  profile: &SubscriptionProfile,
  window: &Window,
  search: Option<String>,
  cursor: Option<&str>,
  limit: usize,
) -> Result<ConversationPage, String> {
  let offset = cursor.and_then(|value| value.parse::<usize>().ok()).unwrap_or(0);
  let search_pattern = search
    .filter(|value| !value.trim().is_empty())
    .map(|value| format!("%{}%", value.to_ascii_lowercase()));
  let include_empty = i64::from(window.bucket == "total");
  let event_filter = if epoch_backfill_complete(conn) || !has_legacy_usage_events(conn).map_err(|error| error.to_string())? {
    "e.timestamp_ms >= ?1 AND e.timestamp_ms < ?2"
  } else {
    "((e.timestamp_ms >= ?1 AND e.timestamp_ms < ?2) OR (e.timestamp_ms IS NULL AND unixepoch(e.timestamp) * 1000 >= ?1 AND unixepoch(e.timestamp) * 1000 < ?2))"
  };
  let sql = format!(
    "
    WITH matching_roots AS (
      SELECT DISTINCT root_session_id
      FROM sessions
      WHERE ?3 IS NULL
         OR lower(COALESCE(title, '')) LIKE ?3
         OR lower(root_session_id) LIKE ?3
         OR lower(session_id) LIKE ?3
    ), session_groups AS (
      SELECT s.root_session_id,
             COALESCE(NULLIF(MAX(title), ''), s.root_session_id) AS title,
             MIN(started_at) AS started_at,
             MAX(updated_at) AS updated_at,
             COUNT(*) AS session_count,
             GROUP_CONCAT(DISTINCT source_state) AS source_states
      FROM sessions s
      JOIN matching_roots mr ON mr.root_session_id = s.root_session_id
      GROUP BY s.root_session_id
    ), event_groups AS (
      SELECT s.root_session_id,
             GROUP_CONCAT(DISTINCT e.model_id) AS model_ids,
             SUM(e.input_tokens) AS input_tokens,
             SUM(e.cached_input_tokens) AS cached_input_tokens,
             SUM(e.output_tokens) AS output_tokens,
             SUM(e.reasoning_output_tokens) AS reasoning_output_tokens,
             SUM(e.total_tokens) AS total_tokens,
             SUM(e.value_usd) AS api_value_usd,
             MAX(e.fast_mode_effective) AS has_fast_mode
      FROM usage_events e
      JOIN sessions s ON s.session_id = e.session_id
      WHERE {event_filter}
      GROUP BY s.root_session_id
    )
    SELECT sg.root_session_id, sg.title, sg.started_at, sg.updated_at,
           COALESCE(eg.model_ids, ''), COALESCE(eg.input_tokens, 0),
           COALESCE(eg.cached_input_tokens, 0), COALESCE(eg.output_tokens, 0),
           COALESCE(eg.reasoning_output_tokens, 0), COALESCE(eg.total_tokens, 0),
           sg.session_count, COALESCE(eg.has_fast_mode, 0),
           COALESCE(eg.api_value_usd, 0.0), COALESCE(sg.source_states, '')
    FROM session_groups sg
    LEFT JOIN event_groups eg ON eg.root_session_id = sg.root_session_id
    WHERE ?4 = 1 OR COALESCE(eg.total_tokens, 0) > 0
    ORDER BY COALESCE(eg.api_value_usd, 0.0) DESC, sg.updated_at DESC, sg.root_session_id ASC
    LIMIT ?5 OFFSET ?6
    "
  );
  let fetch_limit = limit.saturating_add(1);
  let mut stmt = conn.prepare(&sql).map_err(|error| error.to_string())?;
  let rows = stmt
    .query_map(
      rusqlite::params![
        window.start.timestamp_millis(),
        window.end.timestamp_millis(),
        search_pattern,
        include_empty,
        fetch_limit as i64,
        offset as i64,
      ],
      |row| {
        let session_count = row.get::<_, i64>(10)?.max(0) as usize;
        let api_value_usd = row.get::<_, f64>(12)?;
        Ok(ConversationListItem {
          root_session_id: row.get(0)?,
          title: row.get(1)?,
          started_at: row.get(2)?,
          updated_at: row.get(3)?,
          model_ids: split_sorted_csv(row.get::<_, String>(4)?),
          input_tokens: row.get(5)?,
          cached_input_tokens: row.get(6)?,
          output_tokens: row.get(7)?,
          reasoning_output_tokens: row.get(8)?,
          total_tokens: row.get(9)?,
          session_count,
          subagent_count: session_count.saturating_sub(1),
          has_fast_mode: row.get::<_, i64>(11)? != 0,
          api_value_usd,
          subscription_share: if profile.monthly_price > 0.0 {
            api_value_usd / profile.monthly_price
          } else {
            0.0
          },
          source_states: split_sorted_csv(row.get::<_, String>(13)?),
        })
      },
    )
    .map_err(|error| error.to_string())?;
  let mut items = rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|error| error.to_string())?;
  let has_more = items.len() > limit;
  items.truncate(limit);
  Ok(ConversationPage {
    items,
    next_cursor: has_more.then(|| offset.saturating_add(limit).to_string()),
    has_more,
  })
}

fn split_sorted_csv(value: String) -> Vec<String> {
  let mut values = value
    .split(',')
    .filter(|item| !item.is_empty())
    .map(ToString::to_string)
    .collect::<Vec<_>>();
  values.sort();
  values.dedup();
  values
}

fn build_overview(
  conn: &Connection,
  sessions: &HashMap<String, SessionRow>,
  events: &[EventRow],
  profile: &SubscriptionProfile,
  catalog: &HashMap<String, PricingCatalogEntry>,
  resolved_window: &ResolvedWindow,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
) -> Result<OverviewResponse, String> {
  let window = &resolved_window.window;

  let mut conversation_ids = HashSet::new();
  let mut total_value_usd = 0.0;
  let mut total_tokens = 0i64;
  let mut model_shares: HashMap<String, ModelShareAccumulator> = HashMap::new();

  for event in events {
    total_value_usd += event.value_usd;
    total_tokens += event.total_tokens;
    if let Some(session) = sessions.get(&event.session_id) {
      conversation_ids.insert(session.root_session_id.clone());
      let model = model_shares.entry(event.model_id.clone()).or_default();
      model.api_value_usd += event.value_usd;
      model.total_tokens += event.total_tokens;
      model.conversation_ids.insert(session.root_session_id.clone());
    }
  }

  let subscription_cost_usd =
    subscription_cost_for_window(window, profile.monthly_price, profile.billing_anchor_day as u32);
  let payoff_ratio = if subscription_cost_usd > 0.0 {
    total_value_usd / subscription_cost_usd
  } else {
    0.0
  };

  let trend = build_trend(window, events);
  let quota_trend = build_quota_trend(conn, window, events, live_rate_limits.as_ref());
  let composition_breakdown = build_composition_breakdown(events, catalog);
  let mut model_breakdown = model_shares
    .into_iter()
    .map(|(model_id, value)| ModelShare {
      display_name: display_name_for_model(&model_id),
      color: model_color(&model_id).to_string(),
      model_id,
      api_value_usd: value.api_value_usd,
      total_tokens: value.total_tokens,
      conversation_count: value.conversation_ids.len(),
    })
    .collect::<Vec<_>>();
  model_breakdown.sort_by(|left, right| right.api_value_usd.total_cmp(&left.api_value_usd));

  Ok(OverviewResponse {
    bucket: window.bucket.clone(),
    anchor: window.anchor.clone(),
    window_start: window.start.to_rfc3339(),
    window_end: window.end.to_rfc3339(),
    live_window_offset: resolved_window.live_window_offset,
    live_window_count: resolved_window.live_window_count,
    stats: OverviewStats {
      api_value_usd: total_value_usd,
      subscription_cost_usd,
      payoff_ratio,
      total_tokens,
      conversation_count: conversation_ids.len(),
    },
    trend,
    quota_trend,
    model_shares: model_breakdown,
    composition_shares: composition_breakdown,
    live_rate_limits,
  })
}

pub fn get_conversation_detail(
  db_path: &Path,
  root_session_id: &str,
  turn_cursor: Option<usize>,
) -> Result<ConversationDetail, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let sessions = load_sessions_for_root_session(&conn, root_session_id).map_err(|error| error.to_string())?;
  let events = load_events_for_root_session(&conn, root_session_id).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;

  let mut conversation_sessions = sessions.values().cloned().collect::<Vec<_>>();

  if conversation_sessions.is_empty() {
    return Err(format!("Conversation {} was not found.", root_session_id));
  }

  conversation_sessions.sort_by(|left, right| left.started_at.cmp(&right.started_at));

  let mut title = String::new();
  let mut started_at = None;
  let mut updated_at = None;
  let mut source_states = HashSet::new();
  let mut total_input = 0i64;
  let mut total_cached_input = 0i64;
  let mut total_output = 0i64;
  let mut total_reasoning = 0i64;
  let mut total_tokens = 0i64;
  let mut total_value_usd = 0.0;
  let mut model_breakdown: HashMap<String, ModelShareAccumulator> = HashMap::new();
  let mut per_session: HashMap<String, ConversationSessionAccumulator> = HashMap::new();
  let mut detail_turns = Vec::new();
  let mut conversation_events = Vec::new();
  let mut seen_real_turn_ids = HashSet::new();

  for session in &conversation_sessions {
    if title.is_empty() && !session.title.is_empty() {
      title = session.title.clone();
    }
    started_at = min_option_string(started_at, session.started_at.clone());
    updated_at = max_option_string(updated_at, session.updated_at.clone());
    source_states.insert(session.source_state.clone());
    per_session.insert(
      session.session_id.clone(),
      ConversationSessionAccumulator {
        parent_session_id: session.parent_session_id.clone(),
        agent_nickname: session.agent_nickname.clone(),
        agent_role: session.agent_role.clone(),
        model_ids: HashSet::new(),
        started_at: session.started_at.clone(),
        updated_at: session.updated_at.clone(),
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_output_tokens: 0,
        total_tokens: 0,
        api_value_usd: 0.0,
        fast_mode_auto: false,
        fast_mode_effective: false,
        source_state: session.source_state.clone(),
        source_path: session.source_path.clone(),
      },
    );
  }

  for event in &events {
    if !sessions.contains_key(&event.session_id) {
      continue;
    }

    conversation_events.push(event.clone());

    total_input += event.input_tokens;
    total_cached_input += event.cached_input_tokens;
    total_output += event.output_tokens;
    total_reasoning += event.reasoning_output_tokens;
    total_tokens += event.total_tokens;
    total_value_usd += event.value_usd;

    let model = model_breakdown.entry(event.model_id.clone()).or_default();
    model.api_value_usd += event.value_usd;
    model.total_tokens += event.total_tokens;
    model.conversation_ids.insert(root_session_id.to_string());

    if let Some(summary) = per_session.get_mut(&event.session_id) {
      summary.model_ids.insert(event.model_id.clone());
      summary.input_tokens += event.input_tokens;
      summary.cached_input_tokens += event.cached_input_tokens;
      summary.output_tokens += event.output_tokens;
      summary.reasoning_output_tokens += event.reasoning_output_tokens;
      summary.total_tokens += event.total_tokens;
      summary.api_value_usd += event.value_usd;
      summary.fast_mode_auto |= event.fast_mode_auto;
      summary.fast_mode_effective |= event.fast_mode_effective;
    }
  }

  for session in &conversation_sessions {
    let turns = build_turns_for_session(session, &catalog)?;
    let mut turns = filter_replayed_turns_for_session(session, turns, &mut seen_real_turn_ids);
    detail_turns.append(&mut turns);
  }
  detail_turns.sort_by(|left, right| {
    left
      .last_activity_at
      .cmp(&right.last_activity_at)
      .then_with(|| left.session_id.cmp(&right.session_id))
      .then_with(|| left.turn_id.cmp(&right.turn_id))
  });
  let already_loaded = turn_cursor.unwrap_or(0);
  let page_end = detail_turns.len().saturating_sub(already_loaded);
  let page_start = page_end.saturating_sub(40);
  let turn_page = detail_turns[page_start..page_end].to_vec();
  let has_more_turns = page_start > 0;
  let next_turn_cursor = has_more_turns.then_some(already_loaded.saturating_add(turn_page.len()));

  let mut session_summaries = Vec::new();
  for session in conversation_sessions {
    let summary = per_session.remove(&session.session_id).unwrap_or_default();
    session_summaries.push(ConversationSessionSummary {
      session_id: session.session_id.clone(),
      parent_session_id: summary.parent_session_id,
      agent_nickname: summary.agent_nickname,
      agent_role: summary.agent_role,
      model_ids: sorted_strings(summary.model_ids),
      started_at: summary.started_at,
      updated_at: summary.updated_at,
      input_tokens: summary.input_tokens,
      cached_input_tokens: summary.cached_input_tokens,
      output_tokens: summary.output_tokens,
      reasoning_output_tokens: summary.reasoning_output_tokens,
      total_tokens: summary.total_tokens,
      api_value_usd: summary.api_value_usd,
      fast_mode_auto: summary.fast_mode_auto,
      fast_mode_effective: summary.fast_mode_effective,
      fast_mode_override: None,
      source_state: summary.source_state,
      source_path: summary.source_path,
      is_subagent: session.parent_session_id.is_some(),
    });
  }
  let mut model_breakdown = model_breakdown
    .into_iter()
    .map(|(model_id, aggregate)| ModelShare {
      model_id: model_id.clone(),
      display_name: display_name_for_model(&model_id),
      api_value_usd: aggregate.api_value_usd,
      total_tokens: aggregate.total_tokens,
      conversation_count: aggregate.conversation_ids.len(),
      color: model_color(&model_id).to_string(),
    })
    .collect::<Vec<_>>();
  model_breakdown.sort_by(|left, right| right.api_value_usd.total_cmp(&left.api_value_usd));
  let composition_breakdown = build_composition_breakdown(&conversation_events, &catalog);

  if title.trim().is_empty() {
    title = root_session_id.to_string();
  }

  Ok(ConversationDetail {
    root_session_id: root_session_id.to_string(),
    title,
    started_at,
    updated_at,
    input_tokens: total_input,
    cached_input_tokens: total_cached_input,
    output_tokens: total_output,
    reasoning_output_tokens: total_reasoning,
    total_tokens,
    api_value_usd: total_value_usd,
    subscription_share: if profile.monthly_price > 0.0 {
      total_value_usd / profile.monthly_price
    } else {
      0.0
    },
    multiple_agent: session_summaries.len() > 1,
    source_states: sorted_strings(source_states),
    sessions: session_summaries,
    turns: turn_page,
    next_turn_cursor,
    has_more_turns,
    model_breakdown,
    composition_breakdown,
  })
}

fn build_turns_for_session(
  session: &SessionRow,
  catalog: &HashMap<String, PricingCatalogEntry>,
) -> Result<Vec<ConversationTurnPoint>, String> {
  let Some(source_path) = session.source_path.as_deref() else {
    return Ok(Vec::new());
  };

  let path = Path::new(source_path);
  let Ok(file) = File::open(path) else {
    return Ok(Vec::new());
  };

  let mut turns = Vec::new();
  let mut active_turn_index: Option<usize> = None;
  let mut turn_sequence = 0usize;
  let mut current_model: Option<String> = None;
  let mut previous_usage: Option<TokenUsage> = None;

  for line in BufReader::new(file).lines().map_while(Result::ok) {
    let Ok(value) = serde_json::from_str::<Value>(&line) else {
      continue;
    };

    let timestamp = value
      .get("timestamp")
      .and_then(Value::as_str)
      .map(ToString::to_string);

    match value.get("type").and_then(Value::as_str).unwrap_or_default() {
      "turn_context" => {
        if let Some(model) = value
          .get("payload")
          .and_then(|payload| payload.get("model"))
          .and_then(Value::as_str)
        {
          current_model = Some(normalize_model_id(model));
        }
      }
      "event_msg" => {
        let payload = value.get("payload").unwrap_or(&Value::Null);
        match payload.get("type").and_then(Value::as_str).unwrap_or_default() {
          "task_started" => {
            close_active_turn(&mut turns, &mut active_turn_index, timestamp.as_deref(), None);
            let turn_id = payload.get("turn_id").and_then(Value::as_str);
            start_turn(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              turn_id,
              &mut turn_sequence,
              session.session_id.clone(),
            );
          }
          "user_message" => {
            let message = payload
              .get("message")
              .and_then(Value::as_str)
              .and_then(compact_text_preview);
            attach_user_message(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              message,
              &mut turn_sequence,
              session.session_id.clone(),
            );
          }
          "agent_message" => {
            let message = payload
              .get("message")
              .and_then(Value::as_str)
              .and_then(compact_text_preview);
            let phase = payload.get("phase").and_then(Value::as_str);
            attach_assistant_message(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              message,
              phase,
              &mut turn_sequence,
              session.session_id.clone(),
            );
          }
          "task_complete" => {
            close_active_turn(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              Some("completed"),
            );
          }
          "turn_aborted" => {
            close_active_turn(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              Some("aborted"),
            );
          }
          "token_count" => {
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

            if previous_usage.as_ref() == Some(&usage) {
              continue;
            }

            let delta = if let Some(previous) = previous_usage.as_ref() {
              if usage.total_tokens <= previous.total_tokens {
                continue;
              }
              diff_usage(previous, &usage)
            } else {
              usage.clone()
            };
            previous_usage = Some(usage);

            if is_zero_delta(&delta) {
              continue;
            }

            let turn_index = ensure_active_turn(
              &mut turns,
              &mut active_turn_index,
              timestamp.as_deref(),
              &mut turn_sequence,
              session.session_id.clone(),
            );
            let model_id = current_model.clone().unwrap_or_else(|| "unknown".to_string());
            let value_usd = calculate_value_usd(&delta, resolve_pricing(catalog, &model_id).as_ref());
            let turn = &mut turns[turn_index];
            turn.model_ids.insert(model_id);
            turn.input_tokens += delta.input_tokens;
            turn.cached_input_tokens += delta.cached_input_tokens;
            turn.output_tokens += delta.output_tokens;
            turn.reasoning_output_tokens += delta.reasoning_output_tokens;
            turn.total_tokens += delta.total_tokens;
            turn.value_usd += value_usd;
            turn.fast_mode_effective = false;
            update_turn_activity(turn, timestamp.as_deref());
          }
          _ => {}
        }
      }
      _ => {}
    }
  }

  if let Some(index) = active_turn_index {
    let inferred_status = infer_turn_status(&turns[index]);
    close_active_turn(&mut turns, &mut active_turn_index, None, Some(inferred_status));
  }

  Ok(
    turns
      .into_iter()
      .filter(|turn| turn.total_tokens > 0)
      .map(|turn| turn.into_point())
      .collect(),
  )
}

fn filter_replayed_turns_for_session(
  session: &SessionRow,
  turns: Vec<ConversationTurnPoint>,
  seen_real_turn_ids: &mut HashSet<String>,
) -> Vec<ConversationTurnPoint> {
  let mut filtered = Vec::new();

  for turn in turns {
    let is_real_turn_id = !is_synthetic_turn_id(&turn.turn_id);
    let is_replayed_duplicate =
      session.parent_session_id.is_some() && is_real_turn_id && seen_real_turn_ids.contains(&turn.turn_id);

    if is_replayed_duplicate {
      continue;
    }

    if is_real_turn_id {
      seen_real_turn_ids.insert(turn.turn_id.clone());
    }
    filtered.push(turn);
  }

  filtered
}

fn is_synthetic_turn_id(turn_id: &str) -> bool {
  turn_id.starts_with("turn-")
    && turn_id[5..].chars().all(|character| character.is_ascii_digit())
}

fn attach_user_message(
  turns: &mut Vec<SourceTurnAccumulator>,
  active_turn_index: &mut Option<usize>,
  timestamp: Option<&str>,
  message: Option<String>,
  turn_sequence: &mut usize,
  session_id: String,
) {
  let turn_index = if let Some(index) = *active_turn_index {
    if turns[index].user_message.is_none()
      && turns[index].assistant_message.is_none()
      && turns[index].total_tokens == 0
    {
      if turns[index].started_at.is_none() {
        turns[index].started_at = timestamp.map(ToString::to_string);
      }
      index
    } else {
      close_active_turn(turns, active_turn_index, timestamp, None);
      start_turn(turns, active_turn_index, timestamp, None, turn_sequence, session_id)
    }
  } else {
    start_turn(turns, active_turn_index, timestamp, None, turn_sequence, session_id)
  };

  if let Some(message) = message {
    turns[turn_index].user_message = Some(message);
  }
  update_turn_activity(&mut turns[turn_index], timestamp);
}

fn attach_assistant_message(
  turns: &mut Vec<SourceTurnAccumulator>,
  active_turn_index: &mut Option<usize>,
  timestamp: Option<&str>,
  message: Option<String>,
  phase: Option<&str>,
  turn_sequence: &mut usize,
  session_id: String,
) {
  let turn_index = if let Some(index) = *active_turn_index {
    index
  } else {
    start_turn(turns, active_turn_index, timestamp, None, turn_sequence, session_id)
  };

  if let Some(message) = message {
    let should_replace = matches!(phase, Some("final_answer"))
      || turns[turn_index].assistant_message.is_none()
      || turns[turn_index].status == "aborted";
    if should_replace {
      turns[turn_index].assistant_message = Some(message);
    }
  }
  if matches!(phase, Some("final_answer")) {
    turns[turn_index].status = "completed".to_string();
  }
  update_turn_activity(&mut turns[turn_index], timestamp);
}

fn ensure_active_turn(
  turns: &mut Vec<SourceTurnAccumulator>,
  active_turn_index: &mut Option<usize>,
  timestamp: Option<&str>,
  turn_sequence: &mut usize,
  session_id: String,
) -> usize {
  match *active_turn_index {
    Some(index) => index,
    None => start_turn(turns, active_turn_index, timestamp, None, turn_sequence, session_id),
  }
}

fn start_turn(
  turns: &mut Vec<SourceTurnAccumulator>,
  active_turn_index: &mut Option<usize>,
  timestamp: Option<&str>,
  requested_turn_id: Option<&str>,
  turn_sequence: &mut usize,
  session_id: String,
) -> usize {
  let next_sequence = *turn_sequence;
  *turn_sequence += 1;
  turns.push(SourceTurnAccumulator {
    session_id,
    turn_id: requested_turn_id
      .map(ToString::to_string)
      .unwrap_or_else(|| format!("turn-{:04}", next_sequence + 1)),
    started_at: timestamp.map(ToString::to_string),
    completed_at: None,
    last_activity_at: timestamp.map(ToString::to_string).unwrap_or_default(),
    status: "running".to_string(),
    user_message: None,
    assistant_message: None,
    model_ids: HashSet::new(),
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_output_tokens: 0,
    total_tokens: 0,
    value_usd: 0.0,
    fast_mode_effective: false,
  });
  let index = turns.len() - 1;
  *active_turn_index = Some(index);
  index
}

fn close_active_turn(
  turns: &mut [SourceTurnAccumulator],
  active_turn_index: &mut Option<usize>,
  timestamp: Option<&str>,
  status: Option<&str>,
) {
  let Some(index) = *active_turn_index else {
    return;
  };
  let turn = &mut turns[index];
  if turn.completed_at.is_none() {
    turn.completed_at = timestamp.map(ToString::to_string);
  }
  if !turn.completed_at.as_deref().unwrap_or_default().is_empty() {
    turn.last_activity_at = turn.completed_at.clone().unwrap_or_default();
  }
  turn.status = status
    .map(ToString::to_string)
    .unwrap_or_else(|| infer_turn_status(turn).to_string());
  *active_turn_index = None;
}

fn update_turn_activity(turn: &mut SourceTurnAccumulator, timestamp: Option<&str>) {
  if turn.started_at.is_none() {
    turn.started_at = timestamp.map(ToString::to_string);
  }
  if let Some(timestamp) = timestamp {
    turn.last_activity_at = timestamp.to_string();
  } else if turn.last_activity_at.is_empty() {
    turn.last_activity_at = turn.started_at.clone().unwrap_or_default();
  }
}

fn infer_turn_status(turn: &SourceTurnAccumulator) -> &'static str {
  if turn.status == "aborted" {
    "aborted"
  } else if turn.assistant_message.is_some() {
    "completed"
  } else {
    "running"
  }
}

fn compact_text_preview(value: &str) -> Option<String> {
  let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
  if compact.is_empty() {
    return None;
  }

  let preview = compact.chars().take(220).collect::<String>();
  if compact.chars().count() > 220 {
    Some(format!("{preview}..."))
  } else {
    Some(preview)
  }
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

fn read_i64(value: &Value, key: &str) -> i64 {
  value.get(key).and_then(Value::as_i64).unwrap_or_default()
}

fn read_total_tokens(value: &Value) -> i64 {
  value.get("total_tokens").and_then(Value::as_i64).unwrap_or_else(|| {
    read_i64(value, "input_tokens") + read_i64(value, "output_tokens")
  })
}

fn build_composition_breakdown(
  events: &[EventRow],
  catalog: &HashMap<String, PricingCatalogEntry>,
) -> Vec<CompositionShare> {
  let mut breakdown = vec![
    CompositionAccumulator::new("input", "Input", "#ff7f45"),
    CompositionAccumulator::new("cache", "Cache", "#59c3ff"),
    CompositionAccumulator::new("output", "Output", "#ffd166"),
  ];

  for event in events {
    breakdown[0].total_tokens += (event.input_tokens - event.cached_input_tokens).max(0);
    breakdown[1].total_tokens += event.cached_input_tokens;
    breakdown[2].total_tokens += event.output_tokens;

    let Some(pricing) = resolve_pricing(catalog, &event.model_id) else {
      continue;
    };
    breakdown[0].api_value_usd +=
      ((event.input_tokens - event.cached_input_tokens).max(0) as f64 / 1_000_000.0)
        * pricing.input_price_per_million;
    breakdown[1].api_value_usd +=
      (event.cached_input_tokens as f64 / 1_000_000.0) * pricing.cached_input_price_per_million;
    breakdown[2].api_value_usd += (event.output_tokens as f64 / 1_000_000.0) * pricing.output_price_per_million;
  }

  breakdown
    .into_iter()
    .map(|item| CompositionShare {
      category: item.category,
      label: item.label,
      api_value_usd: item.api_value_usd,
      total_tokens: item.total_tokens,
      color: item.color,
    })
    .collect()
}

fn load_sessions(conn: &Connection) -> rusqlite::Result<HashMap<String, SessionRow>> {
  let mut stmt = conn.prepare(SQL_SESSIONS)?;
  let rows = stmt.query_map([], |row| {
    Ok(SessionRow {
      session_id: row.get(0)?,
      root_session_id: row.get(1)?,
      parent_session_id: row.get(2)?,
      title: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
      source_state: row.get(4)?,
      source_path: row.get(5)?,
      started_at: row.get(6)?,
      updated_at: row.get(7)?,
      agent_nickname: row.get(8)?,
      agent_role: row.get(9)?,
    })
  })?;

  let mut sessions = HashMap::new();
  for row in rows {
    let session = row?;
    sessions.insert(session.session_id.clone(), session);
  }
  Ok(sessions)
}

fn load_sessions_for_root_session(
  conn: &Connection,
  root_session_id: &str,
) -> rusqlite::Result<HashMap<String, SessionRow>> {
  let mut stmt = conn.prepare(SQL_SESSIONS_FOR_ROOT)?;
  let rows = stmt.query_map([root_session_id], |row| {
    Ok(SessionRow {
      session_id: row.get(0)?,
      root_session_id: row.get(1)?,
      parent_session_id: row.get(2)?,
      title: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
      source_state: row.get(4)?,
      source_path: row.get(5)?,
      started_at: row.get(6)?,
      updated_at: row.get(7)?,
      agent_nickname: row.get(8)?,
      agent_role: row.get(9)?,
    })
  })?;

  let mut sessions = HashMap::new();
  for row in rows {
    let session = row?;
    sessions.insert(session.session_id.clone(), session);
  }
  Ok(sessions)
}

fn load_events_in_window(conn: &Connection, window: &Window) -> rusqlite::Result<Vec<EventRow>> {
  let mut stmt = conn.prepare(
    "
    SELECT session_id, timestamp, model_id, input_tokens, cached_input_tokens,
           output_tokens, reasoning_output_tokens, total_tokens, value_usd,
           fast_mode_auto, fast_mode_effective
    FROM usage_events
    WHERE timestamp_ms >= ?1 AND timestamp_ms < ?2
    ORDER BY timestamp ASC
    ",
  )?;
  let rows = stmt.query_map(
    rusqlite::params![window.start.timestamp_millis(), window.end.timestamp_millis()],
    |row| {
      Ok(EventRow {
        session_id: row.get(0)?,
        timestamp: row.get(1)?,
        model_id: row.get(2)?,
        input_tokens: row.get(3)?,
        cached_input_tokens: row.get(4)?,
        output_tokens: row.get(5)?,
        reasoning_output_tokens: row.get(6)?,
        total_tokens: row.get(7)?,
        value_usd: row.get(8)?,
        fast_mode_auto: row.get::<_, i64>(9)? != 0,
        fast_mode_effective: row.get::<_, i64>(10)? != 0,
      })
    },
  )?;

  let mut events = rows.collect::<rusqlite::Result<Vec<_>>>()?;
  if epoch_backfill_complete(conn) || !has_legacy_usage_events(conn)? {
    return Ok(events);
  }

  let mut legacy_stmt = conn.prepare(
    "
    SELECT session_id, timestamp, model_id, input_tokens, cached_input_tokens,
           output_tokens, reasoning_output_tokens, total_tokens, value_usd,
           fast_mode_auto, fast_mode_effective
    FROM usage_events
    WHERE timestamp_ms IS NULL
      AND unixepoch(timestamp) * 1000 >= ?1
      AND unixepoch(timestamp) * 1000 < ?2
    ORDER BY timestamp ASC
    ",
  )?;
  let legacy_rows = legacy_stmt.query_map(
    rusqlite::params![window.start.timestamp_millis(), window.end.timestamp_millis()],
    |row| {
      Ok(EventRow {
        session_id: row.get(0)?,
        timestamp: row.get(1)?,
        model_id: row.get(2)?,
        input_tokens: row.get(3)?,
        cached_input_tokens: row.get(4)?,
        output_tokens: row.get(5)?,
        reasoning_output_tokens: row.get(6)?,
        total_tokens: row.get(7)?,
        value_usd: row.get(8)?,
        fast_mode_auto: row.get::<_, i64>(9)? != 0,
        fast_mode_effective: row.get::<_, i64>(10)? != 0,
      })
    },
  )?;
  events.extend(legacy_rows.collect::<rusqlite::Result<Vec<_>>>()?);
  events.sort_by(|left, right| left.timestamp.cmp(&right.timestamp));
  Ok(events)
}

fn has_legacy_usage_events(conn: &Connection) -> rusqlite::Result<bool> {
  conn.query_row(
    "SELECT EXISTS (SELECT 1 FROM usage_events WHERE timestamp_ms IS NULL LIMIT 1)",
    [],
    |row| Ok(row.get::<_, i64>(0)? != 0),
  )
}

fn load_events_for_root_session(conn: &Connection, root_session_id: &str) -> rusqlite::Result<Vec<EventRow>> {
  let mut stmt = conn.prepare(SQL_USAGE_EVENTS_FOR_ROOT)?;
  let rows = stmt.query_map([root_session_id], |row| {
    Ok(EventRow {
      session_id: row.get(0)?,
      timestamp: row.get(1)?,
      model_id: row.get(2)?,
      input_tokens: row.get(3)?,
      cached_input_tokens: row.get(4)?,
      output_tokens: row.get(5)?,
      reasoning_output_tokens: row.get(6)?,
      total_tokens: row.get(7)?,
      value_usd: row.get(8)?,
      fast_mode_auto: row.get::<_, i64>(9)? != 0,
      fast_mode_effective: row.get::<_, i64>(10)? != 0,
    })
  })?;

  rows.collect()
}

fn sum_all_api_value(conn: &Connection) -> rusqlite::Result<f64> {
  conn.query_row("SELECT COALESCE(SUM(value_usd), 0.0) FROM usage_events", [], |row| {
    row.get(0)
  })
}

fn sum_window_api_value_sql(conn: &Connection, window: &Window) -> rusqlite::Result<f64> {
  let start_ms = window.start.timestamp_millis();
  let end_ms = window.end.timestamp_millis();
  let modern = conn.query_row(
    "SELECT COALESCE(SUM(value_usd), 0.0) FROM usage_events WHERE timestamp_ms >= ?1 AND timestamp_ms < ?2",
    rusqlite::params![start_ms, end_ms],
    |row| row.get(0),
  )?;
  if epoch_backfill_complete(conn) || !has_legacy_usage_events(conn)? {
    return Ok(modern);
  }
  let legacy = conn.query_row(
    "
    SELECT COALESCE(SUM(value_usd), 0.0)
    FROM usage_events
    WHERE timestamp_ms IS NULL
      AND unixepoch(timestamp) * 1000 >= ?1
      AND unixepoch(timestamp) * 1000 < ?2
    ",
    rusqlite::params![start_ms, end_ms],
    |row| row.get::<_, f64>(0),
  )?;
  Ok(modern + legacy)
}

fn resolve_window(
  conn: &Connection,
  bucket: Option<String>,
  anchor: Option<String>,
  custom_start: Option<String>,
  custom_end: Option<String>,
  _events: &[EventRow],
  billing_anchor_day: i64,
  live_rate_limits: Option<&LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<ResolvedWindow, String> {
  let bucket = bucket.unwrap_or_else(|| "total".to_string());
  let anchor_date = anchor
    .as_deref()
    .map(parse_date)
    .transpose()?
    .unwrap_or_else(|| Local::now().date_naive());
  let requested_live_window_offset = live_window_offset.unwrap_or(0).max(0);

  let (start, end, resolved_anchor, applied_live_window_offset, live_window_count) = match bucket.as_str() {
    "day" => {
      let start = local_midnight(anchor_date)?;
      (start, start + chrono::Duration::days(1), anchor_date, 0, 0)
    }
    "week" => {
      let start_date = anchor_date - chrono::Duration::days(anchor_date.weekday().num_days_from_monday() as i64);
      let start = local_midnight(start_date)?;
      (start, start + chrono::Duration::days(7), start_date, 0, 0)
    }
    "five_hour" => resolve_live_rate_limit_window(conn, &bucket, live_rate_limits, requested_live_window_offset)?,
    "seven_day" => resolve_live_rate_limit_window(conn, &bucket, live_rate_limits, requested_live_window_offset)?,
    "custom" => {
      let start_date = custom_start
        .as_deref()
        .map(parse_date)
        .transpose()?
        .unwrap_or(anchor_date);
      let end_date = custom_end
        .as_deref()
        .map(parse_date)
        .transpose()?
        .unwrap_or(start_date);
      if end_date < start_date {
        return Err("Custom range end date cannot be before start date.".to_string());
      }
      let start = local_midnight(start_date)?;
      let exclusive_end_date = end_date
        .checked_add_days(Days::new(1))
        .ok_or_else(|| "Custom range end date is too large.".to_string())?;
      let end = local_midnight(exclusive_end_date)?;
      (start, end, start_date, 0, 0)
    }
    "subscription_month" => {
      let cycle_start_date = billing_cycle_start(anchor_date, billing_anchor_day as u32);
      let start = local_midnight(cycle_start_date)?;
      let cycle_end = billing_cycle_next_start(cycle_start_date, billing_anchor_day as u32);
      let end = local_midnight(cycle_end)?;
      (start, end, cycle_start_date, 0, 0)
    }
    "month" => {
      let start_date = NaiveDate::from_ymd_opt(anchor_date.year(), anchor_date.month(), 1)
        .ok_or_else(|| "Invalid month anchor.".to_string())?;
      let start = local_midnight(start_date)?;
      let end = local_midnight(add_months(start_date, 1))?;
      (start, end, start_date, 0, 0)
    }
    "year" => {
      let start_date =
        NaiveDate::from_ymd_opt(anchor_date.year(), 1, 1).ok_or_else(|| "Invalid year anchor.".to_string())?;
      let start = local_midnight(start_date)?;
      let end = local_midnight(NaiveDate::from_ymd_opt(anchor_date.year() + 1, 1, 1).unwrap())?;
      (start, end, start_date, 0, 0)
    }
    "total" => {
      let bounds = conn
        .query_row(
          "
          SELECT
            MIN(COALESCE(timestamp_ms, unixepoch(timestamp) * 1000)),
            MAX(COALESCE(timestamp_ms, unixepoch(timestamp) * 1000))
          FROM usage_events
          ",
          [],
          |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .map_err(|error| error.to_string())?;
      if bounds.0.is_none() || bounds.1.is_none() {
        let start = local_midnight(anchor_date)?;
        (start, start + chrono::Duration::days(1), anchor_date, 0, 0)
      } else {
        let first = Local
          .timestamp_millis_opt(bounds.0.unwrap_or_default())
          .single()
          .ok_or_else(|| "No valid first usage timestamp found.".to_string())?;
        let last = Local
          .timestamp_millis_opt(bounds.1.unwrap_or_default())
          .single()
          .ok_or_else(|| "No valid last usage timestamp found.".to_string())?;
        let start_date = first.date_naive();
        let end_date = last.date_naive().checked_add_days(Days::new(1)).unwrap_or(last.date_naive());
        let start = local_midnight(start_date)?;
        let end = local_midnight(end_date)?;
        (start, end, start_date, 0, 0)
      }
    }
    _ => {
      return Err(format!(
        "Unsupported bucket {}. Expected day, week, five_hour, seven_day, custom, subscription_month, month, year, or total.",
        bucket
      ))
    }
  };

  Ok(ResolvedWindow {
    window: Window {
      bucket,
      anchor: resolved_anchor.format("%Y-%m-%d").to_string(),
      start,
      end,
    },
    live_window_offset: applied_live_window_offset,
    live_window_count,
  })
}

fn resolve_live_rate_limit_window(
  conn: &Connection,
  bucket: &str,
  live_rate_limits: Option<&LiveRateLimitSnapshot>,
  requested_offset: i64,
) -> Result<(DateTime<Local>, DateTime<Local>, NaiveDate, i64, usize), String> {
  let current_window = live_rate_limits
    .and_then(|snapshot| selected_rate_limit_window(snapshot, bucket))
    .and_then(|active_window| {
      Some(RateLimitWindowSummary {
        start: normalize_local_timestamp(active_window.window_start.as_deref().and_then(parse_rfc3339_local)?),
        end: normalize_local_timestamp(active_window.resets_at.as_deref().and_then(parse_rfc3339_local)?),
      })
    });
  if requested_offset == 0 {
    if let Some(window) = current_window {
      return Ok((window.start, window.end, window.start.date_naive(), 0, 2));
    }
  }
  let requested_window_count = requested_offset
    .saturating_add(2)
    .clamp(1, MAX_LIVE_RATE_LIMIT_WINDOWS as i64) as usize;
  let windows = load_live_rate_limit_windows(
    conn,
    bucket,
    current_window,
    requested_window_count,
  )
  .map_err(|error| error.to_string())?;

  if windows.is_empty() {
    let duration = match bucket {
      "five_hour" => chrono::Duration::hours(5),
      "seven_day" => chrono::Duration::days(7),
      _ => {
        return Err(format!(
          "Live rate limits are unavailable for the {} view. Check that Codex is installed and logged in.",
          bucket
        ))
      }
    };
    let end = normalize_local_timestamp(Local::now());
    let start = end - duration;
    return Ok((start, end, start.date_naive(), 0, 1));
  }

  let applied_offset = requested_offset.clamp(0, windows.len().saturating_sub(1) as i64);
  let selected_window = &windows[applied_offset as usize];
  Ok((
    selected_window.start,
    selected_window.end,
    selected_window.start.date_naive(),
    applied_offset,
    windows.len(),
  ))
}

fn load_live_rate_limit_windows(
  conn: &Connection,
  bucket: &str,
  current_window: Option<RateLimitWindowSummary>,
  max_windows: usize,
) -> rusqlite::Result<Vec<RateLimitWindowSummary>> {
  let mut ordered = Vec::new();
  let mut seen = HashSet::new();
  let mut cursor = match current_window {
    Some(window) => Some(window),
    None => load_latest_rate_limit_window(conn, bucket)?,
  };
  while let Some(window) = cursor {
    let key = (window.start.timestamp_millis(), window.end.timestamp_millis());
    if !seen.insert(key) {
      break;
    }
    let previous_start = window.start;
    ordered.push(window);
    if ordered.len() >= max_windows.clamp(1, MAX_LIVE_RATE_LIMIT_WINDOWS) {
      break;
    }
    cursor = load_previous_rate_limit_window(conn, bucket, previous_start)?;
  }

  Ok(ordered)
}

fn load_latest_rate_limit_window(
  conn: &Connection,
  bucket: &str,
) -> rusqlite::Result<Option<RateLimitWindowSummary>> {
  load_rate_limit_window_query(
    conn,
    "
    SELECT window_start_ms, resets_at_ms
    FROM rate_limit_samples
    WHERE bucket = ?1
      AND window_start_ms IS NOT NULL
      AND resets_at_ms IS NOT NULL
    ORDER BY window_start_ms DESC, resets_at_ms DESC
    LIMIT 1
    ",
    rusqlite::params![bucket],
  )
}

fn load_previous_rate_limit_window(
  conn: &Connection,
  bucket: &str,
  before: DateTime<Local>,
) -> rusqlite::Result<Option<RateLimitWindowSummary>> {
  let before_ms = normalize_local_timestamp(before).timestamp_millis();
  load_rate_limit_window_query(
    conn,
    "
    SELECT window_start_ms, resets_at_ms
    FROM rate_limit_samples
    WHERE bucket = ?1
      AND window_start_ms < ?2
      AND (resets_at_ms / 60000) * 60000 <= ?2
    ORDER BY window_start_ms DESC, resets_at_ms DESC
    LIMIT 1
    ",
    rusqlite::params![bucket, before_ms],
  )
}

fn load_rate_limit_window_query<P: rusqlite::Params>(
  conn: &Connection,
  sql: &str,
  params: P,
) -> rusqlite::Result<Option<RateLimitWindowSummary>> {
  conn
    .query_row(sql, params, |row| {
      Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
    })
    .optional()
    .map(|row| {
      row.and_then(|(start_ms, end_ms)| {
        let start = Local.timestamp_millis_opt(start_ms).single()?;
        let end = Local.timestamp_millis_opt(end_ms).single()?;
        Some(RateLimitWindowSummary {
          start: normalize_local_timestamp(start),
          end: normalize_local_timestamp(end),
        })
      })
    })
}

fn build_trend(window: &Window, events: &[EventRow]) -> Vec<TrendPoint> {
  let bins = build_bins(window);
  let mut totals = vec![(0.0, 0i64); bins.len()];
  for event in events {
    let Some(timestamp) = parse_rfc3339_local(&event.timestamp) else {
      continue;
    };
    if let Some(index) = bins
      .iter()
      .position(|bin| timestamp >= bin.start && timestamp < bin.end)
    {
      totals[index].0 += event.value_usd;
      totals[index].1 += event.total_tokens;
    }
  }
  bins
    .into_iter()
    .zip(totals)
    .map(|(bin, (api_value_usd, total_tokens))| TrendPoint {
      label: bin.label,
      timestamp: bin.timestamp,
      api_value_usd,
      total_tokens,
    })
    .collect()
}

fn build_quota_trend(
  conn: &Connection,
  window: &Window,
  events: &[EventRow],
  live_rate_limits: Option<&LiveRateLimitSnapshot>,
) -> Vec<QuotaTrendPoint> {
  if !matches!(window.bucket.as_str(), "five_hour" | "seven_day") {
    return Vec::new();
  }

  let mut samples = load_quota_samples(conn, window);
  let current_cutoff = live_rate_limits
    .and_then(|snapshot| live_snapshot_cutoff(snapshot, window))
    .unwrap_or(window.end);
  if let Some(snapshot) = live_rate_limits {
    if let Some(current) = live_sample(snapshot, &window.bucket) {
      if current.timestamp >= window.start && current.timestamp <= window.end {
        samples.push(current);
      }
    }
  }
  samples.sort_by_key(|sample| sample.timestamp);
  samples.dedup_by(|right, left| right.timestamp == left.timestamp && right.used_percent == left.used_percent);

  let bins = build_elapsed_bins(window, window.end);
  let mut bin_totals = vec![(0.0, 0i64); bins.len()];
  for event in events {
    let Some(timestamp) = parse_rfc3339_local(&event.timestamp) else {
      continue;
    };
    if let Some(index) = bins
      .iter()
      .position(|bin| timestamp >= bin.start && timestamp < bin.end)
    {
      bin_totals[index].0 += event.value_usd;
      bin_totals[index].1 += event.total_tokens;
    }
  }
  let mut trend = Vec::new();
  let mut cumulative_api_value_usd = 0.0;
  let mut cumulative_tokens = 0i64;

  for (bin, (api_value_usd, total_tokens)) in bins.into_iter().zip(bin_totals) {

    cumulative_api_value_usd += api_value_usd;
    cumulative_tokens += total_tokens;

    let effective_end = bin.end.min(current_cutoff);
    let latest_sample = if bin.start < current_cutoff {
      samples
        .iter()
        .filter(|sample| sample.timestamp <= effective_end)
        .next_back()
    } else {
      None
    };
    let (used_percent, remaining_percent) = match latest_sample {
      Some(sample) => {
        let used = sample.used_percent.clamp(0, 100);
        (Some(used), Some((100 - used).clamp(0, 100)))
      }
      None if bin.start < current_cutoff => (Some(0), Some(100)),
      None => (None, None),
    };

    trend.push(QuotaTrendPoint {
      label: bin.label,
      timestamp: bin.timestamp,
      api_value_usd,
      cumulative_api_value_usd,
      total_tokens,
      cumulative_tokens,
      remaining_percent,
      used_percent,
    });
  }

  trend
}

fn build_elapsed_bins(window: &Window, chart_end: DateTime<Local>) -> Vec<TrendBin> {
  let mut bins = Vec::new();
  let mut current = window.start;
  while current < chart_end {
    let next = match window.bucket.as_str() {
      "five_hour" => current + chrono::Duration::minutes(15),
      "seven_day" => current + chrono::Duration::hours(1),
      _ => chart_end,
    };
    bins.push(TrendBin {
      label: match window.bucket.as_str() {
        "five_hour" => current.format("%H:%M").to_string(),
        "seven_day" => current.format("%b %d %H:%M").to_string(),
        _ => current.format("%b %d").to_string(),
      },
      timestamp: current.to_rfc3339(),
      start: current,
      end: next.min(chart_end),
    });
    current = next;
  }
  bins
}

fn build_bins(window: &Window) -> Vec<TrendBin> {
  let mut bins = Vec::new();
  let mut current = window.start;
  while current < window.end {
    let next = match window.bucket.as_str() {
      "day" => current + chrono::Duration::hours(1),
      "five_hour" => current + chrono::Duration::minutes(15),
      "week" | "subscription_month" | "month" => current + chrono::Duration::days(1),
      "seven_day" => current + chrono::Duration::hours(1),
      "custom" if custom_window_uses_hourly_bins(window) => current + chrono::Duration::hours(1),
      "custom" if custom_window_uses_monthly_bins(window) => {
        let current_date = current.date_naive();
        let next_date = add_months(current_date, 1);
        local_midnight(next_date).unwrap_or(window.end)
      }
      "custom" => current + chrono::Duration::days(1),
      "year" | "total" => {
        let current_date = current.date_naive();
        let next_date = add_months(current_date, 1);
        local_midnight(next_date).unwrap_or(window.end)
      }
      _ => window.end,
    };

    let label = match window.bucket.as_str() {
      "day" | "five_hour" => current.format("%H:%M").to_string(),
      "seven_day" => current.format("%b %d %H:%M").to_string(),
      "custom" if custom_window_uses_hourly_bins(window) => current.format("%H:%M").to_string(),
      "custom" if custom_window_uses_monthly_bins(window) => current.format("%b %Y").to_string(),
      "year" | "total" => current.format("%b %Y").to_string(),
      _ => current.format("%b %d").to_string(),
    };
    bins.push(TrendBin {
      label,
      timestamp: current.to_rfc3339(),
      start: current,
      end: next.min(window.end),
    });
    current = next;
  }
  bins
}

fn custom_window_uses_hourly_bins(window: &Window) -> bool {
  window.end.signed_duration_since(window.start) <= chrono::Duration::days(1)
}

fn custom_window_uses_monthly_bins(window: &Window) -> bool {
  window.end.signed_duration_since(window.start) > chrono::Duration::days(62)
}

fn subscription_cost_for_window(window: &Window, monthly_price: f64, billing_anchor_day: u32) -> f64 {
  if window.bucket == "subscription_month" {
    return monthly_price;
  }

  let mut total = 0.0;
  let mut cycle_start = billing_cycle_start(window.start.date_naive(), billing_anchor_day);
  loop {
    let cycle_end = billing_cycle_next_start(cycle_start, billing_anchor_day);
    let overlap_start = window.start.date_naive().max(cycle_start);
    let overlap_end = window.end.date_naive().min(cycle_end);
    if overlap_start < overlap_end {
      let cycle_days = (cycle_end - cycle_start).num_days().max(1) as f64;
      let overlap_days = (overlap_end - overlap_start).num_days().max(0) as f64;
      total += monthly_price * (overlap_days / cycle_days);
    }
    if cycle_end >= window.end.date_naive() {
      break;
    }
    cycle_start = cycle_end;
  }
  total
}

fn selected_rate_limit_window<'a>(
  live_rate_limits: &'a LiveRateLimitSnapshot,
  bucket: &str,
) -> Option<&'a crate::models::RateLimitWindowSnapshot> {
  match bucket {
    "five_hour" => live_rate_limits.primary.as_ref(),
    "seven_day" => live_rate_limits.secondary.as_ref(),
    _ => None,
  }
}

fn live_sample(live_rate_limits: &LiveRateLimitSnapshot, bucket: &str) -> Option<QuotaSample> {
  let active_window = selected_rate_limit_window(live_rate_limits, bucket)?;
  let timestamp = parse_rfc3339_local(&live_rate_limits.fetched_at)?;
  Some(QuotaSample {
    timestamp,
    used_percent: active_window.used_percent,
  })
}

fn load_quota_samples(conn: &Connection, window: &Window) -> Vec<QuotaSample> {
  let target_start = normalize_local_timestamp(window.start);
  let target_end = normalize_local_timestamp(window.end);
  let sample_start_ms = window.start.timestamp_millis();
  let sample_end_ms = window.end.timestamp_millis();
  let bin_duration_ms = match window.bucket.as_str() {
    "five_hour" => chrono::Duration::minutes(15).num_milliseconds(),
    "seven_day" => chrono::Duration::hours(1).num_milliseconds(),
    _ => chrono::Duration::hours(1).num_milliseconds(),
  };
  let mut stmt = match conn.prepare(
    "
    WITH RECURSIVE bins(bin_start_ms, bin_end_ms) AS (
      SELECT ?4, MIN(?4 + ?6, ?5)
      WHERE ?4 < ?5
      UNION ALL
      SELECT bin_end_ms, MIN(bin_end_ms + ?6, ?5)
      FROM bins
      WHERE bin_end_ms < ?5
    ),
    latest_ids AS MATERIALIZED (
      SELECT (
        SELECT id
        FROM rate_limit_samples
        WHERE bucket = ?1
          AND window_start_ms >= ?2
          AND window_start_ms < ?2 + 60000
          AND resets_at_ms >= ?3
          AND resets_at_ms < ?3 + 60000
          AND sample_timestamp_ms >= bins.bin_start_ms
          AND sample_timestamp_ms < bins.bin_end_ms
        ORDER BY sample_timestamp_ms DESC, id DESC
        LIMIT 1
      ) AS id
      FROM bins
    )
    SELECT sample.sample_timestamp_ms, sample.used_percent
    FROM latest_ids
    JOIN rate_limit_samples AS sample ON sample.id = latest_ids.id
    ORDER BY sample.sample_timestamp_ms ASC
    ",
  ) {
    Ok(stmt) => stmt,
    Err(_) => return Vec::new(),
  };

  let rows = match stmt.query_map(
    rusqlite::params![
      window.bucket,
      target_start.timestamp_millis(),
      target_end.timestamp_millis(),
      sample_start_ms,
      sample_end_ms,
      bin_duration_ms,
    ],
    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
  ) {
    Ok(rows) => rows,
    Err(_) => return Vec::new(),
  };

  let mut samples = rows
    .filter_map(Result::ok)
    .filter_map(|(timestamp_ms, used_percent)| {
      Local.timestamp_millis_opt(timestamp_ms).single().map(|timestamp| QuotaSample {
        timestamp,
        used_percent,
      })
    })
    .collect::<Vec<_>>();
  if epoch_backfill_complete(conn) {
    return samples;
  }

  samples.extend(load_legacy_quota_samples(conn, window, target_start, target_end));
  samples.sort_by_key(|sample| sample.timestamp);
  samples.dedup_by(|right, left| right.timestamp == left.timestamp && right.used_percent == left.used_percent);
  samples
}

fn epoch_backfill_complete(conn: &Connection) -> bool {
  conn
    .query_row(
      "SELECT EXISTS (SELECT 1 FROM data_repairs WHERE repair_key = 'epoch_timestamp_backfill_v1')",
      [],
      |row| Ok(row.get::<_, i64>(0)? != 0),
    )
    .unwrap_or(true)
}

fn load_legacy_quota_samples(
  conn: &Connection,
  window: &Window,
  target_start: DateTime<Local>,
  target_end: DateTime<Local>,
) -> Vec<QuotaSample> {
  let mut stmt = match conn.prepare(
    "
    SELECT sample_timestamp, used_percent
    FROM rate_limit_samples
    WHERE bucket = ?1
      AND (window_start_ms IS NULL OR resets_at_ms IS NULL)
      AND (unixepoch(window_start) / 60) * 60000 = ?2
      AND (unixepoch(resets_at) / 60) * 60000 = ?3
    ORDER BY sample_timestamp ASC
    ",
  ) {
    Ok(stmt) => stmt,
    Err(_) => return Vec::new(),
  };
  let rows = match stmt.query_map(
    rusqlite::params![
      window.bucket,
      target_start.timestamp_millis(),
      target_end.timestamp_millis(),
    ],
    |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
  ) {
    Ok(rows) => rows,
    Err(_) => return Vec::new(),
  };
  rows
    .filter_map(Result::ok)
    .filter_map(|(timestamp, used_percent)| {
      parse_rfc3339_local(&timestamp).map(|timestamp| QuotaSample {
        timestamp,
        used_percent,
      })
    })
    .collect()
}

fn live_snapshot_cutoff(live_rate_limits: &LiveRateLimitSnapshot, window: &Window) -> Option<DateTime<Local>> {
  let active_window = selected_rate_limit_window(live_rate_limits, &window.bucket)?;
  let live_start = active_window
    .window_start
    .as_deref()
    .and_then(parse_rfc3339_local)
    .map(normalize_local_timestamp)?;
  let live_end = active_window
    .resets_at
    .as_deref()
    .and_then(parse_rfc3339_local)
    .map(normalize_local_timestamp)?;
  if live_start != normalize_local_timestamp(window.start) || live_end != normalize_local_timestamp(window.end) {
    return None;
  }
  parse_rfc3339_local(&live_rate_limits.fetched_at).map(|timestamp| timestamp.min(window.end))
}

fn normalize_local_timestamp(timestamp: DateTime<Local>) -> DateTime<Local> {
  timestamp
    .with_second(0)
    .and_then(|value| value.with_nanosecond(0))
    .unwrap_or(timestamp)
}

fn billing_cycle_start(anchor_date: NaiveDate, billing_anchor_day: u32) -> NaiveDate {
  let this_month_anchor = anchored_date(anchor_date.year(), anchor_date.month(), billing_anchor_day);
  if anchor_date >= this_month_anchor {
    this_month_anchor
  } else {
    add_months(this_month_anchor, -1)
  }
}

fn billing_cycle_next_start(cycle_start: NaiveDate, billing_anchor_day: u32) -> NaiveDate {
  let next_month = add_months(cycle_start, 1);
  anchored_date(next_month.year(), next_month.month(), billing_anchor_day)
}

fn anchored_date(year: i32, month: u32, billing_anchor_day: u32) -> NaiveDate {
  let mut day = billing_anchor_day.clamp(1, 28);
  while NaiveDate::from_ymd_opt(year, month, day).is_none() {
    day -= 1;
  }
  NaiveDate::from_ymd_opt(year, month, day).unwrap()
}

fn add_months(date: NaiveDate, months: i32) -> NaiveDate {
  if months >= 0 {
    date.checked_add_months(Months::new(months as u32)).unwrap_or(date)
  } else {
    date.checked_sub_months(Months::new((-months) as u32)).unwrap_or(date)
  }
}

fn parse_date(value: &str) -> Result<NaiveDate, String> {
  NaiveDate::parse_from_str(value, "%Y-%m-%d")
    .map_err(|error| format!("Invalid anchor date {}: {error}", value))
}

fn parse_rfc3339_local(value: &str) -> Option<DateTime<Local>> {
  DateTime::parse_from_rfc3339(value)
    .ok()
    .map(|timestamp| timestamp.with_timezone(&Local))
}

fn local_midnight(date: NaiveDate) -> Result<DateTime<Local>, String> {
  let naive = NaiveDateTime::new(
    date,
    chrono::NaiveTime::from_hms_opt(0, 0, 0).ok_or_else(|| "Invalid local midnight.".to_string())?,
  );
  match Local.from_local_datetime(&naive) {
    LocalResult::Single(value) => Ok(value),
    LocalResult::Ambiguous(first, _) => Ok(first),
    LocalResult::None => Err("Could not localize midnight in the current timezone.".to_string()),
  }
}

fn min_option_string(left: Option<String>, right: Option<String>) -> Option<String> {
  match (left, right) {
    (Some(left), Some(right)) => Some(left.min(right)),
    (Some(left), None) => Some(left),
    (None, Some(right)) => Some(right),
    (None, None) => None,
  }
}

fn max_option_string(left: Option<String>, right: Option<String>) -> Option<String> {
  match (left, right) {
    (Some(left), Some(right)) => Some(left.max(right)),
    (Some(left), None) => Some(left),
    (None, Some(right)) => Some(right),
    (None, None) => None,
  }
}

fn sorted_strings(values: HashSet<String>) -> Vec<String> {
  let mut values = values.into_iter().collect::<Vec<_>>();
  values.sort();
  values
}

#[derive(Debug, Default)]
struct ModelShareAccumulator {
  api_value_usd: f64,
  total_tokens: i64,
  conversation_ids: HashSet<String>,
}

#[derive(Debug)]
struct CompositionAccumulator {
  category: String,
  label: String,
  api_value_usd: f64,
  total_tokens: i64,
  color: String,
}

impl CompositionAccumulator {
  fn new(category: &str, label: &str, color: &str) -> Self {
    Self {
      category: category.to_string(),
      label: label.to_string(),
      api_value_usd: 0.0,
      total_tokens: 0,
      color: color.to_string(),
    }
  }
}

#[derive(Debug, Default)]
struct ConversationSessionAccumulator {
  parent_session_id: Option<String>,
  agent_nickname: Option<String>,
  agent_role: Option<String>,
  model_ids: HashSet<String>,
  started_at: Option<String>,
  updated_at: Option<String>,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
  reasoning_output_tokens: i64,
  total_tokens: i64,
  api_value_usd: f64,
  fast_mode_auto: bool,
  fast_mode_effective: bool,
  source_state: String,
  source_path: Option<String>,
}

#[derive(Debug)]
struct SourceTurnAccumulator {
  session_id: String,
  turn_id: String,
  started_at: Option<String>,
  completed_at: Option<String>,
  last_activity_at: String,
  status: String,
  user_message: Option<String>,
  assistant_message: Option<String>,
  model_ids: HashSet<String>,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
  reasoning_output_tokens: i64,
  total_tokens: i64,
  value_usd: f64,
  fast_mode_effective: bool,
}

impl SourceTurnAccumulator {
  fn into_point(self) -> ConversationTurnPoint {
    ConversationTurnPoint {
      session_id: self.session_id,
      turn_id: self.turn_id,
      started_at: self.started_at,
      completed_at: self.completed_at,
      last_activity_at: self.last_activity_at,
      status: self.status,
      user_message: self.user_message,
      assistant_message: self.assistant_message,
      model_ids: sorted_strings(self.model_ids),
      input_tokens: self.input_tokens,
      cached_input_tokens: self.cached_input_tokens,
      output_tokens: self.output_tokens,
      reasoning_output_tokens: self.reasoning_output_tokens,
      total_tokens: self.total_tokens,
      value_usd: self.value_usd,
      fast_mode_effective: self.fast_mode_effective,
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::database::{init_db, insert_live_rate_limit_snapshot};
  use tempfile::tempdir;

  #[test]
  fn seven_day_overview_without_quota_uses_a_rolling_window() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");

    let overview = get_overview_with_connection(
      &conn,
      Some("seven_day".to_string()),
      None,
      None,
      None,
      None,
      None,
    )
    .expect("load seven-day overview without quota samples");
    let start = parse_rfc3339_local(&overview.window_start).expect("parse window start");
    let end = parse_rfc3339_local(&overview.window_end).expect("parse window end");

    assert_eq!(overview.bucket, "seven_day");
    assert_eq!((end - start).num_hours(), 7 * 24);
    assert_eq!(overview.live_window_offset, 0);
    assert_eq!(overview.live_window_count, 1);
  }

  #[test]
  fn seven_day_overview_restarts_after_an_early_live_quota_reset() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    for (session_id, timestamp, value_usd) in [
      ("before-reset", "2026-07-15T03:00:00+08:00", 10.0),
      ("after-reset", "2026-07-15T05:00:00+08:00", 2.0),
    ] {
      conn
        .execute(
          "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES (?1, ?2, ?3, 'gpt-5.4', 1, 0, 1, 0, 2, ?4, 0, 0)",
          rusqlite::params![
            session_id,
            timestamp,
            parse_rfc3339_local(timestamp)
              .expect("parse event timestamp")
              .timestamp_millis(),
            value_usd,
          ],
        )
        .expect("insert usage event");
    }
    let live_rate_limits = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: Some("Codex".to_string()),
      plan_type: Some("pro".to_string()),
      primary: None,
      secondary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 1,
        remaining_percent: 99,
        window_duration_mins: Some(10_080),
        resets_at: Some("2026-07-22T04:36:00+08:00".to_string()),
        window_start: Some("2026-07-15T04:36:00+08:00".to_string()),
      }),
      fetched_at: "2026-07-15T05:30:00+08:00".to_string(),
    };

    let overview = get_overview_with_connection(
      &conn,
      Some("seven_day".to_string()),
      None,
      None,
      None,
      Some(live_rate_limits),
      None,
    )
    .expect("load overview after early reset");

    assert_eq!(overview.window_start, "2026-07-15T04:36:00+08:00");
    assert_eq!(overview.stats.api_value_usd, 2.0);
    assert_eq!(
      overview
        .quota_trend
        .last()
        .map(|point| point.cumulative_api_value_usd),
      Some(2.0)
    );
  }

  #[test]
  fn conversation_query_pages_in_sql_without_loading_every_item() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let event_timestamp = "2026-07-13T08:00:00Z";
    let event_timestamp_ms = parse_rfc3339_local(event_timestamp).expect("event timestamp").timestamp_millis();
    for index in 0..120 {
      let session_id = format!("session-{index:03}");
      conn
        .execute(
          "INSERT INTO sessions (session_id, root_session_id, title, source_state, created_at, imported_at, updated_at) VALUES (?1, ?1, ?2, 'active', ?3, ?3, ?3)",
          rusqlite::params![session_id, format!("Conversation {index:03}"), "2026-07-13T08:00:00Z"],
        )
        .expect("insert session");
      conn
        .execute(
          "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES (?1, ?2, ?3, 'gpt-5.4', 1, 0, 1, 0, 2, ?4, 0, 0)",
          rusqlite::params![session_id, event_timestamp, event_timestamp_ms, index as f64],
        )
        .expect("insert usage event");
    }
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: parse_rfc3339_local("2026-07-13T00:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-20T00:00:00Z").expect("end"),
    };
    let profile = SubscriptionProfile::default();

    let first = load_conversation_page_sql(&conn, &profile, &window, None, None, 50).expect("first page");
    assert_eq!(first.items.len(), 50);
    assert!(first.has_more);
    assert_eq!(first.next_cursor.as_deref(), Some("50"));
    assert_eq!(first.items.first().map(|item| item.root_session_id.as_str()), Some("session-119"));

    let second = load_conversation_page_sql(
      &conn,
      &profile,
      &window,
      None,
      first.next_cursor.as_deref(),
      50,
    )
    .expect("second page");
    assert_eq!(second.items.len(), 50);
    assert_eq!(second.next_cursor.as_deref(), Some("100"));
    assert_eq!(second.items.first().map(|item| item.root_session_id.as_str()), Some("session-069"));
  }

  #[test]
  fn conversation_search_aggregates_every_session_in_a_matching_root() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "INSERT INTO sessions (session_id, root_session_id, title, source_state, started_at, created_at, imported_at, updated_at) VALUES ('root', 'root', 'Z Root title', 'active', '2026-07-13T07:00:00Z', '2026-07-13T07:00:00Z', '2026-07-13T07:00:00Z', '2026-07-13T08:00:00Z')",
        [],
      )
      .expect("insert root session");
    conn
      .execute(
        "INSERT INTO sessions (session_id, root_session_id, title, source_state, started_at, created_at, imported_at, updated_at) VALUES ('child-needle', 'root', 'Needle child', 'missing', '2026-07-13T08:00:00Z', '2026-07-13T08:00:00Z', '2026-07-13T08:00:00Z', '2026-07-13T09:00:00Z')",
        [],
      )
      .expect("insert matching child session");
    for (session_id, total_tokens, value_usd) in [("root", 10, 1.0), ("child-needle", 20, 2.0)] {
      conn
        .execute(
          "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES (?1, '2026-07-13T08:30:00Z', ?2, 'gpt-5.4', ?3, 0, 0, 0, ?3, ?4, 0, 0)",
          rusqlite::params![
            session_id,
            parse_rfc3339_local("2026-07-13T08:30:00Z")
              .expect("event timestamp")
              .timestamp_millis(),
            total_tokens,
            value_usd,
          ],
        )
        .expect("insert usage event");
    }
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: parse_rfc3339_local("2026-07-13T00:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-20T00:00:00Z").expect("end"),
    };

    let page = load_conversation_page_sql(
      &conn,
      &SubscriptionProfile::default(),
      &window,
      Some("needle".to_string()),
      None,
      50,
    )
    .expect("search conversations");

    assert_eq!(page.items.len(), 1);
    let item = &page.items[0];
    assert_eq!(item.root_session_id, "root");
    assert_eq!(item.title, "Z Root title");
    assert_eq!(item.started_at.as_deref(), Some("2026-07-13T07:00:00Z"));
    assert_eq!(item.updated_at.as_deref(), Some("2026-07-13T09:00:00Z"));
    assert_eq!(item.session_count, 2);
    assert_eq!(item.subagent_count, 1);
    assert_eq!(item.total_tokens, 30);
    assert_eq!(item.api_value_usd, 3.0);
    assert_eq!(item.source_states, vec!["active", "missing"]);
  }

  #[test]
  #[ignore = "resource profiling helper; requires CODEX_PACER_PROFILE_DB"]
  fn profile_real_seven_day_dashboard_load() {
    let db_path = std::env::var_os("CODEX_PACER_PROFILE_DB")
      .map(std::path::PathBuf::from)
      .expect("set CODEX_PACER_PROFILE_DB to a database copy");
    let started = std::time::Instant::now();
    let data = load_dashboard_data(
      &db_path,
      Some("seven_day".to_string()),
      None,
      None,
      None,
      None,
      None,
      None,
      true,
    )
    .expect("load seven-day dashboard");
    eprintln!(
      "profile seven_day elapsed_ms={} first_page={} has_more={}",
      started.elapsed().as_millis(),
      data.conversation_page.items.len(),
      data.conversation_page.has_more
    );
  }

  #[test]
  fn window_event_loader_does_not_return_rows_outside_the_requested_range() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    for timestamp in ["2026-07-01T00:00:00Z", "2026-07-10T00:00:00Z"] {
      let timestamp_ms = parse_rfc3339_local(timestamp).expect("timestamp").timestamp_millis();
      conn.execute(
        "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES ('session', ?1, ?2, 'gpt-5.4', 1, 0, 1, 0, 2, 0.0, 0, 0)",
        rusqlite::params![timestamp, timestamp_ms],
      )
      .expect("insert event");
    }
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-10".to_string(),
      start: parse_rfc3339_local("2026-07-09T00:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-11T00:00:00Z").expect("end"),
    };

    let events = load_events_in_window(&conn, &window).expect("load window events");

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].timestamp, "2026-07-10T00:00:00Z");
  }

  #[test]
  fn window_event_loader_keeps_legacy_rows_before_epoch_backfill_completes() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn.execute(
      "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES ('legacy', '2026-07-10T00:00:00Z', NULL, 'gpt-5.4', 1, 0, 1, 0, 2, 1.5, 0, 0)",
      [],
    )
    .expect("insert legacy event");
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-10".to_string(),
      start: parse_rfc3339_local("2026-07-09T00:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-11T00:00:00Z").expect("end"),
    };

    let events = load_events_in_window(&conn, &window).expect("load window events");

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].session_id, "legacy");
    assert_eq!(sum_window_api_value_sql(&conn, &window).expect("sum window"), 1.5);
  }

  #[test]
  fn completed_epoch_backfill_skips_legacy_usage_event_fallback() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn.execute(
      "INSERT INTO usage_events (session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, value_usd, fast_mode_auto, fast_mode_effective) VALUES ('legacy', '2026-07-10T00:00:00Z', NULL, 'gpt-5.4', 1, 0, 1, 0, 2, 1.5, 0, 0)",
      [],
    )
    .expect("insert legacy event");
    conn.execute(
      "INSERT INTO data_repairs (repair_key, completed_at) VALUES ('epoch_timestamp_backfill_v1', '2026-07-13T08:00:00Z')",
      [],
    )
    .expect("mark epoch backfill complete");
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-10".to_string(),
      start: parse_rfc3339_local("2026-07-09T00:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-11T00:00:00Z").expect("end"),
    };

    assert!(load_events_in_window(&conn, &window).expect("load window events").is_empty());
    assert_eq!(sum_window_api_value_sql(&conn, &window).expect("sum window"), 0.0);
  }

  #[test]
  fn legacy_quota_samples_match_the_normalized_window_minute() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "
        INSERT INTO rate_limit_samples (
          source_kind, source_session_id, bucket, sample_timestamp,
          limit_id, limit_name, plan_type, window_start, resets_at,
          used_percent, remaining_percent, created_at,
          sample_timestamp_ms, window_start_ms, resets_at_ms
        ) VALUES (
          'live', '', 'seven_day', '2026-07-13T07:00:12Z',
          '', '', 'pro', '2026-07-13T06:00:36Z', '2026-07-20T06:00:44Z',
          12, 88, '2026-07-13T07:00:12Z',
          NULL, NULL, NULL
        )
        ",
        [],
      )
      .expect("insert legacy quota sample");
    conn
      .execute(
        "
        INSERT INTO rate_limit_samples (
          source_kind, source_session_id, bucket, sample_timestamp,
          limit_id, limit_name, plan_type, window_start, resets_at,
          used_percent, remaining_percent, created_at,
          sample_timestamp_ms, window_start_ms, resets_at_ms
        ) VALUES (
          'live', '', 'seven_day', '2026-07-13T06:30:00Z',
          '', '', 'pro', '2026-07-13T06:00:00Z', '2026-07-20T06:00:00Z',
          8, 92, '2026-07-13T06:30:00Z',
          ?1, ?2, ?3
        )
        ",
        rusqlite::params![
          parse_rfc3339_local("2026-07-13T06:30:00Z").expect("sample").timestamp_millis(),
          parse_rfc3339_local("2026-07-13T06:00:00Z").expect("start").timestamp_millis(),
          parse_rfc3339_local("2026-07-20T06:00:00Z").expect("end").timestamp_millis(),
        ],
      )
      .expect("insert normalized quota sample");
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: parse_rfc3339_local("2026-07-13T06:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-20T06:00:00Z").expect("end"),
    };

    let samples = load_quota_samples(&conn, &window);

    assert_eq!(samples.iter().map(|sample| sample.used_percent).collect::<Vec<_>>(), vec![8, 12]);
  }

  #[test]
  fn quota_samples_keep_only_the_latest_point_in_each_chart_bin() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let window_start = parse_rfc3339_local("2026-07-13T06:00:00Z").expect("start");
    let window_end = parse_rfc3339_local("2026-07-20T06:00:00Z").expect("end");
    for (timestamp, used_percent) in [
      ("2026-07-13T06:05:00Z", 1),
      ("2026-07-13T06:55:00Z", 2),
      ("2026-07-13T07:10:00Z", 3),
      ("2026-07-13T07:58:00Z", 4),
    ] {
      let timestamp_ms = parse_rfc3339_local(timestamp)
        .expect("sample timestamp")
        .timestamp_millis();
      conn
        .execute(
          "
          INSERT INTO rate_limit_samples (
            source_kind, source_session_id, bucket, sample_timestamp,
            limit_id, limit_name, plan_type, window_start, resets_at,
            used_percent, remaining_percent, created_at,
            sample_timestamp_ms, window_start_ms, resets_at_ms
          ) VALUES (
            'session', 'session', 'seven_day', ?1,
            '', '', 'pro', '2026-07-13T06:00:00Z', '2026-07-20T06:00:00Z',
            ?2, 100 - ?2, ?1, ?3, ?4, ?5
          )
          ",
          rusqlite::params![
            timestamp,
            used_percent,
            timestamp_ms,
            window_start.timestamp_millis(),
            window_end.timestamp_millis(),
          ],
        )
        .expect("insert quota sample");
    }
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: window_start,
      end: window_end,
    };

    let samples = load_quota_samples(&conn, &window);

    assert_eq!(
      samples
        .iter()
        .map(|sample| sample.used_percent)
        .collect::<Vec<_>>(),
      vec![2, 4]
    );
  }

  #[test]
  fn backfilled_quota_samples_match_the_normalized_window_minute() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "
        INSERT INTO rate_limit_samples (
          source_kind, source_session_id, bucket, sample_timestamp,
          limit_id, limit_name, plan_type, window_start, resets_at,
          used_percent, remaining_percent, created_at,
          sample_timestamp_ms, window_start_ms, resets_at_ms
        ) VALUES (
          'live', '', 'seven_day', '2026-07-13T07:00:12Z',
          '', '', 'pro', '2026-07-13T06:00:36Z', '2026-07-20T06:00:44Z',
          12, 88, '2026-07-13T07:00:12Z', ?1, ?2, ?3
        )
        ",
        rusqlite::params![
          parse_rfc3339_local("2026-07-13T07:00:12Z").expect("sample").timestamp_millis(),
          parse_rfc3339_local("2026-07-13T06:00:36Z").expect("start").timestamp_millis(),
          parse_rfc3339_local("2026-07-20T06:00:44Z").expect("end").timestamp_millis(),
        ],
      )
      .expect("insert backfilled quota sample");
    conn
      .execute(
        "INSERT INTO data_repairs (repair_key, completed_at) VALUES ('epoch_timestamp_backfill_v1', '2026-07-13T08:00:00Z')",
        [],
      )
      .expect("mark epoch backfill complete");
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: parse_rfc3339_local("2026-07-13T06:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-20T06:00:00Z").expect("end"),
    };

    let samples = load_quota_samples(&conn, &window);

    assert_eq!(samples.iter().map(|sample| sample.used_percent).collect::<Vec<_>>(), vec![12]);
  }

  #[test]
  fn completed_epoch_backfill_does_not_scan_legacy_quota_rows() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    conn
      .execute(
        "
        INSERT INTO rate_limit_samples (
          source_kind, source_session_id, bucket, sample_timestamp,
          limit_id, limit_name, plan_type, window_start, resets_at,
          used_percent, remaining_percent, created_at,
          sample_timestamp_ms, window_start_ms, resets_at_ms
        ) VALUES (
          'live', '', 'seven_day', '2026-07-13T07:00:12Z',
          '', '', 'pro', '2026-07-13T06:00:36Z', '2026-07-20T06:00:44Z',
          12, 88, '2026-07-13T07:00:12Z',
          NULL, NULL, NULL
        )
        ",
        [],
      )
      .expect("insert legacy quota sample");
    conn
      .execute(
        "INSERT INTO data_repairs (repair_key, completed_at) VALUES ('epoch_timestamp_backfill_v1', '2026-07-13T08:00:00Z')",
        [],
      )
      .expect("mark epoch backfill complete");
    let window = Window {
      bucket: "seven_day".to_string(),
      anchor: "2026-07-13".to_string(),
      start: parse_rfc3339_local("2026-07-13T06:00:00Z").expect("start"),
      end: parse_rfc3339_local("2026-07-20T06:00:00Z").expect("end"),
    };

    assert!(load_quota_samples(&conn, &window).is_empty());
  }

  #[test]
  fn groups_modern_snapshots_into_one_turn() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("session.jsonl");
    std::fs::write(
      &path,
      concat!(
        "{\"timestamp\":\"2026-03-24T06:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-123\"}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"hello world\"}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":30,\"reasoning_output_tokens\":10,\"total_tokens\":130}}}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":140,\"cached_input_tokens\":40,\"output_tokens\":50,\"reasoning_output_tokens\":12,\"total_tokens\":190}}}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:04Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"done\",\"phase\":\"final_answer\"}}\n",
        "{\"timestamp\":\"2026-03-24T06:00:05Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-123\"}}\n"
      ),
    )
    .expect("write sample");

    let turns = build_turns_for_session(
      &SessionRow {
        session_id: "session-1".to_string(),
        root_session_id: "session-1".to_string(),
        parent_session_id: None,
        title: String::new(),
        source_state: "active".to_string(),
        source_path: Some(path.to_string_lossy().to_string()),
        started_at: None,
        updated_at: None,
        agent_nickname: None,
        agent_role: None,
      },
      &HashMap::new(),
    )
    .expect("build turns");

    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].turn_id, "turn-123");
    assert_eq!(turns[0].total_tokens, 190);
    assert_eq!(turns[0].input_tokens, 140);
    assert_eq!(turns[0].cached_input_tokens, 40);
    assert_eq!(turns[0].output_tokens, 50);
    assert_eq!(turns[0].status, "completed");
  }

  #[test]
  fn ignores_non_monotonic_token_snapshots_in_turn_totals() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("session.jsonl");
    std::fs::write(
      &path,
      concat!(
        "{\"timestamp\":\"2026-05-18T14:42:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-rollback\"}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"investigate tokens\"}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:02Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:17Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":800,\"cached_input_tokens\":100,\"output_tokens\":100,\"reasoning_output_tokens\":0,\"total_tokens\":1000}}}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:28Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":880,\"cached_input_tokens\":110,\"output_tokens\":110,\"reasoning_output_tokens\":0,\"total_tokens\":1100}}}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:39Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":840,\"cached_input_tokens\":105,\"output_tokens\":105,\"reasoning_output_tokens\":0,\"total_tokens\":1050}}}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:50Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":960,\"cached_input_tokens\":120,\"output_tokens\":120,\"reasoning_output_tokens\":0,\"total_tokens\":1200}}}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:55Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"done\",\"phase\":\"final_answer\"}}\n",
        "{\"timestamp\":\"2026-05-18T14:42:56Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-rollback\"}}\n"
      ),
    )
    .expect("write sample");

    let turns = build_turns_for_session(
      &SessionRow {
        session_id: "session-rollback".to_string(),
        root_session_id: "session-rollback".to_string(),
        parent_session_id: None,
        title: String::new(),
        source_state: "active".to_string(),
        source_path: Some(path.to_string_lossy().to_string()),
        started_at: None,
        updated_at: None,
        agent_nickname: None,
        agent_role: None,
      },
      &HashMap::new(),
    )
    .expect("build turns");

    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].turn_id, "turn-rollback");
    assert_eq!(turns[0].input_tokens, 960);
    assert_eq!(turns[0].cached_input_tokens, 120);
    assert_eq!(turns[0].output_tokens, 120);
    assert_eq!(turns[0].total_tokens, 1200);
  }

  #[test]
  fn groups_legacy_snapshots_until_next_user_message() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("session.jsonl");
    std::fs::write(
      &path,
      concat!(
        "{\"timestamp\":\"2025-11-03T10:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"first turn\"}}\n",
        "{\"timestamp\":\"2025-11-03T10:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n",
        "{\"timestamp\":\"2025-11-03T10:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":20,\"reasoning_output_tokens\":0,\"total_tokens\":120}}}}\n",
        "{\"timestamp\":\"2025-11-03T10:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":20,\"reasoning_output_tokens\":0,\"total_tokens\":120}}}}\n",
        "{\"timestamp\":\"2025-11-03T10:00:04Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":150,\"cached_input_tokens\":10,\"output_tokens\":30,\"reasoning_output_tokens\":2,\"total_tokens\":180}}}}\n",
        "{\"timestamp\":\"2025-11-03T10:00:05Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"legacy done\"}}\n",
        "{\"timestamp\":\"2025-11-03T10:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"second turn\"}}\n",
        "{\"timestamp\":\"2025-11-03T10:01:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n"
      ),
    )
    .expect("write sample");

    let turns = build_turns_for_session(
      &SessionRow {
        session_id: "session-2".to_string(),
        root_session_id: "session-2".to_string(),
        parent_session_id: None,
        title: String::new(),
        source_state: "active".to_string(),
        source_path: Some(path.to_string_lossy().to_string()),
        started_at: None,
        updated_at: None,
        agent_nickname: None,
        agent_role: None,
      },
      &HashMap::new(),
    )
    .expect("build turns");

    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].total_tokens, 180);
    assert_eq!(turns[0].status, "completed");
    assert_eq!(turns[0].user_message.as_deref(), Some("first turn"));
  }

  #[test]
  fn zero_delta_helper_keeps_reasoning_only_growth() {
    assert!(!is_zero_delta(&TokenUsage {
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 5,
      total_tokens: 0,
    }));
  }

  #[test]
  fn child_session_turns_drop_replayed_parent_turn_ids() {
    let root_session = SessionRow {
      session_id: "root-session".to_string(),
      root_session_id: "root-session".to_string(),
      parent_session_id: None,
      title: String::new(),
      source_state: "active".to_string(),
      source_path: None,
      started_at: None,
      updated_at: None,
      agent_nickname: None,
      agent_role: None,
    };
    let child_session = SessionRow {
      session_id: "child-session".to_string(),
      root_session_id: "root-session".to_string(),
      parent_session_id: Some("root-session".to_string()),
      title: String::new(),
      source_state: "active".to_string(),
      source_path: None,
      started_at: None,
      updated_at: None,
      agent_nickname: Some("Scout".to_string()),
      agent_role: Some("explore".to_string()),
    };

    let root_turn = ConversationTurnPoint {
      session_id: "root-session".to_string(),
      turn_id: "019d84da-0f42-7ed0-ada5-f5d70f7bc98b".to_string(),
      started_at: Some("2026-04-13T03:19:36.598Z".to_string()),
      completed_at: Some("2026-04-13T03:47:19.387Z".to_string()),
      last_activity_at: "2026-04-13T03:47:19.387Z".to_string(),
      status: "completed".to_string(),
      user_message: Some("root prompt".to_string()),
      assistant_message: Some("root answer".to_string()),
      model_ids: vec!["gpt-5.4".to_string()],
      input_tokens: 100,
      cached_input_tokens: 20,
      output_tokens: 30,
      reasoning_output_tokens: 0,
      total_tokens: 130,
      value_usd: 0.0,
      fast_mode_effective: false,
    };
    let replayed_root_turn = ConversationTurnPoint {
      session_id: "child-session".to_string(),
      turn_id: root_turn.turn_id.clone(),
      started_at: Some("2026-04-13T03:43:36.598Z".to_string()),
      completed_at: Some("2026-04-13T03:47:19.387Z".to_string()),
      last_activity_at: "2026-04-13T03:47:19.387Z".to_string(),
      status: "completed".to_string(),
      user_message: Some("root prompt".to_string()),
      assistant_message: Some("replayed root answer".to_string()),
      model_ids: vec!["gpt-5.4".to_string()],
      input_tokens: 100,
      cached_input_tokens: 20,
      output_tokens: 30,
      reasoning_output_tokens: 0,
      total_tokens: 130,
      value_usd: 0.0,
      fast_mode_effective: false,
    };
    let child_turn = ConversationTurnPoint {
      session_id: "child-session".to_string(),
      turn_id: "019d84fb-ead7-7c60-a6f1-ac683e7ee175".to_string(),
      started_at: Some("2026-04-13T03:56:35.420Z".to_string()),
      completed_at: Some("2026-04-13T03:57:25.668Z".to_string()),
      last_activity_at: "2026-04-13T03:57:25.668Z".to_string(),
      status: "completed".to_string(),
      user_message: Some("child prompt".to_string()),
      assistant_message: Some("child answer".to_string()),
      model_ids: vec!["gpt-5.4".to_string()],
      input_tokens: 80,
      cached_input_tokens: 10,
      output_tokens: 15,
      reasoning_output_tokens: 0,
      total_tokens: 95,
      value_usd: 0.0,
      fast_mode_effective: false,
    };

    let mut seen_real_turn_ids = HashSet::new();
    let root_filtered =
      filter_replayed_turns_for_session(&root_session, vec![root_turn.clone()], &mut seen_real_turn_ids);
    let child_filtered = filter_replayed_turns_for_session(
      &child_session,
      vec![replayed_root_turn, child_turn.clone()],
      &mut seen_real_turn_ids,
    );

    assert_eq!(root_filtered.len(), 1);
    assert_eq!(child_filtered.len(), 1);
    assert_eq!(child_filtered[0].turn_id, child_turn.turn_id);
  }

  #[test]
  fn synthetic_turn_ids_are_not_deduped_across_sessions() {
    let root_session = SessionRow {
      session_id: "root-session".to_string(),
      root_session_id: "root-session".to_string(),
      parent_session_id: None,
      title: String::new(),
      source_state: "active".to_string(),
      source_path: None,
      started_at: None,
      updated_at: None,
      agent_nickname: None,
      agent_role: None,
    };
    let child_session = SessionRow {
      session_id: "child-session".to_string(),
      root_session_id: "root-session".to_string(),
      parent_session_id: Some("root-session".to_string()),
      title: String::new(),
      source_state: "active".to_string(),
      source_path: None,
      started_at: None,
      updated_at: None,
      agent_nickname: None,
      agent_role: None,
    };

    let root_turn = ConversationTurnPoint {
      session_id: "root-session".to_string(),
      turn_id: "turn-0001".to_string(),
      started_at: None,
      completed_at: None,
      last_activity_at: "2026-04-13T03:19:36.598Z".to_string(),
      status: "completed".to_string(),
      user_message: Some("root".to_string()),
      assistant_message: Some("root".to_string()),
      model_ids: vec!["gpt-5.4".to_string()],
      input_tokens: 100,
      cached_input_tokens: 0,
      output_tokens: 20,
      reasoning_output_tokens: 0,
      total_tokens: 120,
      value_usd: 0.0,
      fast_mode_effective: false,
    };
    let child_turn = ConversationTurnPoint {
      session_id: "child-session".to_string(),
      turn_id: "turn-0001".to_string(),
      started_at: None,
      completed_at: None,
      last_activity_at: "2026-04-13T03:56:35.420Z".to_string(),
      status: "completed".to_string(),
      user_message: Some("child".to_string()),
      assistant_message: Some("child".to_string()),
      model_ids: vec!["gpt-5.4".to_string()],
      input_tokens: 80,
      cached_input_tokens: 0,
      output_tokens: 10,
      reasoning_output_tokens: 0,
      total_tokens: 90,
      value_usd: 0.0,
      fast_mode_effective: false,
    };

    let mut seen_real_turn_ids = HashSet::new();
    let root_filtered =
      filter_replayed_turns_for_session(&root_session, vec![root_turn], &mut seen_real_turn_ids);
    let child_filtered =
      filter_replayed_turns_for_session(&child_session, vec![child_turn], &mut seen_real_turn_ids);

    assert_eq!(root_filtered.len(), 1);
    assert_eq!(child_filtered.len(), 1);
  }

  #[test]
  fn subscription_month_window_uses_billing_anchor_day() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");
    let window = resolve_window(
      &conn,
      Some("subscription_month".to_string()),
      Some("2026-03-26".to_string()),
      None,
      None,
      &[],
      23,
      None,
      None,
    )
    .expect("resolve window");

    assert_eq!(window.window.anchor, "2026-03-23");
    assert_eq!(window.window.start.date_naive(), NaiveDate::from_ymd_opt(2026, 3, 23).unwrap());
    assert_eq!(window.window.end.date_naive(), NaiveDate::from_ymd_opt(2026, 4, 23).unwrap());
  }

  #[test]
  fn subscription_month_window_rolls_back_before_anchor_day() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");
    let window = resolve_window(
      &conn,
      Some("subscription_month".to_string()),
      Some("2026-03-05".to_string()),
      None,
      None,
      &[],
      23,
      None,
      None,
    )
    .expect("resolve window");

    assert_eq!(window.window.anchor, "2026-02-23");
    assert_eq!(window.window.start.date_naive(), NaiveDate::from_ymd_opt(2026, 2, 23).unwrap());
    assert_eq!(window.window.end.date_naive(), NaiveDate::from_ymd_opt(2026, 3, 23).unwrap());
  }

  #[test]
  fn custom_window_includes_selected_end_date() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");
    let window = resolve_window(
      &conn,
      Some("custom".to_string()),
      None,
      Some("2026-04-10".to_string()),
      Some("2026-04-12".to_string()),
      &[],
      1,
      None,
      None,
    )
    .expect("resolve custom window");

    assert_eq!(window.window.bucket, "custom");
    assert_eq!(window.window.anchor, "2026-04-10");
    assert_eq!(window.window.start.date_naive(), NaiveDate::from_ymd_opt(2026, 4, 10).unwrap());
    assert_eq!(window.window.end.date_naive(), NaiveDate::from_ymd_opt(2026, 4, 13).unwrap());
  }

  #[test]
  fn custom_window_rejects_end_before_start() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");
    let error = resolve_window(
      &conn,
      Some("custom".to_string()),
      None,
      Some("2026-04-12".to_string()),
      Some("2026-04-10".to_string()),
      &[],
      1,
      None,
      None,
    )
    .expect_err("custom end before start should fail");

    assert!(error.contains("Custom range end date cannot be before start date"));
  }

  #[test]
  fn five_hour_window_uses_live_rate_limit_window() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");
    let live_rate_limits = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 8,
        remaining_percent: 92,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-26T16:27:36+08:00".to_string()),
        window_start: Some("2026-03-26T11:27:36+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-26T14:33:00+08:00".to_string(),
    };
    insert_live_rate_limit_snapshot(&conn, &live_rate_limits).expect("insert live rate limit snapshot");

    let window =
      resolve_window(&conn, Some("five_hour".to_string()), None, None, None, &[], 1, Some(&live_rate_limits), None)
        .expect("resolve live window");

    assert_eq!(window.window.anchor, "2026-03-26");
    assert_eq!(window.window.start.to_rfc3339(), "2026-03-26T11:27:00+08:00");
    assert_eq!(window.window.end.to_rfc3339(), "2026-03-26T16:27:00+08:00");
  }

  #[test]
  fn menu_bar_api_value_uses_selected_live_window() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let conn = open_connection(&db_path).expect("open database");
    init_db(&conn).expect("init db");
    conn
      .execute(
        "
        INSERT INTO usage_events (
          session_id, timestamp, model_id, input_tokens, cached_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens, value_usd,
          fast_mode_auto, fast_mode_effective
        )
        VALUES
          ('inside', '2026-03-26T04:30:00Z', 'gpt-5.4', 0, 0, 0, 0, 0, 2.50, 0, 0),
          ('inside-offset', '2026-03-26T11:45:00+08:00', 'gpt-5.4', 0, 0, 0, 0, 0, 1.25, 0, 0),
          ('outside', '2026-03-26T09:30:00Z', 'gpt-5.4', 0, 0, 0, 0, 0, 7.25, 0, 0)
        ",
        [],
      )
      .expect("insert usage events");
    let live_rate_limits = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 8,
        remaining_percent: 92,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-26T16:27:36+08:00".to_string()),
        window_start: Some("2026-03-26T11:27:36+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-26T14:33:00+08:00".to_string(),
    };
    insert_live_rate_limit_snapshot(&conn, &live_rate_limits).expect("insert live rate limit snapshot");
    drop(conn);

    let api_value = get_window_api_value(
      &db_path,
      "five_hour".to_string(),
      None,
      None,
      None,
      Some(live_rate_limits),
      None,
    )
    .expect("load menu bar api value");

    assert_eq!(api_value, 3.75);
  }

  #[test]
  fn live_window_offset_selects_historical_window() {
    let conn = Connection::open_in_memory().expect("open in-memory database");
    init_db(&conn).expect("init db");

    let current = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 22,
        remaining_percent: 78,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-26T16:27:36+08:00".to_string()),
        window_start: Some("2026-03-26T11:27:36+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-26T14:33:00+08:00".to_string(),
    };
    let previous = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 48,
        remaining_percent: 52,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-26T11:27:36+08:00".to_string()),
        window_start: Some("2026-03-26T06:27:36+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-26T11:20:00+08:00".to_string(),
    };
    let older = LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: None,
      plan_type: Some("pro".to_string()),
      primary: Some(crate::models::RateLimitWindowSnapshot {
        used_percent: 71,
        remaining_percent: 29,
        window_duration_mins: Some(300),
        resets_at: Some("2026-03-26T06:27:36+08:00".to_string()),
        window_start: Some("2026-03-26T01:27:36+08:00".to_string()),
      }),
      secondary: None,
      fetched_at: "2026-03-26T06:20:00+08:00".to_string(),
    };
    insert_live_rate_limit_snapshot(&conn, &older).expect("insert older live window");
    insert_live_rate_limit_snapshot(&conn, &previous).expect("insert previous live window");
    insert_live_rate_limit_snapshot(&conn, &current).expect("insert current live window");

    let current_window = resolve_window(
      &conn,
      Some("five_hour".to_string()),
      None,
      None,
      None,
      &[],
      1,
      Some(&current),
      Some(0),
    )
    .expect("resolve current live window");
    assert_eq!(current_window.live_window_count, 2);

    let window =
      resolve_window(&conn, Some("five_hour".to_string()), None, None, None, &[], 1, Some(&current), Some(1))
        .expect("resolve historical live window");

    assert_eq!(window.live_window_offset, 1);
    assert_eq!(window.live_window_count, 3);
    assert_eq!(window.window.start.to_rfc3339(), "2026-03-26T06:27:00+08:00");
    assert_eq!(window.window.end.to_rfc3339(), "2026-03-26T11:27:00+08:00");
  }
}

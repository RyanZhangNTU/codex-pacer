use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use chrono::{
  DateTime, Datelike, Days, Local, LocalResult, Months, NaiveDate, NaiveDateTime, TimeZone,
  Timelike,
};
use rusqlite::Connection;
use serde_json::Value;

use crate::database::{get_fast_mode_override, get_subscription_profile, open_connection};
use crate::models::{
  CompositionShare, ConversationDetail, ConversationFilters, ConversationListItem,
  ConversationSessionSummary, ConversationTurnPoint, LiveRateLimitSnapshot, ModelShare,
  OverviewResponse, OverviewStats, PricingCatalogEntry, QuotaTrendPoint, SubscriptionProfile, TokenUsage,
  TrendPoint,
};
use crate::pricing::{
  calculate_value_usd, display_name_for_model, fast_mode_multiplier_for_model, is_codex_fast_mode_model,
  load_catalog_map, model_color, normalize_model_id, resolve_pricing,
};

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
  fast_mode_default: bool,
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

pub struct DashboardData {
  pub overview: OverviewResponse,
  pub conversations: Vec<ConversationListItem>,
  pub subscription_profile: SubscriptionProfile,
}

pub fn get_overview(
  db_path: &Path,
  bucket: Option<String>,
  anchor: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<OverviewResponse, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let sessions = load_sessions(&conn).map_err(|error| error.to_string())?;
  let events = load_events(&conn).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;
  build_overview(
    &conn,
    &sessions,
    &events,
    &profile,
    &catalog,
    bucket,
    anchor,
    live_rate_limits,
    live_window_offset,
  )
}

pub fn list_conversations(
  db_path: &Path,
  filters: Option<ConversationFilters>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
) -> Result<Vec<ConversationListItem>, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let sessions = load_sessions(&conn).map_err(|error| error.to_string())?;
  let events = load_events(&conn).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  build_conversation_list(&conn, &sessions, &events, &profile, filters, live_rate_limits.as_ref())
}

pub fn load_dashboard_data(
  db_path: &Path,
  bucket: Option<String>,
  anchor: Option<String>,
  search: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<DashboardData, String> {
  let conn = open_connection(db_path).map_err(|error| error.to_string())?;
  let sessions = load_sessions(&conn).map_err(|error| error.to_string())?;
  let events = load_events(&conn).map_err(|error| error.to_string())?;
  let profile = get_subscription_profile(&conn).map_err(|error| error.to_string())?;
  let catalog = load_catalog_map(&conn).map_err(|error| error.to_string())?;

  let overview = build_overview(
    &conn,
    &sessions,
    &events,
    &profile,
    &catalog,
    bucket.clone(),
    anchor.clone(),
    live_rate_limits.clone(),
    live_window_offset,
  )?;
  let conversations = build_conversation_list(
    &conn,
    &sessions,
    &events,
    &profile,
    Some(ConversationFilters {
      bucket,
      anchor,
      search,
      live_window_offset,
    }),
    live_rate_limits.as_ref(),
  )?;

  Ok(DashboardData {
    overview,
    conversations,
    subscription_profile: profile,
  })
}

fn build_overview(
  conn: &Connection,
  sessions: &HashMap<String, SessionRow>,
  events: &[EventRow],
  profile: &SubscriptionProfile,
  catalog: &HashMap<String, PricingCatalogEntry>,
  bucket: Option<String>,
  anchor: Option<String>,
  live_rate_limits: Option<LiveRateLimitSnapshot>,
  live_window_offset: Option<i64>,
) -> Result<OverviewResponse, String> {
  let resolved_window = resolve_window(
    conn,
    bucket,
    anchor,
    events,
    profile.billing_anchor_day,
    live_rate_limits.as_ref(),
    live_window_offset,
  )?;
  let window = &resolved_window.window;
  let filtered_events: Vec<_> = events
    .iter()
    .filter(|event| event_in_window(event, window))
    .cloned()
    .collect();

  let mut conversation_ids = HashSet::new();
  let mut total_value_usd = 0.0;
  let mut total_tokens = 0i64;
  let mut model_shares: HashMap<String, ModelShareAccumulator> = HashMap::new();

  for event in &filtered_events {
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

  let trend = build_trend(window, &filtered_events);
  let quota_trend = build_quota_trend(conn, window, &filtered_events, live_rate_limits.as_ref());
  let composition_breakdown = build_composition_breakdown(&filtered_events, catalog);
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

fn build_conversation_list(
  conn: &Connection,
  sessions: &HashMap<String, SessionRow>,
  events: &[EventRow],
  profile: &SubscriptionProfile,
  filters: Option<ConversationFilters>,
  live_rate_limits: Option<&LiveRateLimitSnapshot>,
) -> Result<Vec<ConversationListItem>, String> {
  let filters = filters.unwrap_or_default();
  let window = resolve_window(
    conn,
    filters.bucket.clone(),
    filters.anchor.clone(),
    events,
    profile.billing_anchor_day,
    live_rate_limits,
    filters.live_window_offset,
  )?
  .window;
  let search = filters.search.unwrap_or_default().to_ascii_lowercase();

  let mut groups: BTreeMap<String, ConversationAccumulator> = BTreeMap::new();

  for session in sessions.values() {
    let group = groups
      .entry(session.root_session_id.clone())
      .or_insert_with(|| ConversationAccumulator {
        title: session.title.clone(),
        started_at: session.started_at.clone(),
        updated_at: session.updated_at.clone(),
        model_ids: HashSet::new(),
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_output_tokens: 0,
        total_tokens: 0,
        session_ids: HashSet::new(),
        fast_session_ids: HashSet::new(),
        api_value_usd: 0.0,
        source_states: HashSet::new(),
      });

    if group.title.is_empty() {
      group.title = session.title.clone();
    }
    group.started_at = min_option_string(group.started_at.take(), session.started_at.clone());
    group.updated_at = max_option_string(group.updated_at.take(), session.updated_at.clone());
    group.session_ids.insert(session.session_id.clone());
    group.source_states.insert(session.source_state.clone());
  }

  for event in events {
    if !event_in_window(event, &window) {
      continue;
    }
    let Some(session) = sessions.get(&event.session_id) else {
      continue;
    };
    let group = groups.entry(session.root_session_id.clone()).or_default();
    group.model_ids.insert(event.model_id.clone());
    group.input_tokens += event.input_tokens;
    group.cached_input_tokens += event.cached_input_tokens;
    group.output_tokens += event.output_tokens;
    group.reasoning_output_tokens += event.reasoning_output_tokens;
    group.total_tokens += event.total_tokens;
    group.api_value_usd += event.value_usd;
    if event.fast_mode_effective {
      group.fast_session_ids.insert(event.session_id.clone());
    }
  }

  let mut items = Vec::new();
  for (root_session_id, group) in groups {
    let title = if group.title.trim().is_empty() {
      root_session_id.clone()
    } else {
      group.title.clone()
    };

    if !search.is_empty()
      && !title.to_ascii_lowercase().contains(&search)
      && !root_session_id.to_ascii_lowercase().contains(&search)
      && !group
        .session_ids
        .iter()
        .any(|session_id| session_id.to_ascii_lowercase().contains(&search))
    {
      continue;
    }

    if group.total_tokens == 0 && window.bucket != "total" {
      continue;
    }

    items.push(ConversationListItem {
      root_session_id,
      title,
      started_at: group.started_at,
      updated_at: group.updated_at,
      model_ids: sorted_strings(group.model_ids),
      input_tokens: group.input_tokens,
      cached_input_tokens: group.cached_input_tokens,
      output_tokens: group.output_tokens,
      reasoning_output_tokens: group.reasoning_output_tokens,
      total_tokens: group.total_tokens,
      session_count: group.session_ids.len(),
      subagent_count: group.session_ids.len().saturating_sub(1),
      has_fast_mode: !group.fast_session_ids.is_empty(),
      api_value_usd: group.api_value_usd,
      subscription_share: if profile.monthly_price > 0.0 {
        group.api_value_usd / profile.monthly_price
      } else {
        0.0
      },
      source_states: sorted_strings(group.source_states),
    });
  }

  items.sort_by(|left, right| {
    right
      .api_value_usd
      .total_cmp(&left.api_value_usd)
      .then_with(|| right.updated_at.cmp(&left.updated_at))
  });

  Ok(items)
}

pub fn get_conversation_detail(db_path: &Path, root_session_id: &str) -> Result<ConversationDetail, String> {
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
  let mut fast_mode_overrides = HashMap::new();
  let mut seen_real_turn_ids = HashSet::new();

  for session in &conversation_sessions {
    if title.is_empty() && !session.title.is_empty() {
      title = session.title.clone();
    }
    started_at = min_option_string(started_at, session.started_at.clone());
    updated_at = max_option_string(updated_at, session.updated_at.clone());
    source_states.insert(session.source_state.clone());
    let fast_mode_override = get_fast_mode_override(&conn, &session.session_id).map_err(|error| error.to_string())?;
    fast_mode_overrides.insert(session.session_id.clone(), fast_mode_override);
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
    let fast_mode_override = fast_mode_overrides
      .get(&session.session_id)
      .copied()
      .flatten();
    let turns = build_turns_for_session(session, fast_mode_override, &catalog)?;
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

  let mut session_summaries = Vec::new();
  for session in conversation_sessions {
    let summary = per_session.remove(&session.session_id).unwrap_or_default();
    let fast_mode_override = fast_mode_overrides
      .remove(&session.session_id)
      .unwrap_or(None);
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
      fast_mode_override,
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
    turns: detail_turns,
    model_breakdown,
    composition_breakdown,
  })
}

fn build_turns_for_session(
  session: &SessionRow,
  fast_mode_override: Option<bool>,
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
  let mut explicit_fast_mode: Option<bool> = None;
  let mut previous_usage: Option<TokenUsage> = None;

  for line in BufReader::new(file).lines().map_while(Result::ok) {
    if line.contains("\"fast_mode\":true") || line.contains("\"quick_mode\":true") {
      explicit_fast_mode = Some(true);
    }
    if line.contains("\"fast_mode\":false") || line.contains("\"quick_mode\":false") {
      explicit_fast_mode = Some(false);
    }

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
            let auto_fast =
              is_codex_fast_mode_model(&model_id) && explicit_fast_mode.unwrap_or(session.fast_mode_default);
            let effective_fast = fast_mode_override.unwrap_or(auto_fast);
            let value_usd =
              calculate_value_usd(&delta, resolve_pricing(catalog, &model_id).as_ref(), &model_id, effective_fast);
            let turn = &mut turns[turn_index];
            turn.model_ids.insert(model_id);
            turn.input_tokens += delta.input_tokens;
            turn.cached_input_tokens += delta.cached_input_tokens;
            turn.output_tokens += delta.output_tokens;
            turn.reasoning_output_tokens += delta.reasoning_output_tokens;
            turn.total_tokens += delta.total_tokens;
            turn.value_usd += value_usd;
            turn.fast_mode_effective |= effective_fast;
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
  if current.input_tokens < previous.input_tokens
    || current.cached_input_tokens < previous.cached_input_tokens
    || current.output_tokens < previous.output_tokens
    || current.reasoning_output_tokens < previous.reasoning_output_tokens
    || current.total_tokens < previous.total_tokens
  {
    return current.clone();
  }

  TokenUsage {
    input_tokens: current.input_tokens - previous.input_tokens,
    cached_input_tokens: current.cached_input_tokens - previous.cached_input_tokens,
    output_tokens: current.output_tokens - previous.output_tokens,
    reasoning_output_tokens: current.reasoning_output_tokens - previous.reasoning_output_tokens,
    total_tokens: current.total_tokens - previous.total_tokens,
  }
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
    let multiplier = if event.fast_mode_effective {
      fast_mode_multiplier_for_model(&event.model_id)
    } else {
      1.0
    };
    breakdown[0].api_value_usd +=
      ((event.input_tokens - event.cached_input_tokens).max(0) as f64 * multiplier / 1_000_000.0)
        * pricing.input_price_per_million;
    breakdown[1].api_value_usd +=
      (event.cached_input_tokens as f64 * multiplier / 1_000_000.0) * pricing.cached_input_price_per_million;
    breakdown[2].api_value_usd +=
      (event.output_tokens as f64 * multiplier / 1_000_000.0) * pricing.output_price_per_million;
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
  let mut stmt = conn.prepare(
    "
    SELECT session_id, root_session_id, parent_session_id, title, source_state, source_path,
           started_at, updated_at, agent_nickname, agent_role, fast_mode_default
    FROM sessions
    ",
  )?;
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
      fast_mode_default: row.get::<_, i64>(10)? != 0,
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
  let mut stmt = conn.prepare(
    "
    SELECT session_id, root_session_id, parent_session_id, title, source_state, source_path,
           started_at, updated_at, agent_nickname, agent_role, fast_mode_default
    FROM sessions
    WHERE root_session_id = ?1
    ",
  )?;
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
      fast_mode_default: row.get::<_, i64>(10)? != 0,
    })
  })?;

  let mut sessions = HashMap::new();
  for row in rows {
    let session = row?;
    sessions.insert(session.session_id.clone(), session);
  }
  Ok(sessions)
}

fn load_events(conn: &Connection) -> rusqlite::Result<Vec<EventRow>> {
  let mut stmt = conn.prepare(
    "
    SELECT session_id, timestamp, model_id, input_tokens, cached_input_tokens,
           output_tokens, reasoning_output_tokens, total_tokens, value_usd,
           fast_mode_auto, fast_mode_effective
    FROM usage_events
    ORDER BY timestamp ASC, id ASC
    ",
  )?;
  let rows = stmt.query_map([], |row| {
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

fn load_events_for_root_session(conn: &Connection, root_session_id: &str) -> rusqlite::Result<Vec<EventRow>> {
  let mut stmt = conn.prepare(
    "
    SELECT usage_events.session_id, usage_events.timestamp, usage_events.model_id,
           usage_events.input_tokens, usage_events.cached_input_tokens,
           usage_events.output_tokens, usage_events.reasoning_output_tokens,
           usage_events.total_tokens, usage_events.value_usd,
           usage_events.fast_mode_auto, usage_events.fast_mode_effective
    FROM usage_events
    INNER JOIN sessions ON sessions.session_id = usage_events.session_id
    WHERE sessions.root_session_id = ?1
    ORDER BY usage_events.timestamp ASC, usage_events.id ASC
    ",
  )?;
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

fn resolve_window(
  conn: &Connection,
  bucket: Option<String>,
  anchor: Option<String>,
  events: &[EventRow],
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
      if events.is_empty() {
        let start = local_midnight(anchor_date)?;
        (start, start + chrono::Duration::days(1), anchor_date, 0, 0)
      } else {
        let first = events
          .iter()
          .filter_map(|event| parse_rfc3339_local(&event.timestamp))
          .min()
          .ok_or_else(|| "No valid event timestamps found.".to_string())?;
        let last = events
          .iter()
          .filter_map(|event| parse_rfc3339_local(&event.timestamp))
          .max()
          .ok_or_else(|| "No valid event timestamps found.".to_string())?;
        let start_date = first.date_naive();
        let end_date = last.date_naive().checked_add_days(Days::new(1)).unwrap_or(last.date_naive());
        let start = local_midnight(start_date)?;
        let end = local_midnight(end_date)?;
        (start, end, start_date, 0, 0)
      }
    }
    _ => {
      return Err(format!(
        "Unsupported bucket {}. Expected day, week, five_hour, seven_day, subscription_month, month, year, or total.",
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
  let windows = load_live_rate_limit_windows(conn, bucket, current_window).map_err(|error| error.to_string())?;

  if windows.is_empty() {
    return Err(format!(
      "Live rate limits are unavailable for the {} view. Check that Codex is installed and logged in.",
      bucket
    ));
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
) -> rusqlite::Result<Vec<RateLimitWindowSummary>> {
  let mut stmt = conn.prepare(
    "
    SELECT window_start, resets_at
    FROM rate_limit_samples
    WHERE bucket = ?1
    GROUP BY window_start, resets_at
    ORDER BY window_start DESC, resets_at DESC
    ",
  )?;
  let rows = stmt.query_map(rusqlite::params![bucket], |row| {
    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
  })?;

  let mut windows = Vec::new();
  let mut seen = HashSet::new();
  for row in rows {
    let (window_start, resets_at) = row?;
    let Some(start) = parse_rfc3339_local(&window_start).map(normalize_local_timestamp) else {
      continue;
    };
    let Some(end) = parse_rfc3339_local(&resets_at).map(normalize_local_timestamp) else {
      continue;
    };
    let key = (start.to_rfc3339(), end.to_rfc3339());
    if !seen.insert(key) {
      continue;
    }
    windows.push(RateLimitWindowSummary { start, end });
  }

  windows.sort_by(|left, right| right.end.cmp(&left.end).then_with(|| right.start.cmp(&left.start)));

  let mut ordered = Vec::new();
  let mut cursor = current_window.or_else(|| windows.first().cloned());
  while let Some(window) = cursor {
    if !ordered
      .iter()
      .any(|existing: &RateLimitWindowSummary| existing.start == window.start && existing.end == window.end)
    {
      ordered.push(window.clone());
    }
    cursor = windows
      .iter()
      .filter(|candidate| candidate.end <= window.start)
      .max_by(|left, right| left.end.cmp(&right.end).then_with(|| left.start.cmp(&right.start)))
      .cloned();
  }

  Ok(ordered)
}

fn event_in_window(event: &EventRow, window: &Window) -> bool {
  parse_rfc3339_local(&event.timestamp)
    .map(|timestamp| timestamp >= window.start && timestamp < window.end)
    .unwrap_or(false)
}

fn build_trend(window: &Window, events: &[EventRow]) -> Vec<TrendPoint> {
  let bins = build_bins(window);
  let mut trend = Vec::new();
  for bin in bins {
    let mut api_value_usd = 0.0;
    let mut total_tokens = 0i64;
    for event in events {
      let Some(timestamp) = parse_rfc3339_local(&event.timestamp) else {
        continue;
      };
      if timestamp >= bin.start && timestamp < bin.end {
        api_value_usd += event.value_usd;
        total_tokens += event.total_tokens;
      }
    }
    trend.push(TrendPoint {
      label: bin.label,
      timestamp: bin.timestamp,
      api_value_usd,
      total_tokens,
    });
  }
  trend
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
  let mut trend = Vec::new();
  let mut cumulative_api_value_usd = 0.0;
  let mut cumulative_tokens = 0i64;

  for bin in bins {
    let mut api_value_usd = 0.0;
    let mut total_tokens = 0i64;
    for event in events {
      let Some(timestamp) = parse_rfc3339_local(&event.timestamp) else {
        continue;
      };
      if timestamp >= bin.start && timestamp < bin.end {
        api_value_usd += event.value_usd;
        total_tokens += event.total_tokens;
      }
    }

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
  let mut stmt = match conn.prepare(
    "
    SELECT sample_timestamp, used_percent, window_start, resets_at
    FROM rate_limit_samples
    WHERE bucket = ?1
    ORDER BY sample_timestamp ASC
    ",
  ) {
    Ok(stmt) => stmt,
    Err(_) => return Vec::new(),
  };

  let rows = match stmt.query_map(rusqlite::params![window.bucket], |row| {
    Ok((
      row.get::<_, String>(0)?,
      row.get::<_, i64>(1)?,
      row.get::<_, String>(2)?,
      row.get::<_, String>(3)?,
    ))
  }) {
    Ok(rows) => rows,
    Err(_) => return Vec::new(),
  };

  let target_start = normalize_local_timestamp(window.start);
  let target_end = normalize_local_timestamp(window.end);

  rows
    .filter_map(Result::ok)
    .filter_map(|(timestamp, used_percent, window_start, resets_at)| {
      let sample_window_start = parse_rfc3339_local(&window_start).map(normalize_local_timestamp)?;
      let sample_window_end = parse_rfc3339_local(&resets_at).map(normalize_local_timestamp)?;
      if sample_window_start != target_start || sample_window_end != target_end {
        return None;
      }
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
struct ConversationAccumulator {
  title: String,
  started_at: Option<String>,
  updated_at: Option<String>,
  model_ids: HashSet<String>,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
  reasoning_output_tokens: i64,
  total_tokens: i64,
  session_ids: HashSet<String>,
  fast_session_ids: HashSet<String>,
  api_value_usd: f64,
  source_states: HashSet<String>,
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
        fast_mode_default: true,
      },
      None,
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
        fast_mode_default: true,
      },
      None,
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
      fast_mode_default: true,
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
      fast_mode_default: true,
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
      fast_mode_default: true,
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
      fast_mode_default: true,
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
      resolve_window(&conn, Some("five_hour".to_string()), None, &[], 1, Some(&live_rate_limits), None)
        .expect("resolve live window");

    assert_eq!(window.window.anchor, "2026-03-26");
    assert_eq!(window.window.start.to_rfc3339(), "2026-03-26T11:27:00+08:00");
    assert_eq!(window.window.end.to_rfc3339(), "2026-03-26T16:27:00+08:00");
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
    insert_live_rate_limit_snapshot(&conn, &previous).expect("insert previous live window");
    insert_live_rate_limit_snapshot(&conn, &current).expect("insert current live window");

    let window =
      resolve_window(&conn, Some("five_hour".to_string()), None, &[], 1, Some(&current), Some(1))
        .expect("resolve historical live window");

    assert_eq!(window.live_window_offset, 1);
    assert!(window.live_window_count >= 2);
    assert_eq!(window.window.start.to_rfc3339(), "2026-03-26T06:27:00+08:00");
    assert_eq!(window.window.end.to_rfc3339(), "2026-03-26T11:27:00+08:00");
  }
}

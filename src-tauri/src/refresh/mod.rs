#![allow(dead_code)]

mod schedule;

use chrono::{DateTime, Utc};
use std::time::Duration;

#[allow(unused_imports)]
pub(crate) use schedule::{CoordinatorAction, CoordinatorEvent, CoordinatorState};

pub(crate) const LIVE_QUERY_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RefreshLane {
  Token,
  Live,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RefreshReason {
  Startup,
  Scheduled,
  Manual,
  SettingsChanged,
  Wake,
  Fallback,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum TokenScanKind {
  Incremental,
  Full,
}

#[derive(Clone, Debug)]
pub(crate) struct RefreshConfig {
  pub auto_scan_enabled: bool,
  pub interval: Duration,
  pub codex_home: Option<String>,
  pub token_last_success_wall: Option<DateTime<Utc>>,
  pub live_last_success_wall: Option<DateTime<Utc>>,
}

pub(crate) fn parse_persisted_success_wall(value: Option<&str>) -> Option<DateTime<Utc>> {
  value
    .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
    .map(|value| value.with_timezone(&Utc))
}

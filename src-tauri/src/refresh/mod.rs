#![allow(dead_code)]

mod schedule;

use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

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
#[repr(u8)]
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

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct ReasonSet(u8);

impl ReasonSet {
  pub(crate) fn from_reason(reason: RefreshReason) -> Self {
    let mut reasons = Self::default();
    reasons.insert(reason);
    reasons
  }

  pub(crate) fn insert(&mut self, reason: RefreshReason) {
    self.0 |= 1 << reason as u8;
  }

  pub(crate) fn remove(&mut self, reason: RefreshReason) {
    self.0 &= !(1 << reason as u8);
  }

  pub(crate) fn contains(self, reason: RefreshReason) -> bool {
    self.0 & (1 << reason as u8) != 0
  }

  pub(crate) fn merge(&mut self, other: Self) {
    self.0 |= other.0;
  }

  pub(crate) fn is_empty(self) -> bool {
    self.0 == 0
  }
}

impl From<RefreshReason> for ReasonSet {
  fn from(reason: RefreshReason) -> Self {
    Self::from_reason(reason)
  }
}

#[derive(Clone, Debug)]
pub(crate) struct TokenRequest {
  pub reasons: ReasonSet,
  pub kind: TokenScanKind,
  pub codex_home: Option<String>,
}

impl TokenRequest {
  pub(crate) fn scheduled() -> Self {
    Self::for_reason(RefreshReason::Scheduled)
  }

  pub(crate) fn for_reason(reason: RefreshReason) -> Self {
    Self {
      reasons: reason.into(),
      kind: TokenScanKind::Incremental,
      codex_home: None,
    }
  }

  pub(crate) fn manual_full(codex_home: Option<String>) -> Self {
    Self {
      reasons: RefreshReason::Manual.into(),
      kind: TokenScanKind::Full,
      codex_home,
    }
  }

  fn merge(&mut self, other: Self) {
    self.reasons.merge(other.reasons);
    self.kind = self.kind.max(other.kind);
    if other.codex_home.is_some() || self.codex_home.is_none() {
      self.codex_home = other.codex_home;
    }
  }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct LiveWaiterId(pub(crate) u64);

#[derive(Clone, Debug)]
pub(crate) struct LiveRequest {
  pub reasons: ReasonSet,
  pub waiter: Option<LiveWaiterId>,
}

impl LiveRequest {
  pub(crate) fn scheduled() -> Self {
    Self::for_reason(RefreshReason::Scheduled)
  }

  pub(crate) fn for_reason(reason: RefreshReason) -> Self {
    Self {
      reasons: reason.into(),
      waiter: None,
    }
  }

  pub(crate) fn manual(waiter: LiveWaiterId) -> Self {
    Self {
      reasons: RefreshReason::Manual.into(),
      waiter: Some(waiter),
    }
  }
}

#[derive(Clone, Debug)]
pub(crate) struct TokenExecutionRequest {
  pub generation: u64,
  pub source_generation: u64,
  pub request: TokenRequest,
}

#[derive(Clone, Debug)]
pub(crate) struct LiveExecutionRequest {
  pub generation: u64,
  pub source_generation: u64,
  pub reasons: ReasonSet,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct CommitMarker {
  pub sequence: u64,
  pub committed_at: Instant,
}

#[derive(Clone, Debug)]
pub(crate) struct DisplayInvalidation {
  pub usage_revision: u64,
  pub quota_revision: u64,
  pub settings_revision: u64,
  pub source_generation: u64,
  pub commit: CommitMarker,
}

#[derive(Clone, Debug)]
pub(crate) struct ExecutionCompletion {
  pub generation: u64,
  pub source_generation: u64,
  pub succeeded: bool,
  pub failure: Option<String>,
  pub completed_at: String,
  pub commit: Option<CommitMarker>,
  pub retry_jitter: Duration,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshCompletedEvent {
  pub refresh_revision: u64,
  pub lane: RefreshLane,
  pub generation: u64,
  pub usage_revision: u64,
  pub quota_revision: u64,
  pub source_generation: u64,
  pub succeeded: bool,
  pub failure: Option<String>,
  pub completed_at: String,
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

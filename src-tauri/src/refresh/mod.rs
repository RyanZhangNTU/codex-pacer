#![allow(dead_code)]

mod live_cache;
mod mutation;
mod power;
mod runtime;
mod schedule;

pub(crate) use live_cache::{LivePersistenceRetryState, LivePersistenceWork, LiveQuotaCache};
#[allow(unused_imports)]
pub(crate) use mutation::{MutationOutcome, MutationPriority, UsageMutationCoordinator};
#[allow(unused_imports)]
pub(crate) use power::{ActivityFactory, SystemActivityFactory};
#[allow(unused_imports)]
pub(crate) use runtime::{
  LaneStatus, LiveQuotaFetcher, LiveQuotaPersister, ManualLiveTicket, ManualRefreshTicket,
  ManualTokenTicket, MutationPhase, PreparedTokenRefresh, RefreshCoordinatorHandle, RefreshError,
  RefreshEventSink, RefreshLaneMetrics, RefreshMetricsSnapshot, RefreshRuntime,
  RefreshRuntimeDependencies, RefreshStatus, ShutdownResult, TokenRefreshExecutor,
};

use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

#[allow(unused_imports)]
pub(crate) use schedule::{
  CoordinatorAction, CoordinatorEvent, CoordinatorSnapshot, CoordinatorState, LaneScheduleSnapshot,
};

pub(crate) const LIVE_QUERY_TIMEOUT: Duration = Duration::from_secs(10);
pub(crate) const REFRESH_WAITER_CAPACITY: usize = 32;
pub(crate) const REFRESH_DETAIL_MAX_BYTES: usize = 256;

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RefreshLane {
  Token,
  Live,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub(crate) enum RefreshReason {
  Startup = 0,
  Scheduled = 1,
  Manual = 2,
  SettingsChanged = 3,
  Wake = 4,
  Fallback = 5,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum TokenScanKind {
  Incremental,
  Full,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(transparent)]
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

  pub(crate) fn bits(self) -> u8 {
    self.0
  }
}

impl From<RefreshReason> for ReasonSet {
  fn from(reason: RefreshReason) -> Self {
    Self::from_reason(reason)
  }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct TokenWaiterIds(Vec<TokenWaiterId>);

impl TokenWaiterIds {
  pub(crate) fn try_push(&mut self, waiter: TokenWaiterId) -> Result<(), RefreshRejectionCode> {
    if self.0.contains(&waiter) {
      return Ok(());
    }
    if self.0.len() >= REFRESH_WAITER_CAPACITY {
      return Err(RefreshRejectionCode::Busy);
    }
    self.0.push(waiter);
    Ok(())
  }

  pub(crate) fn as_slice(&self) -> &[TokenWaiterId] {
    &self.0
  }

  pub(crate) fn len(&self) -> usize {
    self.0.len()
  }

  pub(crate) fn is_empty(&self) -> bool {
    self.0.is_empty()
  }

  pub(crate) fn contains(&self, waiter: &TokenWaiterId) -> bool {
    self.0.contains(waiter)
  }

  pub(crate) fn clear(&mut self) {
    self.0.clear();
  }

  fn into_vec(self) -> Vec<TokenWaiterId> {
    self.0
  }
}

#[derive(Clone, Debug)]
pub(crate) struct TokenRequest {
  pub reasons: ReasonSet,
  pub kind: TokenScanKind,
  pub codex_home: Option<String>,
  pub waiter_ids: TokenWaiterIds,
  pub planned_due_at: Option<Instant>,
  source_generation: Option<u64>,
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
      waiter_ids: TokenWaiterIds::default(),
      planned_due_at: None,
      source_generation: None,
    }
  }

  pub(crate) fn for_reason_at(reason: RefreshReason, planned_due_at: Instant) -> Self {
    let mut request = Self::for_reason(reason);
    request.planned_due_at = Some(planned_due_at);
    request
  }

  pub(crate) fn manual_full(codex_home: Option<String>) -> Self {
    Self {
      reasons: RefreshReason::Manual.into(),
      kind: TokenScanKind::Full,
      codex_home,
      waiter_ids: TokenWaiterIds::default(),
      planned_due_at: None,
      source_generation: None,
    }
  }

  pub(crate) fn manual_full_with_waiter(codex_home: Option<String>, waiter: TokenWaiterId) -> Self {
    let mut request = Self::manual_full(codex_home);
    request
      .try_add_waiter(waiter)
      .expect("an empty token request accepts one waiter");
    request
  }

  pub(crate) fn try_add_waiter(
    &mut self,
    waiter: TokenWaiterId,
  ) -> Result<(), RefreshRejectionCode> {
    self.waiter_ids.try_push(waiter)
  }

  pub(crate) fn waiter_ids(&self) -> &[TokenWaiterId] {
    self.waiter_ids.as_slice()
  }

  fn try_merge(&mut self, other: Self) -> Result<(), Self> {
    if !self.same_source_identity(&other) {
      return Err(other);
    }
    self.reasons.merge(other.reasons);
    self.kind = self.kind.max(other.kind);
    for waiter in other.waiter_ids.into_vec() {
      self
        .waiter_ids
        .try_push(waiter)
        .expect("coordinator waiter capacity is enforced before request merges");
    }
    self.planned_due_at = earliest_due(self.planned_due_at, other.planned_due_at);
    Ok(())
  }

  fn same_source_identity(&self, other: &Self) -> bool {
    self.codex_home == other.codex_home && self.source_generation == other.source_generation
  }

  fn bind_configured_source(&mut self, source_generation: u64, codex_home: Option<String>) {
    self.codex_home = codex_home;
    self.source_generation = Some(source_generation);
  }

  fn bind_source_if_needed(&mut self, source_generation: u64, codex_home: Option<String>) {
    if self.source_generation.is_some() {
      return;
    }
    if self.codex_home.is_none() || self.codex_home == codex_home {
      self.bind_configured_source(source_generation, codex_home);
    }
  }

  fn is_bound_to_source_generation(&self, source_generation: u64) -> bool {
    self.source_generation == Some(source_generation)
  }

  fn drain_waiters(&mut self) -> Vec<TokenWaiterId> {
    std::mem::take(&mut self.waiter_ids).into_vec()
  }
}

fn earliest_due(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
  match (left, right) {
    (Some(left), Some(right)) => Some(left.min(right)),
    (Some(value), None) | (None, Some(value)) => Some(value),
    (None, None) => None,
  }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct TokenWaiterId(pub(crate) u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct LiveWaiterId(pub(crate) u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RefreshFailureCode {
  ExecutionFailed,
  SourceChanged,
  InvalidCompletion,
  PreparedPayloadMissing,
  WorkerPanicked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RefreshRejectionCode {
  Busy,
  InvalidRequest,
  Superseded,
  SourceChanged,
  Shutdown,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(transparent)]
pub(crate) struct RefreshDetail(String);

impl RefreshDetail {
  pub(crate) fn new(value: impl AsRef<str>) -> Self {
    let value = value.as_ref();
    if value.len() <= REFRESH_DETAIL_MAX_BYTES {
      return Self(value.to_string());
    }
    let mut end = REFRESH_DETAIL_MAX_BYTES;
    while !value.is_char_boundary(end) {
      end -= 1;
    }
    Self(value[..end].to_string())
  }

  pub(crate) fn as_str(&self) -> &str {
    &self.0
  }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum RefreshWaiterOutcome {
  Completed {
    generation: u64,
    succeeded: bool,
    failure_code: Option<RefreshFailureCode>,
    detail: Option<RefreshDetail>,
  },
  Rejected {
    code: RefreshRejectionCode,
    detail: Option<RefreshDetail>,
  },
}

#[derive(Clone, Debug)]
pub(crate) struct LiveRequest {
  pub reasons: ReasonSet,
  pub waiter: Option<LiveWaiterId>,
  pub planned_due_at: Option<Instant>,
}

impl LiveRequest {
  pub(crate) fn scheduled() -> Self {
    Self::for_reason(RefreshReason::Scheduled)
  }

  pub(crate) fn for_reason(reason: RefreshReason) -> Self {
    Self {
      reasons: reason.into(),
      waiter: None,
      planned_due_at: None,
    }
  }

  pub(crate) fn for_reason_at(reason: RefreshReason, planned_due_at: Instant) -> Self {
    let mut request = Self::for_reason(reason);
    request.planned_due_at = Some(planned_due_at);
    request
  }

  pub(crate) fn manual(waiter: LiveWaiterId) -> Self {
    Self {
      reasons: RefreshReason::Manual.into(),
      waiter: Some(waiter),
      planned_due_at: None,
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
  pub planned_due_at: Option<Instant>,
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
  pub failure_code: Option<RefreshFailureCode>,
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

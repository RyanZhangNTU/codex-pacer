use crate::models::{LiveQuotaState, LiveRateLimitSnapshot};
use chrono::{DateTime, Utc};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const PERSISTENCE_RETRY_SECONDS: [u64; 6] = [5, 15, 30, 60, 120, 300];
const MAX_PERSISTENCE_RETRY: Duration = Duration::from_secs(300);
const MIN_PERSISTENCE_RETRY: Duration = Duration::from_secs(1);

#[derive(Clone)]
pub(crate) struct LiveQuotaCache {
  inner: Arc<Mutex<LiveQuotaCacheInner>>,
}

struct LiveQuotaCacheInner {
  rate_limits: Option<Arc<LiveRateLimitSnapshot>>,
  source_fetched_at: Option<String>,
  cached_at: String,
  is_fallback: bool,
  last_live_success_at: Option<String>,
  refreshing: bool,
  fresh_at: Option<Instant>,
}

impl Default for LiveQuotaCache {
  fn default() -> Self {
    Self::new()
  }
}

impl LiveQuotaCache {
  pub(crate) fn new() -> Self {
    Self {
      inner: Arc::new(Mutex::new(LiveQuotaCacheInner {
        rate_limits: None,
        source_fetched_at: None,
        cached_at: "1970-01-01T00:00:00+00:00".to_string(),
        is_fallback: false,
        last_live_success_at: None,
        refreshing: false,
        fresh_at: None,
      })),
    }
  }

  pub(crate) fn state(&self) -> LiveQuotaState {
    state_from_inner(&lock(&self.inner))
  }

  pub(crate) fn rate_limits(&self) -> Option<Arc<LiveRateLimitSnapshot>> {
    lock(&self.inner).rate_limits.as_ref().map(Arc::clone)
  }

  pub(crate) fn publish_live(
    &self,
    snapshot: Arc<LiveRateLimitSnapshot>,
    monotonic_now: Instant,
    wall_now: DateTime<Utc>,
  ) -> LiveQuotaState {
    let mut inner = lock(&self.inner);
    inner.source_fetched_at = Some(snapshot.fetched_at.clone());
    inner.rate_limits = Some(snapshot);
    inner.cached_at = wall_now.to_rfc3339();
    inner.is_fallback = false;
    inner.last_live_success_at = Some(wall_now.to_rfc3339());
    inner.refreshing = false;
    inner.fresh_at = Some(monotonic_now);
    state_from_inner(&inner)
  }

  pub(crate) fn publish_fallback(
    &self,
    fallback: Arc<LiveRateLimitSnapshot>,
    _monotonic_now: Instant,
    wall_now: DateTime<Utc>,
  ) -> LiveQuotaState {
    let mut inner = lock(&self.inner);
    let replace = inner.rate_limits.as_ref().map_or(true, |current| {
      snapshot_is_strictly_newer(&fallback, current)
    });
    if replace {
      inner.source_fetched_at = Some(fallback.fetched_at.clone());
      inner.rate_limits = Some(fallback);
      inner.cached_at = wall_now.to_rfc3339();
    }
    inner.is_fallback = true;
    inner.refreshing = false;
    inner.fresh_at = None;
    state_from_inner(&inner)
  }

  pub(crate) fn set_refreshing(&self, refreshing: bool) -> LiveQuotaState {
    let mut inner = lock(&self.inner);
    inner.refreshing = refreshing;
    state_from_inner(&inner)
  }

  pub(crate) fn mark_current_as_fallback(&self) -> LiveQuotaState {
    let mut inner = lock(&self.inner);
    inner.refreshing = false;
    if inner.rate_limits.is_some() {
      inner.is_fallback = true;
      inner.fresh_at = None;
    }
    state_from_inner(&inner)
  }

  pub(crate) fn needs_live_refresh(&self, ttl: Duration, monotonic_now: Instant) -> bool {
    let inner = lock(&self.inner);
    inner.rate_limits.is_none()
      || inner.is_fallback
      || inner.fresh_at.map_or(true, |fresh_at| {
        monotonic_now.saturating_duration_since(fresh_at) > ttl
      })
  }
}

fn state_from_inner(inner: &LiveQuotaCacheInner) -> LiveQuotaState {
  LiveQuotaState {
    rate_limits: inner
      .rate_limits
      .as_ref()
      .map(|value| value.as_ref().clone()),
    source_fetched_at: inner.source_fetched_at.clone(),
    cached_at: inner.cached_at.clone(),
    is_fallback: inner.is_fallback,
    last_live_success_at: inner.last_live_success_at.clone(),
    refreshing: inner.refreshing,
  }
}

fn snapshot_is_strictly_newer(
  candidate: &LiveRateLimitSnapshot,
  current: &LiveRateLimitSnapshot,
) -> bool {
  match (
    parse_source_instant(&candidate.fetched_at),
    parse_source_instant(&current.fetched_at),
  ) {
    (Some(candidate), Some(current)) => candidate > current,
    (Some(_), None) => true,
    (None, Some(_)) => false,
    (None, None) => candidate.fetched_at > current.fetched_at,
  }
}

fn parse_source_instant(value: &str) -> Option<DateTime<Utc>> {
  DateTime::parse_from_rfc3339(value)
    .ok()
    .map(|value| value.with_timezone(&Utc))
}

fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
  value
    .lock()
    .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Clone)]
struct PersistenceItem {
  identity: u64,
  source_generation: u64,
  snapshot: Arc<LiveRateLimitSnapshot>,
}

#[derive(Clone)]
pub(crate) struct LivePersistenceWork {
  item: PersistenceItem,
}

impl LivePersistenceWork {
  pub(crate) fn identity(&self) -> u64 {
    self.item.identity
  }

  pub(crate) fn source_generation(&self) -> u64 {
    self.item.source_generation
  }

  pub(crate) fn snapshot(&self) -> &Arc<LiveRateLimitSnapshot> {
    &self.item.snapshot
  }
}

pub(crate) struct LivePersistenceRetryState {
  source_generation: Option<u64>,
  in_flight: Option<PersistenceItem>,
  latest_pending: Option<PersistenceItem>,
  failure_streak: u32,
  retry_at: Option<Instant>,
  next_identity: u64,
}

impl Default for LivePersistenceRetryState {
  fn default() -> Self {
    Self::new()
  }
}

impl LivePersistenceRetryState {
  pub(crate) fn new() -> Self {
    Self {
      source_generation: None,
      in_flight: None,
      latest_pending: None,
      failure_streak: 0,
      retry_at: None,
      next_identity: 0,
    }
  }

  pub(crate) fn publish(
    &mut self,
    snapshot: Arc<LiveRateLimitSnapshot>,
    source_generation: u64,
    _now: Instant,
  ) {
    if self.source_generation != Some(source_generation) {
      self.reset_source(source_generation);
    }
    self.next_identity = self.next_identity.saturating_add(1);
    self.latest_pending = Some(PersistenceItem {
      identity: self.next_identity,
      source_generation,
      snapshot,
    });
    self.failure_streak = 0;
    self.retry_at = None;
  }

  pub(crate) fn take_ready(
    &mut self,
    now: Instant,
    live_fetch_running: bool,
  ) -> Option<LivePersistenceWork> {
    if live_fetch_running || self.in_flight.is_some() {
      return None;
    }
    if self.retry_at.is_some_and(|deadline| deadline > now) {
      return None;
    }
    let item = self.latest_pending.take()?;
    self.retry_at = None;
    self.in_flight = Some(item.clone());
    Some(LivePersistenceWork { item })
  }

  pub(crate) fn finish(
    &mut self,
    work: &LivePersistenceWork,
    result: Result<(), String>,
    now: Instant,
    interval: Duration,
  ) -> bool {
    let matches = self
      .in_flight
      .as_ref()
      .is_some_and(|running| persistence_item_matches(running, &work.item));
    if !matches {
      return false;
    }
    self.in_flight = None;
    if self.source_generation != Some(work.item.source_generation) {
      if self.latest_pending.is_some() {
        self.retry_at = None;
      }
      return true;
    }
    match result {
      Ok(()) => {
        self.failure_streak = 0;
        self.retry_at = None;
      }
      Err(_) if self.latest_pending.is_some() => {
        self.retry_at = None;
      }
      Err(_) => {
        self.failure_streak = self.failure_streak.saturating_add(1);
        self.latest_pending = Some(work.item.clone());
        self.retry_at = Some(
          now
            .checked_add(persistence_retry_delay(self.failure_streak, interval))
            .unwrap_or(now),
        );
      }
    }
    true
  }

  pub(crate) fn abandon(&mut self, work: &LivePersistenceWork) -> bool {
    let matches = self
      .in_flight
      .as_ref()
      .is_some_and(|running| persistence_item_matches(running, &work.item));
    if !matches {
      return false;
    }
    self.in_flight = None;
    if self.latest_pending.is_some() {
      self.retry_at = None;
    }
    true
  }

  pub(crate) fn reset_source(&mut self, source_generation: u64) {
    if self.source_generation == Some(source_generation) {
      return;
    }
    self.source_generation = Some(source_generation);
    self.latest_pending = None;
    self.failure_streak = 0;
    self.retry_at = None;
  }

  pub(crate) fn cancel_pending(&mut self) {
    self.latest_pending = None;
    self.retry_at = None;
  }

  pub(crate) fn retry_deadline(&self) -> Option<Instant> {
    self.retry_at
  }

  pub(crate) fn has_in_flight(&self) -> bool {
    self.in_flight.is_some()
  }

  pub(crate) fn next_wait(&self, now: Instant, live_fetch_running: bool) -> Option<Duration> {
    if live_fetch_running || self.in_flight.is_some() || self.latest_pending.is_none() {
      return None;
    }
    Some(self.retry_at.map_or(Duration::ZERO, |deadline| {
      deadline.saturating_duration_since(now)
    }))
  }

  pub(crate) fn failure_streak(&self) -> u32 {
    self.failure_streak
  }
}

fn persistence_item_matches(left: &PersistenceItem, right: &PersistenceItem) -> bool {
  left.identity == right.identity
    && left.source_generation == right.source_generation
    && Arc::ptr_eq(&left.snapshot, &right.snapshot)
}

fn persistence_retry_delay(failure_streak: u32, interval: Duration) -> Duration {
  let index = failure_streak
    .saturating_sub(1)
    .min(PERSISTENCE_RETRY_SECONDS.len().saturating_sub(1) as u32) as usize;
  let base = Duration::from_secs(PERSISTENCE_RETRY_SECONDS[index]);
  let cap = interval
    .min(MAX_PERSISTENCE_RETRY)
    .max(MIN_PERSISTENCE_RETRY);
  base.min(cap).max(MIN_PERSISTENCE_RETRY)
}

#[cfg(test)]
mod tests {
  use super::{LivePersistenceRetryState, LiveQuotaCache};
  use crate::models::LiveRateLimitSnapshot;
  use chrono::{DateTime, Utc};
  use std::sync::Arc;
  use std::time::{Duration, Instant};

  fn utc(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
      .expect("valid test timestamp")
      .with_timezone(&Utc)
  }

  fn snapshot(fetched_at: &str) -> Arc<LiveRateLimitSnapshot> {
    Arc::new(LiveRateLimitSnapshot {
      limit_id: Some("codex".to_string()),
      limit_name: Some("Codex".to_string()),
      plan_type: Some("pro".to_string()),
      primary: None,
      secondary: None,
      fetched_at: fetched_at.to_string(),
    })
  }

  #[test]
  fn fallback_never_becomes_fresh_for_ttl() {
    let cache = LiveQuotaCache::new();
    let monotonic = Instant::now();
    let state = cache.publish_fallback(
      snapshot("2026-07-09T10:00:00+00:00"),
      monotonic,
      utc("2026-07-10T10:00:00Z"),
    );

    assert!(state.is_fallback);
    assert_eq!(
      state.source_fetched_at.as_deref(),
      Some("2026-07-09T10:00:00+00:00")
    );
    assert_eq!(state.last_live_success_at, None);
    assert!(cache.needs_live_refresh(Duration::from_secs(300), monotonic));
    assert!(cache.needs_live_refresh(Duration::from_secs(300), monotonic + Duration::from_secs(1)));
  }

  #[test]
  fn fallback_preserves_source_and_last_success() {
    let cache = LiveQuotaCache::new();
    let monotonic = Instant::now();
    let live = snapshot("2026-07-10T10:05:00Z");
    cache.publish_live(Arc::clone(&live), monotonic, utc("2026-07-10T10:06:00Z"));

    let state = cache.publish_fallback(
      snapshot("2026-07-10T10:00:00Z"),
      monotonic + Duration::from_secs(1),
      utc("2026-07-10T10:07:00Z"),
    );

    assert!(state.is_fallback);
    assert_eq!(
      state.source_fetched_at.as_deref(),
      Some("2026-07-10T10:05:00Z")
    );
    assert_eq!(
      state.last_live_success_at.as_deref(),
      Some("2026-07-10T10:06:00+00:00")
    );
    assert_eq!(state.cached_at, "2026-07-10T10:06:00+00:00");
    let cached = cache
      .rate_limits()
      .expect("newer in-memory snapshot remains");
    assert!(Arc::ptr_eq(&cached, &live));
    assert!(cache.needs_live_refresh(Duration::from_secs(300), monotonic));

    let current_only = LiveQuotaCache::new();
    current_only.publish_live(Arc::clone(&live), monotonic, utc("2026-07-10T10:06:00Z"));
    let marked = current_only.mark_current_as_fallback();
    assert!(marked.is_fallback);
    assert_eq!(marked.cached_at, "2026-07-10T10:06:00+00:00");
    assert_eq!(
      marked.source_fetched_at.as_deref(),
      Some("2026-07-10T10:05:00Z")
    );
    assert_eq!(
      marked.last_live_success_at.as_deref(),
      Some("2026-07-10T10:06:00+00:00")
    );
    assert!(current_only.needs_live_refresh(Duration::from_secs(300), monotonic));
  }

  #[test]
  fn persistence_retry_is_capped() {
    let mut retries = LivePersistenceRetryState::new();
    let initial_snapshot = snapshot("2026-07-10T10:05:00Z");
    let mut now = Instant::now();
    retries.publish(Arc::clone(&initial_snapshot), 7, now);

    for (index, expected) in [5, 15, 30, 60, 120, 300, 300].into_iter().enumerate() {
      let work = retries
        .take_ready(now, false)
        .expect("published or retried snapshot is ready");
      retries.finish(
        &work,
        Err("database busy".to_string()),
        now,
        Duration::from_secs(1_000),
      );
      let deadline = retries.retry_deadline().expect("failure schedules retry");
      assert_eq!(
        deadline.saturating_duration_since(now),
        Duration::from_secs(expected)
      );
      assert_eq!(retries.failure_streak(), index as u32 + 1);
      now = deadline;
    }

    let mut interval_capped = LivePersistenceRetryState::new();
    interval_capped.publish(Arc::clone(&initial_snapshot), 7, now);
    let first = interval_capped
      .take_ready(now, false)
      .expect("first capped work");
    interval_capped.finish(
      &first,
      Err("database busy".to_string()),
      now,
      Duration::from_secs(12),
    );
    now = interval_capped
      .retry_deadline()
      .expect("first capped deadline");
    let second = interval_capped
      .take_ready(now, false)
      .expect("second capped work");
    interval_capped.finish(
      &second,
      Err("database busy".to_string()),
      now,
      Duration::from_secs(12),
    );
    assert_eq!(
      interval_capped
        .retry_deadline()
        .expect("interval-capped deadline")
        .saturating_duration_since(now),
      Duration::from_secs(12)
    );

    let mut zero_interval = LivePersistenceRetryState::new();
    zero_interval.publish(initial_snapshot, 7, now);
    let work = zero_interval
      .take_ready(now, false)
      .expect("zero interval work");
    zero_interval.finish(&work, Err("database busy".to_string()), now, Duration::ZERO);
    assert_eq!(
      zero_interval
        .retry_deadline()
        .expect("nonzero retry deadline")
        .saturating_duration_since(now),
      Duration::from_secs(1)
    );

    let mut superseded = LivePersistenceRetryState::new();
    superseded.publish(snapshot("2026-07-10T10:05:00Z"), 7, now);
    let old = superseded
      .take_ready(now, false)
      .expect("old persistence work");
    superseded.publish(snapshot("2026-07-10T10:06:00Z"), 7, now);
    superseded.finish(
      &old,
      Err("old write failed".to_string()),
      now,
      Duration::from_secs(300),
    );
    assert_eq!(superseded.failure_streak(), 0);
    let latest = superseded
      .take_ready(now, false)
      .expect("newer work stays immediate");
    superseded.finish(
      &latest,
      Err("new write failed".to_string()),
      now,
      Duration::from_secs(300),
    );
    assert_eq!(
      superseded
        .retry_deadline()
        .expect("new value starts at first retry")
        .saturating_duration_since(now),
      Duration::from_secs(5)
    );
  }
}

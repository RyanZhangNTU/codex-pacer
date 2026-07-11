use super::{
  CommitMarker, DisplayInvalidation, ExecutionCompletion, LiveExecutionRequest, LiveRequest,
  LiveWaiterId, ReasonSet, RefreshCompletedEvent, RefreshConfig, RefreshDetail, RefreshFailureCode,
  RefreshLane, RefreshReason, RefreshRejectionCode, RefreshWaiterOutcome, TokenExecutionRequest,
  TokenRequest, TokenScanKind, TokenWaiterId, REFRESH_WAITER_CAPACITY,
};
use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub(crate) enum CoordinatorEvent {
  Timer,
  Wake,
  SettingsChanged(RefreshConfig),
  RequestToken(TokenRequest),
  RequestLive(LiveRequest),
  TokenPrepared {
    generation: u64,
    source_generation: u64,
  },
  TokenFinished(ExecutionCompletion),
  LiveFinished(ExecutionCompletion),
}

#[derive(Clone, Debug)]
pub(crate) enum CoordinatorAction {
  StartToken(TokenExecutionRequest),
  StartLive(LiveExecutionRequest),
  CommitToken {
    generation: u64,
    source_generation: u64,
  },
  DiscardToken {
    generation: u64,
    source_generation: u64,
  },
  PublishInvalidation(DisplayInvalidation),
  PublishCompletion(RefreshCompletedEvent),
  ResolveLiveWaiters {
    waiter_ids: Vec<LiveWaiterId>,
    outcome: RefreshWaiterOutcome,
  },
  ResolveTokenWaiters {
    waiter_ids: Vec<TokenWaiterId>,
    outcome: RefreshWaiterOutcome,
  },
}

struct LaneState {
  next_deadline: Instant,
  startup_due: bool,
  immediate_due_at: Option<Instant>,
  last_generation: u64,
  running_generation: Option<u64>,
  failure_streak: u32,
  retry_at: Option<Instant>,
  missed_deadline_count: u64,
  coalesced_trigger_count: u64,
  suppress_next_missed_count: bool,
  disabled_normal_overdue_lag: Option<Duration>,
  disabled_retry_overdue_lag: Option<Duration>,
}

impl LaneState {
  fn new(next_deadline: Instant, monotonic_now: Instant) -> Self {
    Self {
      next_deadline,
      startup_due: next_deadline <= monotonic_now,
      immediate_due_at: None,
      last_generation: 0,
      running_generation: None,
      failure_streak: 0,
      retry_at: None,
      missed_deadline_count: 0,
      coalesced_trigger_count: 0,
      suppress_next_missed_count: false,
      disabled_normal_overdue_lag: None,
      disabled_retry_overdue_lag: None,
    }
  }

  fn recalculate_interval(
    &mut self,
    now: Instant,
    old_interval: Duration,
    new_interval: Duration,
    count_missed: bool,
  ) {
    if self.startup_due || old_interval == new_interval {
      return;
    }

    let elapsed = if self.next_deadline > now {
      old_interval.saturating_sub(self.next_deadline.duration_since(now))
    } else {
      old_interval.saturating_add(now.duration_since(self.next_deadline))
    };
    let anchor = self.next_deadline.checked_sub(old_interval);
    let remaining = if anchor.is_some() {
      let phase = duration_remainder(elapsed, new_interval);
      if phase.is_zero() {
        new_interval
      } else {
        new_interval - phase
      }
    } else {
      let remaining = new_interval.saturating_sub(elapsed);
      if remaining.is_zero() {
        new_interval
      } else {
        remaining
      }
    };
    self.next_deadline = saturating_instant_add(now, remaining);
    self.immediate_due_at = if elapsed >= new_interval {
      if count_missed {
        let due_count = elapsed.as_nanos() / new_interval.as_nanos();
        let missed = due_count.saturating_sub(1).min(u64::MAX as u128) as u64;
        self.missed_deadline_count = self.missed_deadline_count.saturating_add(missed);
      }
      anchor
        .and_then(|anchor| anchor.checked_add(new_interval))
        .or_else(|| now.checked_sub(elapsed.saturating_sub(new_interval)))
        .or(Some(now))
    } else {
      None
    };
  }

  fn pause_normal_schedule(&mut self, now: Instant) {
    self.disabled_normal_overdue_lag = self
      .immediate_due_at
      .map(|planned_due_at| now.saturating_duration_since(planned_due_at));
  }

  fn resume_normal_schedule(&mut self, now: Instant) {
    if self.immediate_due_at.is_some() || self.next_deadline <= now {
      self.immediate_due_at = Some(
        self
          .disabled_normal_overdue_lag
          .and_then(|lag| now.checked_sub(lag))
          .unwrap_or(now),
      );
    }
    self.disabled_normal_overdue_lag = None;
    self.suppress_next_missed_count = self.next_deadline <= now;
  }

  fn pause_automatic_retry(&mut self, now: Instant) {
    self.disabled_retry_overdue_lag = self
      .retry_at
      .filter(|retry_at| *retry_at <= now)
      .map(|retry_at| now.saturating_duration_since(retry_at));
  }

  fn resume_automatic_retry(&mut self, now: Instant) -> Option<Instant> {
    let Some(retry_at) = self.retry_at else {
      self.disabled_retry_overdue_lag = None;
      return None;
    };
    if retry_at > now {
      self.disabled_retry_overdue_lag = None;
      return None;
    }
    let planned_due_at = self
      .disabled_retry_overdue_lag
      .take()
      .and_then(|lag| now.checked_sub(lag))
      .unwrap_or(now);
    self.retry_at = Some(planned_due_at);
    Some(planned_due_at)
  }

  fn capture_enabled_overdue(&mut self, now: Instant, interval: Duration) -> Option<Instant> {
    if self.next_deadline > now {
      return self.immediate_due_at;
    }
    let planned_due_at = self.immediate_due_at.unwrap_or(self.next_deadline);
    let had_immediate_due = self.immediate_due_at.is_some();
    let (next_deadline, missed) = advance_fixed_deadline(self.next_deadline, interval, now);
    self.next_deadline = next_deadline;
    let missed = if had_immediate_due {
      missed.saturating_add(1)
    } else {
      missed
    };
    self.missed_deadline_count = self.missed_deadline_count.saturating_add(missed);
    self.immediate_due_at = Some(planned_due_at);
    self.immediate_due_at
  }

  fn take_normal_due(
    &mut self,
    now: Instant,
    interval: Duration,
    trigger_reason: RefreshReason,
  ) -> Option<(RefreshReason, Instant)> {
    if self.immediate_due_at.is_none() && self.next_deadline > now {
      return None;
    }

    let had_immediate_due = self.immediate_due_at.is_some();
    let planned_due_at = self.immediate_due_at.unwrap_or(self.next_deadline);
    self.immediate_due_at = None;
    if self.next_deadline <= now {
      let (next_deadline, missed) = advance_fixed_deadline(self.next_deadline, interval, now);
      self.next_deadline = next_deadline;
      if !self.suppress_next_missed_count {
        let missed = if had_immediate_due {
          missed.saturating_add(1)
        } else {
          missed
        };
        self.missed_deadline_count = self.missed_deadline_count.saturating_add(missed);
      }
    }
    self.suppress_next_missed_count = false;
    let reason = if self.startup_due {
      RefreshReason::Startup
    } else {
      trigger_reason
    };
    self.startup_due = false;
    Some((reason, planned_due_at))
  }

  fn start_generation(&mut self) -> u64 {
    let generation = self
      .last_generation
      .checked_add(1)
      .expect("refresh generation overflowed");
    self.last_generation = generation;
    self.running_generation = Some(generation);
    generation
  }

  fn clear_running(&mut self) {
    self.running_generation = None;
  }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct LaneScheduleSnapshot {
  pub running_generation: Option<u64>,
  pub next_normal_deadline: Instant,
  pub retry_deadline: Option<Instant>,
  pub failure_streak: u32,
  pub pending: bool,
  pub pending_reasons: ReasonSet,
  pub missed_deadline_count: u64,
  pub coalesced_trigger_count: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct CoordinatorSnapshot {
  pub token: LaneScheduleSnapshot,
  pub live: LaneScheduleSnapshot,
  pub source_generation: u64,
  pub interval: Duration,
  pub auto_scan_enabled: bool,
}

pub(crate) struct CoordinatorState {
  config: RefreshConfig,
  token: LaneState,
  live: LaneState,
  token_running: Option<TokenExecutionRequest>,
  token_running_source_refresh: bool,
  token_pending_manual: Option<TokenRequest>,
  token_pending_automatic: Option<TokenRequest>,
  token_source_refresh_pending: Option<TokenRequest>,
  token_retry_request: Option<TokenRequest>,
  token_retry_source_refresh: bool,
  live_running: Option<LiveExecutionRequest>,
  live_pending: ReasonSet,
  live_pending_due_at: Option<Instant>,
  live_retry_reasons: ReasonSet,
  live_retry_planned_due_at: Option<Instant>,
  live_waiters: Vec<LiveWaiterId>,
  source_generation: u64,
  refresh_revision: u64,
  usage_revision: u64,
  quota_revision: u64,
  settings_revision: u64,
}

impl CoordinatorState {
  pub(crate) fn new(
    mut config: RefreshConfig,
    monotonic_now: Instant,
    wall_now: DateTime<Utc>,
  ) -> Self {
    assert!(
      !config.interval.is_zero(),
      "refresh interval must be positive"
    );
    config.interval = effective_interval(monotonic_now, config.interval);
    let token_next_deadline = initial_deadline(
      monotonic_now,
      wall_now,
      config.token_last_success_wall,
      config.interval,
    );
    let live_next_deadline = initial_deadline(
      monotonic_now,
      wall_now,
      config.live_last_success_wall,
      config.interval,
    );

    Self {
      config,
      token: LaneState::new(token_next_deadline, monotonic_now),
      live: LaneState::new(live_next_deadline, monotonic_now),
      token_running: None,
      token_running_source_refresh: false,
      token_pending_manual: None,
      token_pending_automatic: None,
      token_source_refresh_pending: None,
      token_retry_request: None,
      token_retry_source_refresh: false,
      live_running: None,
      live_pending: ReasonSet::default(),
      live_pending_due_at: None,
      live_retry_reasons: ReasonSet::default(),
      live_retry_planned_due_at: None,
      live_waiters: Vec::new(),
      source_generation: 0,
      refresh_revision: 0,
      usage_revision: 0,
      quota_revision: 0,
      settings_revision: 0,
    }
  }

  pub(crate) fn handle(&mut self, now: Instant, event: CoordinatorEvent) -> Vec<CoordinatorAction> {
    match event {
      CoordinatorEvent::Timer => self.handle_due(now, RefreshReason::Scheduled),
      CoordinatorEvent::Wake => self.handle_due(now, RefreshReason::Wake),
      CoordinatorEvent::SettingsChanged(config) => self.handle_settings_changed(now, config),
      CoordinatorEvent::RequestToken(mut request) => {
        let mut actions = Vec::with_capacity(2);
        if !self.prepare_token_intake(&mut request, &mut actions) {
          return actions;
        }
        if !self.config.auto_scan_enabled && !request.reasons.contains(RefreshReason::Manual) {
          return actions;
        }
        self.submit_token_request_with_due(now, request, &mut actions);
        actions
      }
      CoordinatorEvent::RequestLive(request) => {
        let mut actions = Vec::with_capacity(2);
        if let Some(waiter) = request.waiter {
          if !request.reasons.contains(RefreshReason::Manual) {
            actions.push(CoordinatorAction::ResolveLiveWaiters {
              waiter_ids: vec![waiter],
              outcome: rejected_outcome(RefreshRejectionCode::InvalidRequest, None),
            });
            return actions;
          }
        }
        if !self.config.auto_scan_enabled && !request.reasons.contains(RefreshReason::Manual) {
          return actions;
        }
        if let Some(waiter) = request.waiter {
          if !self.live_waiters.contains(&waiter)
            && self.live_waiters.len() >= REFRESH_WAITER_CAPACITY
          {
            actions.push(CoordinatorAction::ResolveLiveWaiters {
              waiter_ids: vec![waiter],
              outcome: rejected_outcome(RefreshRejectionCode::Busy, None),
            });
            return actions;
          }
        }
        self.submit_live_request_with_due(now, request, &mut actions);
        actions
      }
      CoordinatorEvent::TokenPrepared {
        generation,
        source_generation,
      } => self.handle_token_prepared(now, generation, source_generation),
      CoordinatorEvent::TokenFinished(completion) => self.handle_token_finished(now, completion),
      CoordinatorEvent::LiveFinished(completion) => self.handle_live_finished(now, completion),
    }
  }

  fn handle_due(&mut self, now: Instant, trigger_reason: RefreshReason) -> Vec<CoordinatorAction> {
    let mut token_request = self.take_due_token_request(now, trigger_reason);
    let live_request = self.take_due_live_request(now, trigger_reason);
    let mut actions = Vec::with_capacity(2);

    if let Some((request, source_refresh)) = token_request.take() {
      if source_refresh {
        self.submit_source_refresh_request(request, &mut actions);
      } else {
        self.submit_token_request(now, request, &mut actions);
      }
    }
    if let Some(request) = live_request {
      self.submit_live_request(now, request, &mut actions);
    }

    actions
  }

  fn submit_token_request_with_due(
    &mut self,
    now: Instant,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    let Some((due, due_is_source_refresh)) =
      self.take_due_token_request(now, RefreshReason::Scheduled)
    else {
      self.submit_token_request(now, request, actions);
      return;
    };

    if request.same_source_identity(&due) {
      request
        .try_merge(due)
        .expect("same source identity was checked before request-time due merge");
      self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
      if due_is_source_refresh {
        self.submit_source_refresh_request(request, actions);
      } else {
        self.submit_token_request(now, request, actions);
      }
      return;
    }

    let due_matches_protected = !due_is_source_refresh
      && self
        .token_source_refresh_pending
        .as_ref()
        .is_some_and(|protected| protected.same_source_identity(&due));
    let due_matches_protected_retry = !due_is_source_refresh
      && self.token_retry_source_refresh
      && self
        .token_retry_request
        .as_ref()
        .is_some_and(|protected| protected.same_source_identity(&due));
    if due_matches_protected {
      self
        .token_source_refresh_pending
        .as_mut()
        .expect("matching protected source refresh remains pending")
        .try_merge(due)
        .expect("same source identity was checked before protected due merge");
      self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
    } else if due_matches_protected_retry {
      self
        .token_retry_request
        .as_mut()
        .expect("matching protected retry remains pending")
        .try_merge(due)
        .expect("same source identity was checked before protected retry due merge");
      self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
    } else if due_is_source_refresh {
      self.submit_source_refresh_request(due, actions);
    } else {
      self.queue_token_pending_request(due, actions);
    }
    self.submit_token_request(now, request, actions);
  }

  fn submit_live_request_with_due(
    &mut self,
    now: Instant,
    mut request: LiveRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if let Some(due) = self.take_due_live_request(now, RefreshReason::Scheduled) {
      request.reasons.merge(due.reasons);
      request.planned_due_at = earliest_planned_due(request.planned_due_at, due.planned_due_at);
      self.live.coalesced_trigger_count = self.live.coalesced_trigger_count.saturating_add(1);
    }
    self.submit_live_request(now, request, actions);
  }

  fn handle_settings_changed(
    &mut self,
    now: Instant,
    mut config: RefreshConfig,
  ) -> Vec<CoordinatorAction> {
    assert!(
      !config.interval.is_zero(),
      "refresh interval must be positive"
    );
    config.interval = effective_interval(now, config.interval);
    let old_interval = self.config.interval;
    let source_changed = self.config.codex_home != config.codex_home;
    let disabling_auto_scan = self.config.auto_scan_enabled && !config.auto_scan_enabled;
    let enabling_auto_scan = !self.config.auto_scan_enabled && config.auto_scan_enabled;
    let auto_scan_remains_enabled = self.config.auto_scan_enabled && config.auto_scan_enabled;
    let settings_changed = self.config.auto_scan_enabled != config.auto_scan_enabled
      || old_interval != config.interval
      || source_changed;

    let token_enabled_due = disabling_auto_scan
      .then(|| self.token.capture_enabled_overdue(now, old_interval))
      .flatten();
    let live_enabled_due = disabling_auto_scan
      .then(|| self.live.capture_enabled_overdue(now, old_interval))
      .flatten();
    if !self.config.auto_scan_enabled && old_interval != config.interval {
      self.token.disabled_normal_overdue_lag = None;
      self.live.disabled_normal_overdue_lag = None;
    }

    self.token.recalculate_interval(
      now,
      old_interval,
      config.interval,
      auto_scan_remains_enabled,
    );
    self.live.recalculate_interval(
      now,
      old_interval,
      config.interval,
      auto_scan_remains_enabled,
    );
    self.token.immediate_due_at =
      earliest_planned_due(self.token.immediate_due_at, token_enabled_due);
    self.live.immediate_due_at = earliest_planned_due(self.live.immediate_due_at, live_enabled_due);
    if disabling_auto_scan {
      self.token.pause_normal_schedule(now);
      self.live.pause_normal_schedule(now);
      let token_retry_is_automatic_only = !self.token_retry_source_refresh
        && self
          .token_retry_request
          .as_ref()
          .is_some_and(|request| !request.reasons.contains(RefreshReason::Manual));
      if token_retry_is_automatic_only {
        self.token.pause_automatic_retry(now);
      } else {
        self.token.disabled_retry_overdue_lag = None;
      }
      let live_retry_is_automatic_only = !self.live_retry_reasons.is_empty()
        && !self.live_retry_reasons.contains(RefreshReason::Manual);
      if live_retry_is_automatic_only {
        self.live.pause_automatic_retry(now);
      } else {
        self.live.disabled_retry_overdue_lag = None;
      }
    }
    self.config = config;

    if enabling_auto_scan {
      self.token.resume_normal_schedule(now);
      self.live.resume_normal_schedule(now);
      let token_retry_is_automatic_only = !self.token_retry_source_refresh
        && self
          .token_retry_request
          .as_ref()
          .is_some_and(|request| !request.reasons.contains(RefreshReason::Manual));
      if token_retry_is_automatic_only {
        if let Some(planned_due_at) = self.token.resume_automatic_retry(now) {
          if let Some(request) = self.token_retry_request.as_mut() {
            request.planned_due_at = Some(planned_due_at);
          }
        }
      } else {
        self.token.disabled_retry_overdue_lag = None;
      }
      let live_retry_is_automatic_only = !self.live_retry_reasons.is_empty()
        && !self.live_retry_reasons.contains(RefreshReason::Manual);
      if live_retry_is_automatic_only {
        if let Some(planned_due_at) = self.live.resume_automatic_retry(now) {
          self.live_retry_planned_due_at = Some(planned_due_at);
        }
      } else {
        self.live.disabled_retry_overdue_lag = None;
      }
    }

    if disabling_auto_scan {
      self.prune_automatic_pending_work();
    }

    if settings_changed {
      self.settings_revision = self.settings_revision.saturating_add(1);
    }

    let mut token_request = None;
    let mut token_request_is_source_refresh = false;
    let mut live_request = None;
    let mut actions = Vec::with_capacity(4);
    if source_changed {
      self.source_generation = self
        .source_generation
        .checked_add(1)
        .expect("refresh source generation overflowed");
      self.token.failure_streak = 0;
      self.token.retry_at = None;
      self.token.disabled_retry_overdue_lag = None;
      if let Some(mut retry) = self.token_retry_request.take() {
        self.reject_token_waiters(
          retry.drain_waiters(),
          RefreshRejectionCode::SourceChanged,
          Some("refresh source changed"),
          &mut actions,
        );
      }
      self.token_retry_source_refresh = false;
      self.live.failure_streak = 0;
      self.live.retry_at = None;
      self.live.disabled_retry_overdue_lag = None;
      self.live_retry_reasons = ReasonSet::default();
      self.live_retry_planned_due_at = None;

      let mut request = TokenRequest::for_reason(RefreshReason::SettingsChanged);
      request.kind = TokenScanKind::Full;
      request.bind_configured_source(self.source_generation, self.config.codex_home.clone());
      if let Some(previous_source_refresh) = self.token_source_refresh_pending.take() {
        self.retarget_automatic_reasons(
          &mut request,
          previous_source_refresh,
          RefreshRejectionCode::SourceChanged,
          &mut actions,
        );
      }
      if let Some(pending) = self.token_pending_automatic.take() {
        self.retarget_automatic_reasons(
          &mut request,
          pending,
          RefreshRejectionCode::SourceChanged,
          &mut actions,
        );
      }
      if let Some(pending) = self.token_pending_manual.take() {
        if pending.same_source_identity(&request) {
          request
            .try_merge(pending)
            .expect("same source identity was checked before settings merge");
        } else if pending.source_generation.is_none() {
          let mut manual = pending;
          let mut automatic_reasons = manual.reasons;
          automatic_reasons.remove(RefreshReason::Manual);
          request.reasons.merge(automatic_reasons);
          request.planned_due_at =
            earliest_planned_due(request.planned_due_at, manual.planned_due_at);
          manual.reasons = RefreshReason::Manual.into();
          manual.planned_due_at = None;
          self.token_pending_manual = Some(manual);
        } else {
          self.retarget_automatic_reasons(
            &mut request,
            pending,
            RefreshRejectionCode::SourceChanged,
            &mut actions,
          );
        }
      }
      token_request = Some(request);
      token_request_is_source_refresh = true;
      if self.config.auto_scan_enabled {
        live_request = Some(LiveRequest::for_reason(RefreshReason::SettingsChanged));
      }
    }

    if let Some((due, due_is_source_refresh)) =
      self.take_due_token_request(now, RefreshReason::SettingsChanged)
    {
      let merged_existing = token_request.is_some();
      if let Err(due) = merge_token_request(&mut token_request, due) {
        self.queue_token_pending_request(due, &mut actions);
      } else {
        if merged_existing {
          self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
        }
        token_request_is_source_refresh |= due_is_source_refresh;
      }
    }
    if let Some(due) = self.take_due_live_request(now, RefreshReason::SettingsChanged) {
      if live_request.is_some() {
        self.live.coalesced_trigger_count = self.live.coalesced_trigger_count.saturating_add(1);
      }
      merge_live_request(&mut live_request, due);
    }

    if let Some(request) = token_request {
      if token_request_is_source_refresh {
        self.submit_source_refresh_request(request, &mut actions);
      } else {
        self.submit_token_request(now, request, &mut actions);
      }
    }
    if let Some(request) = live_request {
      self.submit_live_request(now, request, &mut actions);
    }
    actions
  }

  fn take_due_token_request(
    &mut self,
    now: Instant,
    trigger_reason: RefreshReason,
  ) -> Option<(TokenRequest, bool)> {
    let mut request = None;
    let mut source_refresh = false;
    if self.token.retry_at.is_some_and(|retry_at| retry_at <= now) {
      let retry_allowed = self.config.auto_scan_enabled
        || self.token_retry_source_refresh
        || self
          .token_retry_request
          .as_ref()
          .is_some_and(|value| value.reasons.contains(RefreshReason::Manual));
      if retry_allowed {
        self.token.retry_at = None;
        self.token.disabled_retry_overdue_lag = None;
        if let Some(retry) = self.token_retry_request.take() {
          merge_token_request(&mut request, retry)
            .expect("an empty due request accepts the retry source");
          source_refresh = self.token_retry_source_refresh;
          self.token_retry_source_refresh = false;
        }
      }
    }

    if self.config.auto_scan_enabled {
      if let Some((reason, planned_due_at)) =
        self
          .token
          .take_normal_due(now, self.config.interval, trigger_reason)
      {
        let mut automatic = TokenRequest::for_reason_at(reason, planned_due_at);
        automatic.bind_configured_source(self.source_generation, self.config.codex_home.clone());
        let retry_has_different_source = request
          .as_ref()
          .is_some_and(|retry| !retry.same_source_identity(&automatic));
        if retry_has_different_source {
          self.queue_token_pending_request(automatic, &mut Vec::new());
        } else {
          if request.is_some() {
            self.token.coalesced_trigger_count =
              self.token.coalesced_trigger_count.saturating_add(1);
          }
          merge_token_request(&mut request, automatic)
            .expect("same configured source was checked before deadline merge");
        }
      }
    }
    request.map(|request| (request, source_refresh))
  }

  fn take_due_live_request(
    &mut self,
    now: Instant,
    trigger_reason: RefreshReason,
  ) -> Option<LiveRequest> {
    let mut reasons = ReasonSet::default();
    let mut planned_due_at = None;
    if self.live.retry_at.is_some_and(|retry_at| retry_at <= now) {
      let retry_allowed =
        self.config.auto_scan_enabled || self.live_retry_reasons.contains(RefreshReason::Manual);
      if retry_allowed {
        self.live.retry_at = None;
        self.live.disabled_retry_overdue_lag = None;
        reasons.merge(std::mem::take(&mut self.live_retry_reasons));
        planned_due_at = self.live_retry_planned_due_at.take();
      }
    }

    if self.config.auto_scan_enabled {
      if let Some((reason, normal_due_at)) =
        self
          .live
          .take_normal_due(now, self.config.interval, trigger_reason)
      {
        if !reasons.is_empty() {
          self.live.coalesced_trigger_count = self.live.coalesced_trigger_count.saturating_add(1);
        }
        reasons.insert(reason);
        planned_due_at = earliest_planned_due(planned_due_at, Some(normal_due_at));
      }
    }
    (!reasons.is_empty()).then_some(LiveRequest {
      reasons,
      waiter: None,
      planned_due_at,
    })
  }

  fn submit_token_request(
    &mut self,
    now: Instant,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if request.reasons.is_empty() {
      return;
    }
    request.bind_source_if_needed(self.source_generation, self.config.codex_home.clone());

    if self.token.running_generation.is_some() {
      if let Some(source_refresh) = self.token_source_refresh_pending.as_mut() {
        if source_refresh.same_source_identity(&request) {
          source_refresh
            .try_merge(request)
            .expect("same source identity was checked before protected merge");
          self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
          return;
        }
      }
      self.queue_token_pending_request(request, actions);
      return;
    }

    if self.token_retry_source_refresh {
      if let Some(source_retry) = self.token_retry_request.as_mut() {
        if source_retry.same_source_identity(&request) {
          source_retry
            .try_merge(request)
            .expect("same source identity was checked before protected retry merge");
          self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
        } else {
          self.queue_token_pending_request(request, actions);
        }
        return;
      }
      self.token_retry_source_refresh = false;
    }

    let preserves_manual_retry = self.token_retry_request.as_ref().is_some_and(|retry| {
      retry.reasons.contains(RefreshReason::Manual)
        && !request.reasons.contains(RefreshReason::Manual)
        && !retry.same_source_identity(&request)
    });
    if preserves_manual_retry {
      self.queue_token_pending_request(request, actions);
      return;
    }

    if let Some(mut retry) = self.token_retry_request.take() {
      if retry.same_source_identity(&request) {
        let retry_was_manual = retry.reasons.contains(RefreshReason::Manual);
        let retry_due_was_eligible = self.token.retry_at.is_some_and(|retry_at| retry_at <= now)
          && (self.config.auto_scan_enabled || self.token_retry_source_refresh || retry_was_manual);
        if !retry_due_was_eligible {
          retry.planned_due_at = if !self.config.auto_scan_enabled && !retry_was_manual {
            self
              .token
              .disabled_retry_overdue_lag
              .and_then(|lag| now.checked_sub(lag))
          } else {
            None
          };
        }
        retry
          .try_merge(request)
          .expect("same source identity was checked before retry merge");
        request = retry;
        self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
      } else {
        self.reject_token_waiters(
          retry.drain_waiters(),
          RefreshRejectionCode::Superseded,
          Some("refresh request was superseded"),
          actions,
        );
      }
    }
    self.token.retry_at = None;
    self.token.disabled_retry_overdue_lag = None;
    self.start_token_request(request, false, actions);
  }

  fn queue_token_pending_request(
    &mut self,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
    if request.reasons.contains(RefreshReason::Manual) {
      let automatic_matches = self
        .token_pending_automatic
        .as_ref()
        .is_some_and(|pending| pending.same_source_identity(&request));
      if automatic_matches {
        if let Some(automatic) = self.token_pending_automatic.take() {
          request
            .try_merge(automatic)
            .expect("same source identity was checked before pending merge");
        }
      }
      if let Some(mut manual) = self.token_pending_manual.take() {
        if manual.same_source_identity(&request) {
          manual
            .try_merge(request)
            .expect("same source identity was checked before manual merge");
          self.token_pending_manual = Some(manual);
        } else {
          self.reject_token_waiters(
            manual.drain_waiters(),
            RefreshRejectionCode::Superseded,
            Some("refresh request was superseded"),
            actions,
          );
          self.retain_automatic_request(manual, actions);
          self.token_pending_manual = Some(request);
        }
      } else {
        self.token_pending_manual = Some(request);
      }
      return;
    }

    if let Some(manual) = self.token_pending_manual.as_mut() {
      if manual.same_source_identity(&request) {
        manual
          .try_merge(request)
          .expect("same source identity was checked before automatic merge");
        return;
      }
    }
    if let Some(mut automatic) = self.token_pending_automatic.take() {
      if automatic.same_source_identity(&request) {
        automatic
          .try_merge(request)
          .expect("same source identity was checked before automatic merge");
        self.token_pending_automatic = Some(automatic);
      } else {
        self.reject_token_waiters(
          automatic.drain_waiters(),
          RefreshRejectionCode::Superseded,
          Some("refresh request was superseded"),
          actions,
        );
        self.token_pending_automatic = Some(request);
      }
    } else {
      self.token_pending_automatic = Some(request);
    }
  }

  fn start_token_request(
    &mut self,
    mut request: TokenRequest,
    source_refresh: bool,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if request
      .source_generation
      .is_some_and(|generation| generation != self.source_generation)
    {
      self.reject_token_waiters(
        request.drain_waiters(),
        RefreshRejectionCode::SourceChanged,
        Some("refresh source changed"),
        actions,
      );
      request.reasons.remove(RefreshReason::Manual);
      if request.reasons.is_empty() {
        return;
      }
      request.bind_configured_source(self.source_generation, self.config.codex_home.clone());
      request.kind = TokenScanKind::Full;
      request.reasons.insert(RefreshReason::SettingsChanged);
    }
    let generation = self.token.start_generation();
    let execution = TokenExecutionRequest {
      generation,
      source_generation: self.source_generation,
      request,
    };
    self.token_running = Some(execution.clone());
    self.token_running_source_refresh = source_refresh;
    actions.push(CoordinatorAction::StartToken(execution));
  }

  fn submit_source_refresh_request(
    &mut self,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if self.token.running_generation.is_some() {
      let matches_running_source_refresh = self.token_running_source_refresh
        && self
          .token_running
          .as_ref()
          .is_some_and(|running| running.request.same_source_identity(&request));
      if matches_running_source_refresh {
        if let Err(request) = merge_token_request(&mut self.token_source_refresh_pending, request) {
          self.token_source_refresh_pending = Some(request);
        }
        self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
        return;
      }
      if let Some(previous) = self.token_source_refresh_pending.take() {
        if request.same_source_identity(&previous) {
          request
            .try_merge(previous)
            .expect("same source identity was checked before source-refresh merge");
        } else {
          self.retarget_automatic_reasons(
            &mut request,
            previous,
            RefreshRejectionCode::SourceChanged,
            actions,
          );
        }
      }
      self.token_source_refresh_pending = Some(request);
      self.token.coalesced_trigger_count = self.token.coalesced_trigger_count.saturating_add(1);
      return;
    }
    self.token.retry_at = None;
    if let Some(mut retry) = self.token_retry_request.take() {
      self.reject_token_waiters(
        retry.drain_waiters(),
        RefreshRejectionCode::SourceChanged,
        Some("refresh source changed"),
        actions,
      );
    }
    self.token_retry_source_refresh = false;
    self.start_token_request(request, true, actions);
  }

  fn submit_live_request(
    &mut self,
    now: Instant,
    mut request: LiveRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if self.live.running_generation.is_some() {
      if let Some(waiter) = request.waiter {
        push_unique_waiter(&mut self.live_waiters, waiter);
      }
      request.reasons.remove(RefreshReason::Manual);
      self.live_pending.merge(request.reasons);
      self.live_pending_due_at =
        earliest_planned_due(self.live_pending_due_at, request.planned_due_at);
      self.live.coalesced_trigger_count = self.live.coalesced_trigger_count.saturating_add(1);
      return;
    }

    if let Some(waiter) = request.waiter {
      push_unique_waiter(&mut self.live_waiters, waiter);
    }
    let had_retry = !self.live_retry_reasons.is_empty();
    let retry_was_manual = self.live_retry_reasons.contains(RefreshReason::Manual);
    let retry_due_was_eligible = self.live.retry_at.is_some_and(|retry_at| retry_at <= now)
      && (self.config.auto_scan_enabled || retry_was_manual);
    request
      .reasons
      .merge(std::mem::take(&mut self.live_retry_reasons));
    let retry_planned_due_at = self.live_retry_planned_due_at.take();
    let retry_planned_due_at = if retry_due_was_eligible {
      retry_planned_due_at
    } else if !self.config.auto_scan_enabled && !retry_was_manual {
      self
        .live
        .disabled_retry_overdue_lag
        .and_then(|lag| now.checked_sub(lag))
    } else {
      None
    };
    request.planned_due_at = earliest_planned_due(request.planned_due_at, retry_planned_due_at);
    self.live.retry_at = None;
    self.live.disabled_retry_overdue_lag = None;
    if had_retry {
      self.live.coalesced_trigger_count = self.live.coalesced_trigger_count.saturating_add(1);
    }
    if request.reasons.is_empty() {
      return;
    }

    let generation = self.live.start_generation();
    let execution = LiveExecutionRequest {
      generation,
      source_generation: self.source_generation,
      reasons: request.reasons,
      planned_due_at: request.planned_due_at,
    };
    self.live_running = Some(execution.clone());
    actions.push(CoordinatorAction::StartLive(execution));
  }

  fn handle_token_prepared(
    &mut self,
    now: Instant,
    generation: u64,
    source_generation: u64,
  ) -> Vec<CoordinatorAction> {
    let mut actions = Vec::with_capacity(2);
    let Some(running) = self.token_running.as_ref() else {
      actions.push(CoordinatorAction::DiscardToken {
        generation,
        source_generation,
      });
      return actions;
    };

    if running.generation != generation {
      actions.push(CoordinatorAction::DiscardToken {
        generation,
        source_generation,
      });
      return actions;
    }

    if running.source_generation == source_generation && source_generation == self.source_generation
    {
      actions.push(CoordinatorAction::CommitToken {
        generation,
        source_generation,
      });
      return actions;
    }

    let stale = self
      .token_running
      .take()
      .expect("matching token generation remains present");
    self.token.clear_running();
    self.token_running_source_refresh = false;
    actions.push(CoordinatorAction::DiscardToken {
      generation,
      source_generation,
    });
    let mut stale_request = stale.request;
    let stale_waiters = stale_request.drain_waiters();
    self.complete_token_waiters(
      stale_waiters,
      generation,
      false,
      Some(RefreshFailureCode::SourceChanged),
      Some("refresh source changed"),
      &mut actions,
    );
    let mut replacement = self.token_source_refresh_pending.take().unwrap_or_else(|| {
      let mut request = TokenRequest::for_reason(RefreshReason::SettingsChanged);
      request.kind = TokenScanKind::Full;
      request.bind_configured_source(self.source_generation, self.config.codex_home.clone());
      request
    });
    self.retarget_automatic_reasons(
      &mut replacement,
      stale_request,
      RefreshRejectionCode::SourceChanged,
      &mut actions,
    );
    self.token_source_refresh_pending = Some(replacement);
    self.start_pending_token(now, &mut actions);
    actions
  }

  fn handle_token_finished(
    &mut self,
    now: Instant,
    completion: ExecutionCompletion,
  ) -> Vec<CoordinatorAction> {
    let Some(running) = self.token_running.as_ref() else {
      return Vec::new();
    };
    if running.generation != completion.generation {
      return Vec::new();
    }

    let mut running = self
      .token_running
      .take()
      .expect("matching token generation remains present");
    let running_source_refresh = self.token_running_source_refresh;
    self.token.clear_running();
    self.token_running_source_refresh = false;
    if running.source_generation != completion.source_generation
      || completion.source_generation != self.source_generation
    {
      let mut actions = Vec::with_capacity(3);
      let waiters = running.request.drain_waiters();
      self.complete_token_waiters(
        waiters,
        completion.generation,
        false,
        Some(RefreshFailureCode::SourceChanged),
        Some("refresh source changed"),
        &mut actions,
      );
      self.start_pending_token(now, &mut actions);
      return actions;
    }

    let completion = normalize_completion(completion);
    let waiters = running.request.drain_waiters();
    let mut actions = Vec::with_capacity(4);
    if completion.succeeded {
      self.token.failure_streak = 0;
      self.token.retry_at = None;
      self.token.disabled_retry_overdue_lag = None;
      self.token_retry_request = None;
      self.token_retry_source_refresh = false;
      self.usage_revision = self.usage_revision.saturating_add(1);
      actions.push(CoordinatorAction::PublishInvalidation(
        self.invalidation(
          completion
            .commit
            .expect("normalized success has commit marker"),
        ),
      ));
    } else {
      self.token.failure_streak = self.token.failure_streak.saturating_add(1);
      let jitter = completion.retry_jitter.min(Duration::from_secs(1));
      let delay = retry_delay(self.token.failure_streak, self.config.interval, jitter);
      let retry_at = now.checked_add(delay).unwrap_or(now);
      self.token.retry_at = Some(retry_at);
      self.token.disabled_retry_overdue_lag = None;
      let mut retry_request = running.request;
      retry_request.planned_due_at = Some(retry_at);
      if running_source_refresh {
        if let Some(pending) = self.token_source_refresh_pending.take() {
          if retry_request.same_source_identity(&pending) {
            retry_request
              .try_merge(pending)
              .expect("same source identity was checked before protected retry merge");
          } else {
            self.retarget_automatic_reasons(
              &mut retry_request,
              pending,
              RefreshRejectionCode::SourceChanged,
              &mut actions,
            );
          }
        }
        let pending_manual_matches = self
          .token_pending_manual
          .as_ref()
          .is_some_and(|pending| retry_request.same_source_identity(pending));
        if pending_manual_matches {
          retry_request
            .try_merge(
              self
                .token_pending_manual
                .take()
                .expect("matching protected follow-up remains pending"),
            )
            .expect("same source identity was checked before protected follow-up merge");
        }
        let pending_automatic_matches = self
          .token_pending_automatic
          .as_ref()
          .is_some_and(|pending| retry_request.same_source_identity(pending));
        if pending_automatic_matches {
          retry_request
            .try_merge(
              self
                .token_pending_automatic
                .take()
                .expect("matching protected automatic follow-up remains pending"),
            )
            .expect("same source identity was checked before protected automatic merge");
        }
      }
      self.token_retry_request = Some(retry_request);
      self.token_retry_source_refresh = running_source_refresh;
    }
    actions.push(CoordinatorAction::PublishCompletion(
      self.completed_event(RefreshLane::Token, &completion),
    ));
    self.complete_token_waiters(
      waiters,
      completion.generation,
      completion.succeeded,
      completion.failure_code,
      completion.failure.as_deref(),
      &mut actions,
    );
    self.start_pending_token(now, &mut actions);
    actions
  }

  fn handle_live_finished(
    &mut self,
    now: Instant,
    completion: ExecutionCompletion,
  ) -> Vec<CoordinatorAction> {
    let Some(running) = self.live_running.as_ref() else {
      return Vec::new();
    };
    if running.generation != completion.generation {
      return Vec::new();
    }

    let running = self
      .live_running
      .take()
      .expect("matching live generation remains present");
    self.live.clear_running();
    let waiters = std::mem::take(&mut self.live_waiters);
    if running.source_generation != completion.source_generation
      || completion.source_generation != self.source_generation
    {
      let mut actions = Vec::with_capacity(2);
      self.complete_live_waiters(
        waiters,
        completion.generation,
        false,
        Some(RefreshFailureCode::SourceChanged),
        Some("refresh source changed"),
        &mut actions,
      );
      self.start_pending_live(now, &mut actions);
      return actions;
    }

    let completion = normalize_completion(completion);
    let mut actions = Vec::with_capacity(4);
    if completion.succeeded {
      self.live.failure_streak = 0;
      self.live.retry_at = None;
      self.live.disabled_retry_overdue_lag = None;
      self.live_retry_reasons = ReasonSet::default();
      self.quota_revision = self.quota_revision.saturating_add(1);
      actions.push(CoordinatorAction::PublishInvalidation(
        self.invalidation(
          completion
            .commit
            .expect("normalized success has commit marker"),
        ),
      ));
    } else {
      self.live.failure_streak = self.live.failure_streak.saturating_add(1);
      let jitter = completion.retry_jitter.min(Duration::from_secs(1));
      let delay = retry_delay(self.live.failure_streak, self.config.interval, jitter);
      let retry_at = now.checked_add(delay).unwrap_or(now);
      self.live.retry_at = Some(retry_at);
      self.live.disabled_retry_overdue_lag = None;
      self.live_retry_reasons = running.reasons;
      self.live_retry_planned_due_at = Some(retry_at);
    }
    actions.push(CoordinatorAction::PublishCompletion(
      self.completed_event(RefreshLane::Live, &completion),
    ));
    self.complete_live_waiters(
      waiters,
      completion.generation,
      completion.succeeded,
      completion.failure_code,
      completion.failure.as_deref(),
      &mut actions,
    );
    self.start_pending_live(now, &mut actions);
    actions
  }

  fn start_pending_token(&mut self, now: Instant, actions: &mut Vec<CoordinatorAction>) {
    if self.token_retry_source_refresh {
      return;
    }
    if let Some(request) = self.token_source_refresh_pending.take() {
      self.submit_source_refresh_request(request, actions);
      return;
    }
    if let Some(request) = self.token_pending_manual.take() {
      self.submit_token_request(now, request, actions);
      return;
    }
    if let Some(request) = self.token_pending_automatic.take() {
      if self.config.auto_scan_enabled {
        self.submit_token_request(now, request, actions);
      }
    }
  }

  fn prune_automatic_pending_work(&mut self) {
    if let Some(pending) = self.token_pending_manual.as_mut() {
      pending.reasons = RefreshReason::Manual.into();
      pending.planned_due_at = None;
    }
    self.token_pending_automatic = None;
    self.live_pending = ReasonSet::default();
    self.live_pending_due_at = None;
  }

  fn start_pending_live(&mut self, now: Instant, actions: &mut Vec<CoordinatorAction>) {
    let reasons = std::mem::take(&mut self.live_pending);
    let planned_due_at = self.live_pending_due_at.take();
    if !reasons.is_empty() {
      self.submit_live_request(
        now,
        LiveRequest {
          reasons,
          waiter: None,
          planned_due_at,
        },
        actions,
      );
    }
  }

  fn prepare_token_intake(
    &self,
    request: &mut TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) -> bool {
    request.bind_source_if_needed(self.source_generation, self.config.codex_home.clone());
    let had_waiters = !request.waiter_ids.is_empty();
    if !had_waiters {
      return true;
    }

    if !request.reasons.contains(RefreshReason::Manual) {
      self.reject_token_waiters(
        request.drain_waiters(),
        RefreshRejectionCode::InvalidRequest,
        Some("token waiters require a manual refresh request"),
        actions,
      );
      return false;
    }

    let incoming = request.drain_waiters();
    let mut accepted = Vec::with_capacity(incoming.len());
    let mut rejected = Vec::with_capacity(incoming.len());
    let mut owned_count = self.token_waiter_count();
    for waiter in incoming {
      if accepted.contains(&waiter) || self.token_waiter_is_owned(waiter) {
        continue;
      }
      if owned_count >= REFRESH_WAITER_CAPACITY {
        rejected.push(waiter);
      } else {
        accepted.push(waiter);
        owned_count += 1;
      }
    }
    for waiter in accepted {
      request
        .try_add_waiter(waiter)
        .expect("normalized token waiter input stays within the fixed capacity");
    }
    if !rejected.is_empty() {
      actions.push(CoordinatorAction::ResolveTokenWaiters {
        waiter_ids: rejected,
        outcome: rejected_outcome(RefreshRejectionCode::Busy, None),
      });
    }
    !request.waiter_ids.is_empty()
  }

  fn token_waiter_count(&self) -> usize {
    self
      .token_running
      .as_ref()
      .map_or(0, |request| request.request.waiter_ids.len())
      .saturating_add(
        self
          .token_pending_manual
          .as_ref()
          .map_or(0, |request| request.waiter_ids.len()),
      )
      .saturating_add(
        self
          .token_pending_automatic
          .as_ref()
          .map_or(0, |request| request.waiter_ids.len()),
      )
      .saturating_add(
        self
          .token_source_refresh_pending
          .as_ref()
          .map_or(0, |request| request.waiter_ids.len()),
      )
      .saturating_add(
        self
          .token_retry_request
          .as_ref()
          .map_or(0, |request| request.waiter_ids.len()),
      )
  }

  fn token_waiter_is_owned(&self, waiter: TokenWaiterId) -> bool {
    self
      .token_running
      .as_ref()
      .is_some_and(|request| request.request.waiter_ids.contains(&waiter))
      || self
        .token_pending_manual
        .as_ref()
        .is_some_and(|request| request.waiter_ids.contains(&waiter))
      || self
        .token_pending_automatic
        .as_ref()
        .is_some_and(|request| request.waiter_ids.contains(&waiter))
      || self
        .token_source_refresh_pending
        .as_ref()
        .is_some_and(|request| request.waiter_ids.contains(&waiter))
      || self
        .token_retry_request
        .as_ref()
        .is_some_and(|request| request.waiter_ids.contains(&waiter))
  }

  fn reject_token_waiters(
    &self,
    waiter_ids: Vec<TokenWaiterId>,
    code: RefreshRejectionCode,
    detail: Option<&str>,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if !waiter_ids.is_empty() {
      actions.push(CoordinatorAction::ResolveTokenWaiters {
        waiter_ids,
        outcome: rejected_outcome(code, detail),
      });
    }
  }

  fn complete_token_waiters(
    &self,
    waiter_ids: Vec<TokenWaiterId>,
    generation: u64,
    succeeded: bool,
    failure_code: Option<RefreshFailureCode>,
    detail: Option<&str>,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if !waiter_ids.is_empty() {
      actions.push(CoordinatorAction::ResolveTokenWaiters {
        waiter_ids,
        outcome: completed_outcome(generation, succeeded, failure_code, detail),
      });
    }
  }

  fn complete_live_waiters(
    &self,
    waiter_ids: Vec<LiveWaiterId>,
    generation: u64,
    succeeded: bool,
    failure_code: Option<RefreshFailureCode>,
    detail: Option<&str>,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if !waiter_ids.is_empty() {
      actions.push(CoordinatorAction::ResolveLiveWaiters {
        waiter_ids,
        outcome: completed_outcome(generation, succeeded, failure_code, detail),
      });
    }
  }

  fn retarget_automatic_reasons(
    &self,
    target: &mut TokenRequest,
    mut displaced: TokenRequest,
    rejection: RefreshRejectionCode,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    self.reject_token_waiters(
      displaced.drain_waiters(),
      rejection,
      Some("refresh source changed"),
      actions,
    );
    displaced.reasons.remove(RefreshReason::Manual);
    if displaced.reasons.is_empty() {
      return;
    }
    target.reasons.merge(displaced.reasons);
    target.kind = target.kind.max(displaced.kind);
    target.planned_due_at = earliest_planned_due(target.planned_due_at, displaced.planned_due_at);
  }

  fn retain_automatic_request(
    &mut self,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    request.reasons.remove(RefreshReason::Manual);
    request.waiter_ids.clear();
    if request.reasons.is_empty() {
      return;
    }
    if let Some(mut automatic) = self.token_pending_automatic.take() {
      if automatic.same_source_identity(&request) {
        automatic
          .try_merge(request)
          .expect("same source identity was checked before retained merge");
        self.token_pending_automatic = Some(automatic);
      } else {
        self.reject_token_waiters(
          automatic.drain_waiters(),
          RefreshRejectionCode::Superseded,
          Some("refresh request was superseded"),
          actions,
        );
        self.token_pending_automatic = Some(request);
      }
    } else {
      self.token_pending_automatic = Some(request);
    }
  }

  fn invalidation(&self, commit: CommitMarker) -> DisplayInvalidation {
    DisplayInvalidation {
      usage_revision: self.usage_revision,
      quota_revision: self.quota_revision,
      settings_revision: self.settings_revision,
      source_generation: self.source_generation,
      commit,
    }
  }

  fn completed_event(
    &mut self,
    lane: RefreshLane,
    completion: &ExecutionCompletion,
  ) -> RefreshCompletedEvent {
    if completion.succeeded {
      self.refresh_revision = self.refresh_revision.saturating_add(1);
    }
    RefreshCompletedEvent {
      refresh_revision: self.refresh_revision,
      lane,
      generation: completion.generation,
      usage_revision: self.usage_revision,
      quota_revision: self.quota_revision,
      source_generation: self.source_generation,
      succeeded: completion.succeeded,
      failure: completion.failure.clone(),
      completed_at: completion.completed_at.clone(),
    }
  }

  pub(crate) fn token_next_deadline(&self) -> Instant {
    self.token.next_deadline
  }

  pub(crate) fn live_next_deadline(&self) -> Instant {
    self.live.next_deadline
  }

  pub(crate) fn token_retry_at(&self) -> Option<Instant> {
    self.token.retry_at
  }

  pub(crate) fn live_retry_at(&self) -> Option<Instant> {
    self.live.retry_at
  }

  pub(crate) fn source_generation(&self) -> u64 {
    self.source_generation
  }

  pub(crate) fn usage_revision(&self) -> u64 {
    self.usage_revision
  }

  pub(crate) fn snapshot(&self) -> CoordinatorSnapshot {
    let mut token_pending_reasons = ReasonSet::default();
    for request in [
      self.token_pending_manual.as_ref(),
      self.token_pending_automatic.as_ref(),
      self.token_source_refresh_pending.as_ref(),
      self.token_retry_request.as_ref(),
    ]
    .into_iter()
    .flatten()
    {
      token_pending_reasons.merge(request.reasons);
    }
    let mut live_pending_reasons = self.live_pending;
    live_pending_reasons.merge(self.live_retry_reasons);

    CoordinatorSnapshot {
      token: LaneScheduleSnapshot {
        running_generation: self.token.running_generation,
        next_normal_deadline: self.token.next_deadline,
        retry_deadline: self.token.retry_at,
        failure_streak: self.token.failure_streak,
        pending: !token_pending_reasons.is_empty(),
        pending_reasons: token_pending_reasons,
        missed_deadline_count: self.token.missed_deadline_count,
        coalesced_trigger_count: self.token.coalesced_trigger_count,
      },
      live: LaneScheduleSnapshot {
        running_generation: self.live.running_generation,
        next_normal_deadline: self.live.next_deadline,
        retry_deadline: self.live.retry_at,
        failure_streak: self.live.failure_streak,
        pending: !live_pending_reasons.is_empty(),
        pending_reasons: live_pending_reasons,
        missed_deadline_count: self.live.missed_deadline_count,
        coalesced_trigger_count: self.live.coalesced_trigger_count,
      },
      source_generation: self.source_generation,
      interval: self.config.interval,
      auto_scan_enabled: self.config.auto_scan_enabled,
    }
  }

  pub(crate) fn next_wait(&self, now: Instant) -> Option<Duration> {
    let mut wait = None;
    if self.config.auto_scan_enabled {
      wait = Some(if self.token.immediate_due_at.is_some() {
        Duration::ZERO
      } else {
        self.token.next_deadline.saturating_duration_since(now)
      });
      wait = earliest_wait(
        wait,
        Some(if self.live.immediate_due_at.is_some() {
          Duration::ZERO
        } else {
          self.live.next_deadline.saturating_duration_since(now)
        }),
      );
    }

    let token_retry_is_eligible = self.config.auto_scan_enabled
      || self.token_retry_source_refresh
      || self
        .token_retry_request
        .as_ref()
        .is_some_and(|request| request.reasons.contains(RefreshReason::Manual));
    if token_retry_is_eligible {
      wait = earliest_wait(
        wait,
        self
          .token
          .retry_at
          .map(|deadline| deadline.saturating_duration_since(now)),
      );
    }

    let live_retry_is_eligible =
      self.config.auto_scan_enabled || self.live_retry_reasons.contains(RefreshReason::Manual);
    if live_retry_is_eligible {
      wait = earliest_wait(
        wait,
        self
          .live
          .retry_at
          .map(|deadline| deadline.saturating_duration_since(now)),
      );
    }
    wait
  }
}

fn merge_token_request(
  target: &mut Option<TokenRequest>,
  request: TokenRequest,
) -> Result<(), TokenRequest> {
  if let Some(target) = target {
    target.try_merge(request)
  } else {
    *target = Some(request);
    Ok(())
  }
}

fn merge_live_request(target: &mut Option<LiveRequest>, request: LiveRequest) {
  if let Some(target) = target {
    target.reasons.merge(request.reasons);
    target.planned_due_at = earliest_planned_due(target.planned_due_at, request.planned_due_at);
    if target.waiter.is_none() {
      target.waiter = request.waiter;
    }
  } else {
    *target = Some(request);
  }
}

fn earliest_planned_due(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
  match (left, right) {
    (Some(left), Some(right)) => Some(left.min(right)),
    (Some(value), None) | (None, Some(value)) => Some(value),
    (None, None) => None,
  }
}

fn earliest_wait(left: Option<Duration>, right: Option<Duration>) -> Option<Duration> {
  match (left, right) {
    (Some(left), Some(right)) => Some(left.min(right)),
    (Some(value), None) | (None, Some(value)) => Some(value),
    (None, None) => None,
  }
}

fn completed_outcome(
  generation: u64,
  succeeded: bool,
  failure_code: Option<RefreshFailureCode>,
  detail: Option<&str>,
) -> RefreshWaiterOutcome {
  RefreshWaiterOutcome::Completed {
    generation,
    succeeded,
    failure_code,
    detail: detail.map(RefreshDetail::new),
  }
}

fn rejected_outcome(code: RefreshRejectionCode, detail: Option<&str>) -> RefreshWaiterOutcome {
  RefreshWaiterOutcome::Rejected {
    code,
    detail: detail.map(RefreshDetail::new),
  }
}

fn push_unique_waiter(waiters: &mut Vec<LiveWaiterId>, waiter: LiveWaiterId) {
  if !waiters.contains(&waiter) {
    waiters.push(waiter);
  }
}

fn normalize_completion(mut completion: ExecutionCompletion) -> ExecutionCompletion {
  if completion.succeeded && completion.commit.is_none() {
    completion.succeeded = false;
    completion.failure_code = Some(RefreshFailureCode::InvalidCompletion);
    completion.failure = Some("successful refresh completion missing commit marker".to_string());
  } else if !completion.succeeded {
    if completion.failure_code.is_none() {
      completion.failure_code = Some(RefreshFailureCode::ExecutionFailed);
    }
    if completion.failure.is_none() {
      completion.failure = Some("refresh failed without an error".to_string());
    }
  } else {
    completion.failure_code = None;
    completion.failure = None;
  }
  completion
}

fn retry_delay(failure_streak: u32, interval: Duration, jitter: Duration) -> Duration {
  const STEPS: [u64; 6] = [5, 15, 30, 60, 120, 300];
  let index = failure_streak.saturating_sub(1) as usize;
  Duration::from_secs(STEPS[index.min(STEPS.len() - 1)])
    .saturating_add(jitter)
    .min(interval)
    .min(Duration::from_secs(300))
}

fn advance_fixed_deadline(deadline: Instant, interval: Duration, now: Instant) -> (Instant, u64) {
  if deadline > now {
    return (deadline, 0);
  }

  let interval_nanos = interval.as_nanos();
  debug_assert!(interval_nanos > 0);
  let overdue_nanos = now.duration_since(deadline).as_nanos();
  let elapsed_intervals = overdue_nanos / interval_nanos + 1;
  let remainder_nanos = overdue_nanos % interval_nanos;
  let remaining = duration_from_nanos(interval_nanos - remainder_nanos);
  let next_deadline = saturating_instant_add(now, remaining);
  let missed = elapsed_intervals.saturating_sub(1).min(u64::MAX as u128) as u64;
  (next_deadline, missed)
}

fn duration_from_nanos(value: u128) -> Duration {
  Duration::new(
    (value / 1_000_000_000).min(u64::MAX as u128) as u64,
    (value % 1_000_000_000) as u32,
  )
}

fn saturating_instant_add(base: Instant, duration: Duration) -> Instant {
  if let Some(value) = base.checked_add(duration) {
    return value;
  }

  let mut accepted_nanos = 0_u128;
  let mut rejected_nanos = duration.as_nanos();
  let mut accepted = base;
  while accepted_nanos.saturating_add(1) < rejected_nanos {
    let candidate_nanos = accepted_nanos + (rejected_nanos - accepted_nanos) / 2;
    if let Some(candidate) = base.checked_add(duration_from_nanos(candidate_nanos)) {
      accepted_nanos = candidate_nanos;
      accepted = candidate;
    } else {
      rejected_nanos = candidate_nanos;
    }
  }
  accepted
}

fn effective_interval(base: Instant, requested: Duration) -> Duration {
  let effective = saturating_instant_add(base, requested).duration_since(base);
  if effective.is_zero() {
    Duration::from_nanos(1)
  } else {
    effective
  }
}

fn duration_remainder(value: Duration, modulus: Duration) -> Duration {
  let remainder_nanos = value.as_nanos() % modulus.as_nanos();
  Duration::new(
    (remainder_nanos / 1_000_000_000) as u64,
    (remainder_nanos % 1_000_000_000) as u32,
  )
}

fn initial_deadline(
  monotonic_now: Instant,
  wall_now: DateTime<Utc>,
  last_success: Option<DateTime<Utc>>,
  interval: Duration,
) -> Instant {
  let Some(age) =
    last_success.and_then(|value| wall_now.signed_duration_since(value).to_std().ok())
  else {
    return monotonic_now;
  };
  saturating_instant_add(monotonic_now, interval.saturating_sub(age))
}

#[cfg(test)]
mod tests {
  use super::*;
  use chrono::{DateTime, Duration as ChronoDuration, Utc};
  use std::time::{Duration, Instant};

  fn utc(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
      .expect("valid test timestamp")
      .with_timezone(&Utc)
  }

  fn test_config(interval: Duration, last_success_wall: Option<DateTime<Utc>>) -> RefreshConfig {
    RefreshConfig {
      auto_scan_enabled: true,
      interval,
      codex_home: None,
      token_last_success_wall: last_success_wall,
      live_last_success_wall: last_success_wall,
    }
  }

  fn token_starts(actions: &[CoordinatorAction]) -> usize {
    actions
      .iter()
      .filter(|value| matches!(value, CoordinatorAction::StartToken(_)))
      .count()
  }

  fn live_starts(actions: &[CoordinatorAction]) -> usize {
    actions
      .iter()
      .filter(|value| matches!(value, CoordinatorAction::StartLive(_)))
      .count()
  }

  #[test]
  fn persisted_success_maps_remaining_wall_time_to_monotonic_deadline() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let last_success = wall - ChronoDuration::seconds(120);
    let state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(last_success)),
      base,
      wall,
    );

    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(180));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(180));
  }

  #[test]
  fn missing_persisted_success_starts_one_immediate_catch_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(test_config(Duration::from_secs(300), None), base, wall);

    let first = state.handle(base, CoordinatorEvent::Timer);
    let duplicate = state.handle(base + Duration::from_secs(1), CoordinatorEvent::Timer);

    assert_eq!(token_starts(&first), 1);
    assert_eq!(live_starts(&first), 1);
    assert!(matches!(
      first.as_slice(),
      [
        CoordinatorAction::StartToken(token),
        CoordinatorAction::StartLive(live),
      ] if token.request.kind == TokenScanKind::Incremental
        && token.request.reasons.contains(RefreshReason::Startup)
        && live.reasons.contains(RefreshReason::Startup)
    ));
    assert!(duplicate.is_empty());
  }

  #[test]
  fn invalid_persisted_success_starts_one_immediate_catch_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let malformed_success = crate::refresh::parse_persisted_success_wall(Some("not-a-timestamp"));
    let future_success = wall + ChronoDuration::seconds(1);

    assert_eq!(malformed_success, None);
    for last_success in [malformed_success, Some(future_success)] {
      let mut state = CoordinatorState::new(
        test_config(Duration::from_secs(300), last_success),
        base,
        wall,
      );

      let first = state.handle(base, CoordinatorEvent::Timer);
      let duplicate = state.handle(base, CoordinatorEvent::Timer);

      assert_eq!(token_starts(&first), 1);
      assert_eq!(live_starts(&first), 1);
      assert!(duplicate.is_empty());
    }
  }

  #[test]
  fn overdue_persisted_success_starts_one_immediate_catch_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let overdue_success = wall - ChronoDuration::seconds(301);
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(overdue_success)),
      base,
      wall,
    );

    let first = state.handle(base, CoordinatorEvent::Timer);
    let duplicate = state.handle(base + Duration::from_secs(1), CoordinatorEvent::Timer);

    assert_eq!(token_starts(&first), 1);
    assert_eq!(live_starts(&first), 1);
    assert!(duplicate.is_empty());
  }

  #[test]
  fn due_lanes_start_together_and_advance_from_planned_deadlines() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let config = test_config(Duration::from_secs(300), Some(wall));
    let mut state = CoordinatorState::new(config, base, wall);

    let actions = state.handle(base + Duration::from_secs(300), CoordinatorEvent::Timer);

    assert!(actions
      .iter()
      .any(|value| matches!(value, CoordinatorAction::StartToken(_))));
    assert!(actions
      .iter()
      .any(|value| matches!(value, CoordinatorAction::StartLive(_))));
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(600));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(600));
  }

  #[test]
  fn token_running_does_not_block_due_live_lane() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let config = RefreshConfig {
      auto_scan_enabled: true,
      interval: Duration::from_secs(300),
      codex_home: None,
      token_last_success_wall: None,
      live_last_success_wall: Some(wall),
    };
    let mut state = CoordinatorState::new(config, base, wall);

    let startup = state.handle(base, CoordinatorEvent::Timer);
    let live_due = state.handle(base + Duration::from_secs(300), CoordinatorEvent::Timer);

    assert_eq!(token_starts(&startup), 1);
    assert_eq!(live_starts(&startup), 0);
    assert_eq!(token_starts(&live_due), 0);
    assert_eq!(live_starts(&live_due), 1);
    assert!(matches!(
      live_due.as_slice(),
      [CoordinatorAction::StartLive(request)]
        if request.reasons.contains(RefreshReason::Scheduled)
    ));
  }

  #[test]
  fn missed_intervals_coalesce_into_one_catch_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let config = test_config(Duration::from_secs(300), Some(wall));
    let mut state = CoordinatorState::new(config, base, wall);

    let actions = state.handle(base + Duration::from_secs(950), CoordinatorEvent::Wake);

    assert_eq!(token_starts(&actions), 1);
    assert_eq!(live_starts(&actions), 1);
    assert!(matches!(
      actions.as_slice(),
      [
        CoordinatorAction::StartToken(token),
        CoordinatorAction::StartLive(live),
      ] if token.request.reasons.contains(RefreshReason::Wake)
        && live.reasons.contains(RefreshReason::Wake)
    ));
    assert_eq!(
      state.token_next_deadline(),
      base + Duration::from_secs(1_200)
    );
    assert_eq!(
      state.live_next_deadline(),
      base + Duration::from_secs(1_200)
    );
  }

  #[test]
  fn shorter_interval_recalculates_deadline_immediately() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let shorter = test_config(Duration::from_secs(30), Some(wall));

    let actions = state.handle(
      base + Duration::from_secs(60),
      CoordinatorEvent::SettingsChanged(shorter),
    );

    assert_eq!(token_starts(&actions), 1);
    assert_eq!(live_starts(&actions), 1);
    assert!(matches!(
      actions.as_slice(),
      [
        CoordinatorAction::StartToken(token),
        CoordinatorAction::StartLive(live),
      ] if token.request.reasons.contains(RefreshReason::SettingsChanged)
        && live.reasons.contains(RefreshReason::SettingsChanged)
    ));
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(90));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(90));
  }

  #[test]
  fn interval_shrink_preserves_original_planned_due() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );

    let actions = state.handle(
      base + Duration::from_secs(60),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(30), Some(wall))),
    );

    let token = actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("shorter interval starts token catch-up");
    let live = actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("shorter interval starts live catch-up");
    assert_eq!(
      token.request.planned_due_at,
      Some(base + Duration::from_secs(30))
    );
    assert_eq!(live.planned_due_at, Some(base + Duration::from_secs(30)));
  }

  #[test]
  fn interval_shrink_counts_only_skipped_new_deadlines() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );

    state.handle(
      base + Duration::from_secs(60),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(30), Some(wall))),
    );

    assert_eq!(state.snapshot().token.missed_deadline_count, 1);
    assert_eq!(state.snapshot().live.missed_deadline_count, 1);
  }

  #[test]
  fn shorter_interval_preserves_unaligned_fixed_deadline() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );

    let actions = state.handle(
      base + Duration::from_secs(45),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(30), Some(wall))),
    );

    assert_eq!(token_starts(&actions), 1);
    assert_eq!(live_starts(&actions), 1);
    assert_eq!(
      state.token_next_deadline().duration_since(base),
      Duration::from_secs(60)
    );
    assert_eq!(
      state.live_next_deadline().duration_since(base),
      Duration::from_secs(60)
    );
  }

  #[test]
  fn shorter_interval_recalculates_when_prior_anchor_predates_monotonic_epoch() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let old_interval = Duration::MAX;
    let old_next_deadline = base + Duration::from_secs(60);
    assert!(old_next_deadline.checked_sub(old_interval).is_none());
    let mut state =
      CoordinatorState::new(test_config(Duration::from_secs(60), Some(wall)), base, wall);
    state.config.interval = old_interval;
    state.token = LaneState::new(old_next_deadline, base);
    state.live = LaneState::new(old_next_deadline, base);

    let actions = state.handle(
      base + Duration::from_secs(30),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(10), None)),
    );

    assert_eq!(token_starts(&actions), 1);
    assert_eq!(live_starts(&actions), 1);
    assert!(matches!(
      actions.as_slice(),
      [
        CoordinatorAction::StartToken(token),
        CoordinatorAction::StartLive(live),
      ] if token.request.reasons.contains(RefreshReason::SettingsChanged)
        && live.reasons.contains(RefreshReason::SettingsChanged)
    ));
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(40));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(40));
  }

  #[test]
  fn shorten_then_lengthen_while_disabled_does_not_refresh_on_reenable() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut initial = test_config(Duration::from_secs(300), Some(wall));
    initial.auto_scan_enabled = false;
    let mut state = CoordinatorState::new(initial, base, wall);
    let mut shorter = test_config(Duration::from_secs(30), Some(wall));
    shorter.auto_scan_enabled = false;
    let mut longer = test_config(Duration::from_secs(300), Some(wall));
    longer.auto_scan_enabled = false;

    let shortened = state.handle(
      base + Duration::from_secs(45),
      CoordinatorEvent::SettingsChanged(shorter),
    );
    let lengthened = state.handle(
      base + Duration::from_secs(50),
      CoordinatorEvent::SettingsChanged(longer),
    );
    let reenabled = state.handle(
      base + Duration::from_secs(50),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(300), Some(wall))),
    );

    assert!(shortened.is_empty());
    assert!(lengthened.is_empty());
    assert_eq!(
      state.token_next_deadline().duration_since(base),
      Duration::from_secs(330)
    );
    assert_eq!(
      state.live_next_deadline().duration_since(base),
      Duration::from_secs(330)
    );
    assert_eq!(token_starts(&reenabled), 0);
    assert_eq!(live_starts(&reenabled), 0);
  }

  #[test]
  fn same_interval_reenable_preserves_due_disabled_refresh() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut initial = test_config(Duration::from_secs(300), Some(wall));
    initial.auto_scan_enabled = false;
    let mut state = CoordinatorState::new(initial, base, wall);
    let mut shorter = test_config(Duration::from_secs(30), Some(wall));
    shorter.auto_scan_enabled = false;

    let shortened = state.handle(
      base + Duration::from_secs(45),
      CoordinatorEvent::SettingsChanged(shorter),
    );
    let reenabled = state.handle(
      base + Duration::from_secs(50),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(30), Some(wall))),
    );

    assert!(shortened.is_empty());
    assert_eq!(token_starts(&reenabled), 1);
    assert_eq!(live_starts(&reenabled), 1);
    assert_eq!(
      state.token_next_deadline().duration_since(base),
      Duration::from_secs(60)
    );
    assert_eq!(
      state.live_next_deadline().duration_since(base),
      Duration::from_secs(60)
    );
  }

  #[test]
  fn backward_wall_clock_does_not_move_runtime_deadline() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let future_wall_success = wall + ChronoDuration::hours(1);

    let early = state.handle(
      base + Duration::from_secs(299),
      CoordinatorEvent::SettingsChanged(test_config(
        Duration::from_secs(300),
        Some(future_wall_success),
      )),
    );
    let due = state.handle(base + Duration::from_secs(300), CoordinatorEvent::Timer);

    assert!(early.is_empty());
    assert_eq!(token_starts(&due), 1);
    assert_eq!(live_starts(&due), 1);
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(600));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(600));
  }

  fn execution_success(
    generation: u64,
    source_generation: u64,
    sequence: u64,
    committed_at: Instant,
  ) -> ExecutionCompletion {
    ExecutionCompletion {
      generation,
      source_generation,
      succeeded: true,
      failure_code: None,
      failure: None,
      completed_at: "2026-07-10T10:00:00Z".to_string(),
      commit: Some(CommitMarker {
        sequence,
        committed_at,
      }),
      retry_jitter: Duration::ZERO,
    }
  }

  fn execution_failure(
    generation: u64,
    source_generation: u64,
    retry_jitter: Duration,
  ) -> ExecutionCompletion {
    ExecutionCompletion {
      generation,
      source_generation,
      succeeded: false,
      failure_code: Some(RefreshFailureCode::ExecutionFailed),
      failure: Some("test failure".to_string()),
      completed_at: "2026-07-10T10:00:00Z".to_string(),
      commit: None,
      retry_jitter,
    }
  }

  fn start_token_generation(state: &mut CoordinatorState, now: Instant) -> TokenExecutionRequest {
    state
      .handle(
        now,
        CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("token generation starts")
  }

  fn start_live_generation(state: &mut CoordinatorState, now: Instant) -> LiveExecutionRequest {
    state
      .handle(now, CoordinatorEvent::RequestLive(LiveRequest::scheduled()))
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("live generation starts")
  }

  fn manual_token_request(waiter: TokenWaiterId, codex_home: Option<&str>) -> TokenRequest {
    TokenRequest::manual_full_with_waiter(codex_home.map(str::to_string), waiter)
  }

  fn token_waiter_outcome<'a>(
    actions: &'a [CoordinatorAction],
    waiter: TokenWaiterId,
  ) -> Option<&'a RefreshWaiterOutcome> {
    actions.iter().find_map(|action| match action {
      CoordinatorAction::ResolveTokenWaiters {
        waiter_ids,
        outcome,
      } if waiter_ids.contains(&waiter) => Some(outcome),
      _ => None,
    })
  }

  fn live_waiter_outcome<'a>(
    actions: &'a [CoordinatorAction],
    waiter: LiveWaiterId,
  ) -> Option<&'a RefreshWaiterOutcome> {
    actions.iter().find_map(|action| match action {
      CoordinatorAction::ResolveLiveWaiters {
        waiter_ids,
        outcome,
      } if waiter_ids.contains(&waiter) => Some(outcome),
      _ => None,
    })
  }

  #[test]
  fn triggers_during_run_create_one_follow_up_generation() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let first = start_token_generation(&mut state, base);

    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
    );
    let actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );

    let starts = actions
      .iter()
      .filter_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .collect::<Vec<_>>();
    assert_eq!(starts.len(), 1);
    assert_eq!(starts[0].request.kind, TokenScanKind::Full);
  }

  #[test]
  fn multiple_triggers_merge_reason_bits() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let first = start_live_generation(&mut state, base);

    for reason in [
      RefreshReason::Scheduled,
      RefreshReason::Wake,
      RefreshReason::SettingsChanged,
    ] {
      state.handle(
        base + Duration::from_secs(1),
        CoordinatorEvent::RequestLive(LiveRequest::for_reason(reason)),
      );
    }
    let actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::LiveFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );

    let starts = actions
      .iter()
      .filter_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .collect::<Vec<_>>();
    assert_eq!(starts.len(), 1);
    assert!(starts[0].reasons.contains(RefreshReason::Scheduled));
    assert!(starts[0].reasons.contains(RefreshReason::Wake));
    assert!(starts[0].reasons.contains(RefreshReason::SettingsChanged));
  }

  #[test]
  fn manual_live_waiter_joins_running_generation() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let first = start_live_generation(&mut state, base);
    let waiter_id = LiveWaiterId(41);

    let joined = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestLive(LiveRequest::manual(waiter_id)),
    );
    assert!(joined
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartLive(_))));

    let actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::LiveFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );

    assert!(actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartLive(_))));
    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::ResolveLiveWaiters {
        waiter_ids,
        outcome: RefreshWaiterOutcome::Completed {
          generation,
          succeeded: true,
          failure_code: None,
          detail: None,
        },
      } if waiter_ids == &[waiter_id] && *generation == first.generation
    )));
  }

  #[test]
  fn failed_lanes_back_off_independently() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first_token = start_token_generation(&mut state, base);
    let first_live = start_live_generation(&mut state, base);

    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_failure(
        first_token.generation,
        first_token.source_generation,
        Duration::ZERO,
      )),
    );
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::LiveFinished(execution_failure(
        first_live.generation,
        first_live.source_generation,
        Duration::ZERO,
      )),
    );

    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(6)));
    assert_eq!(state.live_retry_at(), Some(base + Duration::from_secs(7)));
    assert_eq!(state.token_next_deadline(), base + interval);
    assert_eq!(state.live_next_deadline(), base + interval);

    let token_retry = state.handle(base + Duration::from_secs(6), CoordinatorEvent::Timer);
    assert_eq!(token_starts(&token_retry), 1);
    assert_eq!(live_starts(&token_retry), 0);
    let second_token = token_retry
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("token retry starts");
    state.handle(
      base + Duration::from_secs(6),
      CoordinatorEvent::TokenFinished(execution_failure(
        second_token.generation,
        second_token.source_generation,
        Duration::ZERO,
      )),
    );

    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(21)));
    assert_eq!(state.live_retry_at(), Some(base + Duration::from_secs(7)));
    assert_eq!(
      retry_delay(6, Duration::from_secs(600), Duration::ZERO),
      Duration::from_secs(300)
    );
    assert_eq!(
      retry_delay(1, Duration::from_secs(3), Duration::ZERO),
      Duration::from_secs(3)
    );

    let mut jitter_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let jittered = start_token_generation(&mut jitter_state, base);
    jitter_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        jittered.generation,
        jittered.source_generation,
        Duration::from_secs(2),
      )),
    );
    assert_eq!(
      jitter_state.token_retry_at(),
      Some(base + Duration::from_secs(6))
    );
  }

  #[test]
  fn source_change_rejects_old_completion() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/new-home".to_string());

    let settings_actions = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    assert!(settings_actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartToken(_))));

    let actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );

    assert_eq!(state.source_generation(), first.source_generation + 1);
    assert_eq!(state.usage_revision(), 0);
    assert!(actions.iter().all(|action| !matches!(
      action,
      CoordinatorAction::PublishCompletion(_) | CoordinatorAction::PublishInvalidation(_)
    )));
    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::StartToken(request)
        if request.source_generation == first.source_generation + 1
          && request.request.kind == TokenScanKind::Full
          && request.request.codex_home.as_deref() == Some("/normalized/new-home")
    )));
  }

  #[test]
  fn source_change_discards_prepared_token_before_commit() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/new-home".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );

    let actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenPrepared {
        generation: first.generation,
        source_generation: first.source_generation,
      },
    );

    assert_eq!(state.usage_revision(), 0);
    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::DiscardToken {
        generation,
        source_generation,
      } if *generation == first.generation && *source_generation == first.source_generation
    )));
    assert!(actions.iter().all(|action| !matches!(
      action,
      CoordinatorAction::CommitToken { .. }
        | CoordinatorAction::PublishCompletion(_)
        | CoordinatorAction::PublishInvalidation(_)
    )));
    assert_eq!(
      actions
        .iter()
        .filter(|action| matches!(action, CoordinatorAction::StartToken(_)))
        .count(),
      1
    );
    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::StartToken(request)
        if request.source_generation == first.source_generation + 1
          && request.request.kind == TokenScanKind::Full
    )));
  }

  #[test]
  fn success_without_commit_marker_does_not_advance_refresh_revision() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let first = start_token_generation(&mut state, base);
    let completion = ExecutionCompletion {
      generation: first.generation,
      source_generation: first.source_generation,
      succeeded: true,
      failure_code: None,
      failure: None,
      completed_at: "2026-07-10T10:00:00Z".to_string(),
      commit: None,
      retry_jitter: Duration::ZERO,
    };

    let actions = state.handle(base, CoordinatorEvent::TokenFinished(completion));

    assert_eq!(state.usage_revision(), 0);
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(5)));
    assert!(actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::PublishInvalidation(_))));
    let published = actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::PublishCompletion(event) => Some(event),
        _ => None,
      })
      .expect("invalid success publishes a failed attempt");
    assert!(!published.succeeded);
    assert_eq!(
      published.failure.as_deref(),
      Some("successful refresh completion missing commit marker")
    );
    assert_eq!(published.refresh_revision, 0);
    assert_eq!(published.usage_revision, 0);
    assert_eq!(published.quota_revision, 0);
    assert_eq!(published.generation, first.generation);

    let mut failure_state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let failed = start_token_generation(&mut failure_state, base);
    let failed_actions = failure_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        failed.generation,
        failed.source_generation,
        Duration::ZERO,
      )),
    );
    assert!(failed_actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::PublishCompletion(event)
        if event.refresh_revision == 0
          && event.usage_revision == 0
          && event.quota_revision == 0
          && event.generation == failed.generation
          && !event.succeeded
    )));
  }

  #[test]
  fn stale_live_completion_resolves_waiters_without_publishing() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_live_generation(&mut state, base);
    let waiter_id = LiveWaiterId(73);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestLive(LiveRequest::manual(waiter_id)),
    );
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/new-home".to_string());
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::SettingsChanged(changed),
    );

    let actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::LiveFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );

    assert!(actions.iter().all(|action| !matches!(
      action,
      CoordinatorAction::PublishCompletion(_) | CoordinatorAction::PublishInvalidation(_)
    )));
    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::ResolveLiveWaiters {
        waiter_ids,
        outcome: RefreshWaiterOutcome::Completed {
          generation,
          succeeded: false,
          failure_code: Some(RefreshFailureCode::SourceChanged),
          detail,
        },
      } if waiter_ids == &[waiter_id]
        && *generation == first.generation
        && detail.as_ref().is_some_and(|value| value.as_str() == "refresh source changed")
    )));
    assert_eq!(
      actions
        .iter()
        .filter(|action| matches!(action, CoordinatorAction::StartLive(_)))
        .count(),
      1
    );
  }

  #[test]
  fn manual_full_request_supersedes_pending_retry_source() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut config = test_config(Duration::from_secs(300), Some(wall));
    config.codex_home = Some("/normalized/configured-home".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let first = start_token_generation(&mut state, base);
    state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        first.generation,
        first.source_generation,
        Duration::ZERO,
      )),
    );

    let actions = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
        "/normalized/manual-home".to_string(),
      ))),
    );

    assert!(actions.iter().any(|action| matches!(
      action,
      CoordinatorAction::StartToken(request)
        if request.request.kind == TokenScanKind::Full
          && request.request.reasons.contains(RefreshReason::Manual)
          && request.request.codex_home.as_deref() == Some("/normalized/manual-home")
    )));
  }

  #[test]
  fn disabling_auto_scan_cancels_queued_automatic_token_follow_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_token_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::SettingsChanged(disabled),
    );

    let actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );

    assert!(actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartToken(_))));
  }

  #[test]
  fn disabling_auto_scan_cancels_queued_automatic_live_follow_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_live_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestLive(LiveRequest::scheduled()),
    );
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::SettingsChanged(disabled),
    );

    let actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::LiveFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );

    assert!(actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartLive(_))));
  }

  #[test]
  fn source_refresh_precedes_manual_request_for_another_home() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let first = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/new-home".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
        "/normalized/manual-home".to_string(),
      ))),
    );

    let actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        first.generation,
        first.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );

    let starts = actions
      .iter()
      .filter_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .collect::<Vec<_>>();
    assert_eq!(starts.len(), 1);
    assert_eq!(starts[0].request.kind, TokenScanKind::Full);
    assert_eq!(
      starts[0].request.codex_home.as_deref(),
      Some("/normalized/new-home")
    );
  }

  #[test]
  fn protected_source_refresh_failure_retries_while_auto_scan_disabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let old_source = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.auto_scan_enabled = false;
    changed.codex_home = Some("/normalized/configured-home".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        old_source.generation,
        old_source.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let protected = replacement_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("new source Full refresh starts");
    assert_eq!(protected.request.kind, TokenScanKind::Full);
    assert_eq!(
      protected.request.codex_home.as_deref(),
      Some("/normalized/configured-home")
    );

    let failure_actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_failure(
        protected.generation,
        protected.source_generation,
        Duration::ZERO,
      )),
    );
    assert!(failure_actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartToken(_))));
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(8)));

    let early = state.handle(base + Duration::from_secs(7), CoordinatorEvent::Timer);
    let retry_actions = state.handle(base + Duration::from_secs(8), CoordinatorEvent::Timer);
    assert_eq!(token_starts(&early), 0);
    assert!(matches!(
      retry_actions.as_slice(),
      [CoordinatorAction::StartToken(request)]
        if request.request.kind == TokenScanKind::Full
          && request.request.codex_home.as_deref()
            == Some("/normalized/configured-home")
    ));
  }

  #[test]
  fn protected_source_retry_is_not_retargeted_by_different_home_manual_request() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let old_source = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.auto_scan_enabled = false;
    changed.codex_home = Some("/normalized/configured-home".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        old_source.generation,
        old_source.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let protected = replacement_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("new source Full refresh starts");
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_failure(
        protected.generation,
        protected.source_generation,
        Duration::ZERO,
      )),
    );

    let manual_actions = state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
        "/normalized/manual-home".to_string(),
      ))),
    );
    assert!(manual_actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartToken(_))));

    let retry_actions = state.handle(base + Duration::from_secs(8), CoordinatorEvent::Timer);
    let retry = retry_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("protected retry starts first");
    assert_eq!(retry.request.kind, TokenScanKind::Full);
    assert_eq!(
      retry.request.codex_home.as_deref(),
      Some("/normalized/configured-home")
    );

    let success_actions = state.handle(
      base + Duration::from_secs(9),
      CoordinatorEvent::TokenFinished(execution_success(
        retry.generation,
        retry.source_generation,
        2,
        base + Duration::from_secs(9),
      )),
    );
    assert!(matches!(
      success_actions.last(),
      Some(CoordinatorAction::StartToken(request))
        if request.request.kind == TokenScanKind::Full
          && request.request.reasons.contains(RefreshReason::Manual)
          && request.request.codex_home.as_deref() == Some("/normalized/manual-home")
    ));
  }

  #[test]
  fn automatic_follow_up_during_protected_run_is_pruned_when_disabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let old_source = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/configured-home".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed.clone()),
    );
    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        old_source.generation,
        old_source.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let protected = replacement_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("configured-source Full refresh starts");
    assert_eq!(protected.request.kind, TokenScanKind::Full);
    assert_eq!(
      protected.request.codex_home.as_deref(),
      Some("/normalized/configured-home")
    );

    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );
    changed.auto_scan_enabled = false;
    state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::SettingsChanged(changed),
    );
    let completion_actions = state.handle(
      base + Duration::from_secs(5),
      CoordinatorEvent::TokenFinished(execution_success(
        protected.generation,
        protected.source_generation,
        2,
        base + Duration::from_secs(5),
      )),
    );

    assert!(completion_actions
      .iter()
      .all(|action| !matches!(action, CoordinatorAction::StartToken(_))));
  }

  #[test]
  fn later_automatic_trigger_does_not_retarget_pending_manual_home() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let old_source = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/configured-home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        old_source.generation,
        old_source.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let protected = replacement_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("configured-source Full refresh starts");

    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
        "/normalized/manual-home-c".to_string(),
      ))),
    );
    state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );

    let protected_success = state.handle(
      base + Duration::from_secs(5),
      CoordinatorEvent::TokenFinished(execution_success(
        protected.generation,
        protected.source_generation,
        2,
        base + Duration::from_secs(5),
      )),
    );
    let manual = protected_success
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual follow-up starts first");
    assert_eq!(manual.request.kind, TokenScanKind::Full);
    assert!(manual.request.reasons.contains(RefreshReason::Manual));
    assert_eq!(
      manual.request.codex_home.as_deref(),
      Some("/normalized/manual-home-c")
    );

    let manual_success = state.handle(
      base + Duration::from_secs(6),
      CoordinatorEvent::TokenFinished(execution_success(
        manual.generation,
        manual.source_generation,
        3,
        base + Duration::from_secs(6),
      )),
    );
    assert!(matches!(
      manual_success.last(),
      Some(CoordinatorAction::StartToken(request))
        if request.request.reasons.contains(RefreshReason::Scheduled)
          && !request.request.reasons.contains(RefreshReason::Manual)
          && request.request.codex_home.as_deref()
            == Some("/normalized/configured-home-b")
    ));
  }

  #[test]
  fn failed_manual_retry_survives_different_home_automatic_pending() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let old_source = start_token_generation(&mut state, base);
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/configured-home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );
    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        old_source.generation,
        old_source.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let protected = replacement_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("configured-source Full refresh starts");

    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
        "/normalized/manual-home-c".to_string(),
      ))),
    );
    state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );
    let protected_success = state.handle(
      base + Duration::from_secs(5),
      CoordinatorEvent::TokenFinished(execution_success(
        protected.generation,
        protected.source_generation,
        2,
        base + Duration::from_secs(5),
      )),
    );
    let manual = protected_success
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual follow-up starts first");

    let manual_failure = state.handle(
      base + Duration::from_secs(6),
      CoordinatorEvent::TokenFinished(execution_failure(
        manual.generation,
        manual.source_generation,
        Duration::ZERO,
      )),
    );
    assert_eq!(token_starts(&manual_failure), 0);
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(11)));

    let early = state.handle(base + Duration::from_secs(10), CoordinatorEvent::Timer);
    assert_eq!(token_starts(&early), 0);
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(11)));

    let retry_actions = state.handle(base + Duration::from_secs(11), CoordinatorEvent::Timer);
    let manual_retry = retry_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual Full retry starts at its deadline");
    assert_eq!(manual_retry.request.kind, TokenScanKind::Full);
    assert!(manual_retry.request.reasons.contains(RefreshReason::Manual));
    assert_eq!(
      manual_retry.request.codex_home.as_deref(),
      Some("/normalized/manual-home-c")
    );

    let manual_success = state.handle(
      base + Duration::from_secs(12),
      CoordinatorEvent::TokenFinished(execution_success(
        manual_retry.generation,
        manual_retry.source_generation,
        3,
        base + Duration::from_secs(12),
      )),
    );
    assert!(matches!(
      manual_success.last(),
      Some(CoordinatorAction::StartToken(request))
        if request.request.reasons.contains(RefreshReason::Scheduled)
          && !request.request.reasons.contains(RefreshReason::Manual)
          && request.request.codex_home.as_deref()
            == Some("/normalized/configured-home-b")
    ));
  }

  #[test]
  fn due_automatic_trigger_does_not_retarget_manual_retry() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(5);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/configured-home-b".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let manual = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(TokenRequest::manual_full(Some(
          "/normalized/manual-home-c".to_string(),
        ))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual Full refresh starts");

    let failure_actions = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_failure(
        manual.generation,
        manual.source_generation,
        Duration::ZERO,
      )),
    );
    assert_eq!(token_starts(&failure_actions), 0);
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(6)));

    let retry_actions = state.handle(base + Duration::from_secs(6), CoordinatorEvent::Timer);
    let manual_retry = retry_actions
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual Full retry starts at its deadline");
    assert_eq!(manual_retry.request.kind, TokenScanKind::Full);
    assert!(manual_retry.request.reasons.contains(RefreshReason::Manual));
    assert_eq!(
      manual_retry.request.codex_home.as_deref(),
      Some("/normalized/manual-home-c")
    );

    let manual_success = state.handle(
      base + Duration::from_secs(7),
      CoordinatorEvent::TokenFinished(execution_success(
        manual_retry.generation,
        manual_retry.source_generation,
        1,
        base + Duration::from_secs(7),
      )),
    );
    assert!(matches!(
      manual_success.last(),
      Some(CoordinatorAction::StartToken(request))
        if request.request.reasons.contains(RefreshReason::Scheduled)
          && !request.request.reasons.contains(RefreshReason::Manual)
          && request.request.codex_home.as_deref()
            == Some("/normalized/configured-home-b")
    ));
  }

  #[test]
  fn manual_token_waiter_binds_to_follow_up_generation() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let running = start_token_generation(&mut state, base);
    let waiter = TokenWaiterId(1);

    let queued = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(manual_token_request(waiter, None)),
    );
    assert!(queued.is_empty());

    let first_completion = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        running.generation,
        running.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    assert!(token_waiter_outcome(&first_completion, waiter).is_none());
    let follow_up = first_completion
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual waiter starts in one follow-up generation");
    assert_ne!(follow_up.generation, running.generation);
    assert_eq!(follow_up.request.waiter_ids(), &[waiter]);

    let follow_up_completion = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        follow_up.generation,
        follow_up.source_generation,
        2,
        base + Duration::from_secs(3),
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&follow_up_completion, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: true,
        failure_code: None,
        detail: None,
      }) if *generation == follow_up.generation
    ));
  }

  #[test]
  fn same_source_manual_waiters_coalesce() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut config = test_config(Duration::from_secs(300), Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let running = start_token_generation(&mut state, base);
    let first_waiter = TokenWaiterId(10);
    let second_waiter = TokenWaiterId(11);

    for waiter in [first_waiter, second_waiter, first_waiter] {
      assert!(state
        .handle(
          base + Duration::from_secs(1),
          CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-a"),)),
        )
        .is_empty());
    }

    let actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        running.generation,
        running.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    let follow_up = actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("coalesced manual request starts");
    assert_eq!(
      follow_up.request.waiter_ids(),
      &[first_waiter, second_waiter]
    );
    assert_eq!(
      follow_up.request.codex_home.as_deref(),
      Some("/normalized/home-a")
    );
  }

  #[test]
  fn different_source_manual_waiter_is_rejected_without_generation() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let running = start_token_generation(&mut state, base);
    let displaced = TokenWaiterId(20);
    let replacement = TokenWaiterId(21);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(manual_token_request(displaced, Some("/normalized/home-a"))),
    );

    let replacement_actions = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(manual_token_request(
        replacement,
        Some("/normalized/home-b"),
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&replacement_actions, displaced),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::Superseded,
        ..
      })
    ));

    let completion_actions = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        running.generation,
        running.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );
    let follow_up = completion_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("replacement manual source starts");
    assert_eq!(follow_up.request.waiter_ids(), &[replacement]);
    assert_eq!(
      follow_up.request.codex_home.as_deref(),
      Some("/normalized/home-b")
    );
  }

  #[test]
  fn failed_manual_waiter_resolves_once_before_retry() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let waiter = TokenWaiterId(30);
    let manual = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(waiter, None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token generation starts");

    let failure_actions = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_failure(
        manual.generation,
        manual.source_generation,
        Duration::ZERO,
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&failure_actions, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: false,
        failure_code: Some(RefreshFailureCode::ExecutionFailed),
        ..
      }) if *generation == manual.generation
    ));
    assert_eq!(
      failure_actions
        .iter()
        .filter(|action| matches!(action, CoordinatorAction::ResolveTokenWaiters { .. }))
        .count(),
      1
    );
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(6)));

    let retry_actions = state.handle(base + Duration::from_secs(6), CoordinatorEvent::Timer);
    let retry = retry_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("automatic retry starts");
    assert!(retry.request.waiter_ids.is_empty());
  }

  #[test]
  fn retry_never_reresolves_old_waiter() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let waiter = TokenWaiterId(31);
    let manual = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(waiter, None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token generation starts");
    let failed = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_failure(
        manual.generation,
        manual.source_generation,
        Duration::ZERO,
      )),
    );
    assert!(token_waiter_outcome(&failed, waiter).is_some());
    let retry = state
      .handle(base + Duration::from_secs(6), CoordinatorEvent::Timer)
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("retry starts");

    let succeeded = state.handle(
      base + Duration::from_secs(7),
      CoordinatorEvent::TokenFinished(execution_success(
        retry.generation,
        retry.source_generation,
        1,
        base + Duration::from_secs(7),
      )),
    );
    assert!(token_waiter_outcome(&succeeded, waiter).is_none());
  }

  #[test]
  fn source_change_does_not_orphan_token_waiter() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let waiter = TokenWaiterId(40);
    let running = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(waiter, None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token generation starts");
    let mut changed = test_config(interval, Some(wall));
    changed.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(changed),
    );

    let stale = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        running.generation,
        running.source_generation,
        1,
        base + Duration::from_secs(2),
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&stale, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: false,
        failure_code: Some(RefreshFailureCode::SourceChanged),
        ..
      }) if *generation == running.generation
    ));
  }

  #[test]
  fn protected_waiter_survives_or_rejects_second_source_change() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let running = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let protected_waiter = TokenWaiterId(41);
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(manual_token_request(
        protected_waiter,
        Some("/normalized/home-b"),
      )),
    );

    let mut home_c = test_config(interval, Some(wall));
    home_c.codex_home = Some("/normalized/home-c".to_string());
    let second_change = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::SettingsChanged(home_c),
    );
    assert!(matches!(
      token_waiter_outcome(&second_change, protected_waiter),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::SourceChanged,
        ..
      })
    ));

    let stale = state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::TokenFinished(execution_success(
        running.generation,
        running.source_generation,
        1,
        base + Duration::from_secs(4),
      )),
    );
    let replacement = stale
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("latest protected source starts");
    assert_eq!(
      replacement.request.codex_home.as_deref(),
      Some("/normalized/home-c")
    );
    assert!(replacement.request.waiter_ids.is_empty());
  }

  #[test]
  fn stale_running_and_protected_waiters_are_drained_or_carried() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let stale_waiter = TokenWaiterId(50);
    let stale_running = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(stale_waiter, None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("configured-source manual generation starts");

    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let displaced_protected = TokenWaiterId(51);
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(manual_token_request(
        displaced_protected,
        Some("/normalized/home-b"),
      )),
    );

    let mut home_a_again = test_config(interval, Some(wall));
    home_a_again.codex_home = Some("/normalized/home-a".to_string());
    let second_change = state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::SettingsChanged(home_a_again),
    );
    assert!(matches!(
      token_waiter_outcome(&second_change, displaced_protected),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::SourceChanged,
        ..
      })
    ));

    let current_protected = TokenWaiterId(52);
    state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::RequestToken(manual_token_request(
        current_protected,
        Some("/normalized/home-a"),
      )),
    );
    let discarded = state.handle(
      base + Duration::from_secs(5),
      CoordinatorEvent::TokenPrepared {
        generation: stale_running.generation,
        source_generation: stale_running.source_generation,
      },
    );
    assert!(matches!(
      token_waiter_outcome(&discarded, stale_waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: false,
        failure_code: Some(RefreshFailureCode::SourceChanged),
        ..
      }) if *generation == stale_running.generation
    ));
    let protected = discarded
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("current protected source starts after stale discard");
    assert_eq!(protected.request.waiter_ids(), &[current_protected]);
  }

  #[test]
  fn protected_replacement_absorbs_same_source_waiter_behind_stale_source_refresh() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let home_a = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let home_b = state
      .handle(
        base + Duration::from_secs(2),
        CoordinatorEvent::TokenFinished(execution_success(
          home_a.generation,
          home_a.source_generation,
          1,
          base + Duration::from_secs(2),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("home-b protected source refresh starts");

    let mut home_c = test_config(interval, Some(wall));
    home_c.codex_home = Some("/normalized/home-c".to_string());
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::SettingsChanged(home_c),
    );
    let waiter = TokenWaiterId(53);
    assert!(state
      .handle(
        base + Duration::from_secs(4),
        CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-c"),)),
      )
      .is_empty());

    let replacement = state
      .handle(
        base + Duration::from_secs(5),
        CoordinatorEvent::TokenFinished(execution_success(
          home_b.generation,
          home_b.source_generation,
          2,
          base + Duration::from_secs(5),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("home-c protected replacement starts");
    assert_eq!(replacement.request.waiter_ids(), &[waiter]);
  }

  #[test]
  fn protected_retry_absorbs_same_source_follow_up_waiter() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let home_a = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let home_b = state
      .handle(
        base + Duration::from_secs(2),
        CoordinatorEvent::TokenFinished(execution_success(
          home_a.generation,
          home_a.source_generation,
          1,
          base + Duration::from_secs(2),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("home-b protected source refresh starts");
    let waiter = TokenWaiterId(54);
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-b"))),
    );
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason(RefreshReason::Wake)),
    );

    let failed = state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::TokenFinished(execution_failure(
        home_b.generation,
        home_b.source_generation,
        Duration::ZERO,
      )),
    );
    assert!(token_waiter_outcome(&failed, waiter).is_none());
    let retry = state
      .handle(base + Duration::from_secs(9), CoordinatorEvent::Timer)
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("protected retry starts at its deadline");
    assert_eq!(retry.request.waiter_ids(), &[waiter]);
    assert!(retry.request.reasons.contains(RefreshReason::Wake));

    let completed = state.handle(
      base + Duration::from_secs(10),
      CoordinatorEvent::TokenFinished(execution_success(
        retry.generation,
        retry.source_generation,
        2,
        base + Duration::from_secs(10),
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&completed, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: true,
        ..
      }) if *generation == retry.generation
    ));
  }

  #[test]
  fn protected_retry_absorbs_same_source_automatic_follow_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let home_a = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let home_b = state
      .handle(
        base + Duration::from_secs(2),
        CoordinatorEvent::TokenFinished(execution_success(
          home_a.generation,
          home_a.source_generation,
          1,
          base + Duration::from_secs(2),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("home-b protected source refresh starts");
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason(RefreshReason::Wake)),
    );
    state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::TokenFinished(execution_failure(
        home_b.generation,
        home_b.source_generation,
        Duration::ZERO,
      )),
    );

    let retry = state
      .handle(base + Duration::from_secs(9), CoordinatorEvent::Timer)
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("protected retry starts at its deadline");
    assert!(retry.request.reasons.contains(RefreshReason::Wake));
    let completed = state.handle(
      base + Duration::from_secs(10),
      CoordinatorEvent::TokenFinished(execution_success(
        retry.generation,
        retry.source_generation,
        2,
        base + Duration::from_secs(10),
      )),
    );
    assert_eq!(token_starts(&completed), 0);
  }

  #[test]
  fn duplicate_completion_does_not_resolve_twice() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let waiter = TokenWaiterId(60);
    let running = state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(waiter, None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual generation starts");
    let completion = execution_success(
      running.generation,
      running.source_generation,
      1,
      base + Duration::from_secs(1),
    );

    let first = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(completion.clone()),
    );
    let duplicate = state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(completion),
    );
    assert!(token_waiter_outcome(&first, waiter).is_some());
    assert!(token_waiter_outcome(&duplicate, waiter).is_none());
    assert!(duplicate.is_empty());
  }

  #[test]
  fn waiter_cap_rejects_without_growth() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut token_state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let token_running = start_token_generation(&mut token_state, base);
    for raw in 0..REFRESH_WAITER_CAPACITY as u64 {
      assert!(token_state
        .handle(
          base + Duration::from_secs(1),
          CoordinatorEvent::RequestToken(manual_token_request(TokenWaiterId(raw), None)),
        )
        .is_empty());
    }
    let overflow = TokenWaiterId(REFRESH_WAITER_CAPACITY as u64);
    let rejected = token_state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(manual_token_request(overflow, None)),
    );
    assert!(matches!(
      token_waiter_outcome(&rejected, overflow),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::Busy,
        ..
      })
    ));
    let token_follow_up = token_state
      .handle(
        base + Duration::from_secs(3),
        CoordinatorEvent::TokenFinished(execution_success(
          token_running.generation,
          token_running.source_generation,
          1,
          base + Duration::from_secs(3),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("bounded token follow-up starts");
    assert_eq!(
      token_follow_up.request.waiter_ids.len(),
      REFRESH_WAITER_CAPACITY
    );

    let mut live_state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let live_running = start_live_generation(&mut live_state, base);
    for raw in 0..REFRESH_WAITER_CAPACITY as u64 {
      assert!(live_state
        .handle(
          base + Duration::from_secs(1),
          CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(raw))),
        )
        .is_empty());
    }
    let live_overflow = LiveWaiterId(REFRESH_WAITER_CAPACITY as u64);
    let live_rejected = live_state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestLive(LiveRequest::manual(live_overflow)),
    );
    assert!(matches!(
      live_waiter_outcome(&live_rejected, live_overflow),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::Busy,
        ..
      })
    ));
    let live_completed = live_state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::LiveFinished(execution_success(
        live_running.generation,
        live_running.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );
    let resolved_count = live_completed
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::ResolveLiveWaiters { waiter_ids, .. } => Some(waiter_ids.len()),
        _ => None,
      })
      .expect("live waiters resolve");
    assert_eq!(resolved_count, REFRESH_WAITER_CAPACITY);
  }

  #[test]
  fn oversized_token_waiter_input_is_bounded_before_coordinator_intake() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut request = TokenRequest::manual_full(None);

    for raw in 0..(REFRESH_WAITER_CAPACITY as u64 * 1_024) {
      let result = request.try_add_waiter(TokenWaiterId(raw));
      if raw < REFRESH_WAITER_CAPACITY as u64 {
        assert_eq!(result, Ok(()));
      } else {
        assert_eq!(result, Err(RefreshRejectionCode::Busy));
      }
    }
    assert_eq!(request.waiter_ids().len(), REFRESH_WAITER_CAPACITY);

    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let actions = state.handle(base, CoordinatorEvent::RequestToken(request));
    assert_eq!(actions.len(), 1);
    assert!(matches!(
      actions.as_slice(),
      [CoordinatorAction::StartToken(execution)]
        if execution.request.waiter_ids().len() == REFRESH_WAITER_CAPACITY
    ));
  }

  #[test]
  fn disabled_next_wait_returns_none_for_overdue_normal_deadline() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut disabled = test_config(Duration::from_secs(300), Some(wall));
    disabled.auto_scan_enabled = false;
    let state = CoordinatorState::new(disabled, base, wall);

    assert_eq!(state.next_wait(base + Duration::from_secs(301)), None);

    let immediate = CoordinatorState::new(test_config(Duration::from_secs(300), None), base, wall);
    assert_eq!(immediate.next_wait(base), Some(Duration::ZERO));
  }

  #[test]
  fn automatic_retry_is_ignored_while_disabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let automatic = start_token_generation(&mut state, base);
    state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        automatic.generation,
        automatic.source_generation,
        Duration::ZERO,
      )),
    );
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(disabled),
    );

    assert_eq!(state.next_wait(base + Duration::from_secs(5)), None);
    assert!(state
      .handle(base + Duration::from_secs(5), CoordinatorEvent::Timer)
      .is_empty());
    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(5)));
  }

  #[test]
  fn manual_retry_controls_next_wait_while_disabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    let mut token_state = CoordinatorState::new(disabled.clone(), base, wall);
    let manual_token = token_state
      .handle(
        base,
        CoordinatorEvent::RequestToken(manual_token_request(TokenWaiterId(70), None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token starts while disabled");
    token_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_failure(
        manual_token.generation,
        manual_token.source_generation,
        Duration::ZERO,
      )),
    );
    assert_eq!(
      token_state.next_wait(base + Duration::from_secs(2)),
      Some(Duration::from_secs(4))
    );
    assert_eq!(
      token_starts(&token_state.handle(base + Duration::from_secs(6), CoordinatorEvent::Timer,)),
      1
    );

    let mut live_state = CoordinatorState::new(disabled, base, wall);
    let manual_live = live_state
      .handle(
        base,
        CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(71))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("manual live starts while disabled");
    live_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::LiveFinished(execution_failure(
        manual_live.generation,
        manual_live.source_generation,
        Duration::ZERO,
      )),
    );
    assert_eq!(
      live_state.next_wait(base + Duration::from_secs(2)),
      Some(Duration::from_secs(4))
    );
  }

  #[test]
  fn next_wait_uses_earliest_lane_retry() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let token = start_token_generation(&mut state, base);
    let live = start_live_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_failure(
        token.generation,
        token.source_generation,
        Duration::ZERO,
      )),
    );
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::LiveFinished(execution_failure(
        live.generation,
        live.source_generation,
        Duration::ZERO,
      )),
    );

    assert_eq!(state.token_retry_at(), Some(base + Duration::from_secs(7)));
    assert_eq!(state.live_retry_at(), Some(base + Duration::from_secs(6)));
    assert_eq!(
      state.next_wait(base + Duration::from_secs(3)),
      Some(Duration::from_secs(3))
    );
  }

  #[test]
  fn future_retry_preempted_by_manual_has_no_planned_due() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut token_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let token = start_token_generation(&mut token_state, base);
    token_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        token.generation,
        token.source_generation,
        Duration::ZERO,
      )),
    );
    let token_manual = token_state
      .handle(
        base + Duration::from_secs(1),
        CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token request preempts future retry");
    assert_eq!(token_manual.request.planned_due_at, None);
    assert_eq!(token_state.snapshot().token.coalesced_trigger_count, 1);

    let mut live_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let live = start_live_generation(&mut live_state, base);
    live_state.handle(
      base,
      CoordinatorEvent::LiveFinished(execution_failure(
        live.generation,
        live.source_generation,
        Duration::ZERO,
      )),
    );
    let live_manual = live_state
      .handle(
        base + Duration::from_secs(1),
        CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(72))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("manual live request preempts future retry");
    assert_eq!(live_manual.planned_due_at, None);
    assert_eq!(live_state.snapshot().live.coalesced_trigger_count, 1);
  }

  #[test]
  fn overdue_retry_preempted_by_manual_keeps_original_planned_due() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let retry_due = base + Duration::from_secs(5);
    let mut token_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let token = start_token_generation(&mut token_state, base);
    token_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        token.generation,
        token.source_generation,
        Duration::ZERO,
      )),
    );
    let token_manual = token_state
      .handle(
        base + Duration::from_secs(10),
        CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual token request starts overdue retry");
    assert_eq!(token_manual.request.planned_due_at, Some(retry_due));

    let mut live_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let live = start_live_generation(&mut live_state, base);
    live_state.handle(
      base,
      CoordinatorEvent::LiveFinished(execution_failure(
        live.generation,
        live.source_generation,
        Duration::ZERO,
      )),
    );
    let live_manual = live_state
      .handle(
        base + Duration::from_secs(10),
        CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(73))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("manual live request starts overdue retry");
    assert_eq!(live_manual.planned_due_at, Some(retry_due));
  }

  #[test]
  fn disabled_retry_preemption_preserves_only_pre_disable_lag() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);

    let mut overdue_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let overdue = start_token_generation(&mut overdue_state, base);
    overdue_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        overdue.generation,
        overdue.source_generation,
        Duration::ZERO,
      )),
    );
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    overdue_state.handle(
      base + Duration::from_secs(8),
      CoordinatorEvent::SettingsChanged(disabled.clone()),
    );
    let frozen = overdue_state
      .handle(
        base + Duration::from_secs(20),
        CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual request starts frozen overdue retry");
    assert_eq!(
      frozen.request.planned_due_at,
      Some(base + Duration::from_secs(17))
    );

    let mut disabled_due_state =
      CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let future = start_token_generation(&mut disabled_due_state, base);
    disabled_due_state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        future.generation,
        future.source_generation,
        Duration::ZERO,
      )),
    );
    disabled_due_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(disabled.clone()),
    );
    let newly_eligible = disabled_due_state
      .handle(
        base + Duration::from_secs(20),
        CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual request starts retry that expired while disabled");
    assert_eq!(newly_eligible.request.planned_due_at, None);

    let mut overdue_live_state =
      CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let overdue_live = start_live_generation(&mut overdue_live_state, base);
    overdue_live_state.handle(
      base,
      CoordinatorEvent::LiveFinished(execution_failure(
        overdue_live.generation,
        overdue_live.source_generation,
        Duration::ZERO,
      )),
    );
    overdue_live_state.handle(
      base + Duration::from_secs(8),
      CoordinatorEvent::SettingsChanged(disabled.clone()),
    );
    let frozen_live = overdue_live_state
      .handle(
        base + Duration::from_secs(20),
        CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(76))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("manual live request starts frozen overdue retry");
    assert_eq!(
      frozen_live.planned_due_at,
      Some(base + Duration::from_secs(17))
    );

    let mut disabled_due_live_state =
      CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let future_live = start_live_generation(&mut disabled_due_live_state, base);
    disabled_due_live_state.handle(
      base,
      CoordinatorEvent::LiveFinished(execution_failure(
        future_live.generation,
        future_live.source_generation,
        Duration::ZERO,
      )),
    );
    disabled_due_live_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(disabled),
    );
    let newly_eligible_live = disabled_due_live_state
      .handle(
        base + Duration::from_secs(20),
        CoordinatorEvent::RequestLive(LiveRequest::manual(LiveWaiterId(77))),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("manual live request starts retry that expired while disabled");
    assert_eq!(newly_eligible_live.planned_due_at, None);
  }

  #[test]
  fn non_manual_waiters_are_rejected_before_disabled_pruning() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut disabled = test_config(Duration::from_secs(300), Some(wall));
    disabled.auto_scan_enabled = false;
    let mut token_state = CoordinatorState::new(disabled.clone(), base, wall);
    let token_waiter = TokenWaiterId(74);
    let mut token_request = TokenRequest::scheduled();
    token_request
      .try_add_waiter(token_waiter)
      .expect("test request accepts waiter before coordinator validation");
    let token_actions = token_state.handle(base, CoordinatorEvent::RequestToken(token_request));
    assert!(matches!(
      token_waiter_outcome(&token_actions, token_waiter),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::InvalidRequest,
        ..
      })
    ));

    let mut live_state = CoordinatorState::new(disabled, base, wall);
    let live_waiter = LiveWaiterId(75);
    let live_actions = live_state.handle(
      base,
      CoordinatorEvent::RequestLive(LiveRequest {
        reasons: RefreshReason::Scheduled.into(),
        waiter: Some(live_waiter),
        planned_due_at: None,
      }),
    );
    assert!(matches!(
      live_waiter_outcome(&live_actions, live_waiter),
      Some(RefreshWaiterOutcome::Rejected {
        code: RefreshRejectionCode::InvalidRequest,
        ..
      })
    ));
  }

  #[test]
  fn retry_and_normal_due_coalescence_increments_fixed_counter() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(5);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let token = start_token_generation(&mut state, base);
    let live = start_live_generation(&mut state, base);
    state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        token.generation,
        token.source_generation,
        Duration::ZERO,
      )),
    );
    state.handle(
      base,
      CoordinatorEvent::LiveFinished(execution_failure(
        live.generation,
        live.source_generation,
        Duration::ZERO,
      )),
    );

    let actions = state.handle(base + interval, CoordinatorEvent::Timer);

    assert_eq!(token_starts(&actions), 1);
    assert_eq!(live_starts(&actions), 1);
    assert_eq!(state.snapshot().token.coalesced_trigger_count, 1);
    assert_eq!(state.snapshot().live.coalesced_trigger_count, 1);
  }

  #[test]
  fn same_source_manual_at_normal_due_starts_one_generation() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut token_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let token_waiter = TokenWaiterId(78);

    let token_actions = token_state.handle(
      base + interval,
      CoordinatorEvent::RequestToken(manual_token_request(token_waiter, None)),
    );
    assert_eq!(token_starts(&token_actions), 1);
    let token = token_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("due manual token work starts");
    assert!(token.request.reasons.contains(RefreshReason::Manual));
    assert!(token.request.reasons.contains(RefreshReason::Scheduled));
    assert_eq!(token.request.planned_due_at, Some(base + interval));
    assert_eq!(token_state.token_next_deadline(), base + interval * 2);
    assert_eq!(token_state.snapshot().token.coalesced_trigger_count, 1);
    let token_completed = token_state.handle(
      base + interval + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_success(
        token.generation,
        token.source_generation,
        1,
        base + interval + Duration::from_secs(1),
      )),
    );
    assert_eq!(token_starts(&token_completed), 0);
    assert!(token_waiter_outcome(&token_completed, token_waiter).is_some());
    assert!(!token_state.snapshot().token.pending);

    let mut live_state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let live_waiter = LiveWaiterId(79);
    let overdue = base + Duration::from_secs(950);
    let live_actions = live_state.handle(
      overdue,
      CoordinatorEvent::RequestLive(LiveRequest::manual(live_waiter)),
    );
    assert_eq!(live_starts(&live_actions), 1);
    let live = live_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("overdue manual live work starts");
    assert!(live.reasons.contains(RefreshReason::Manual));
    assert!(live.reasons.contains(RefreshReason::Scheduled));
    assert_eq!(live.planned_due_at, Some(base + interval));
    assert_eq!(
      live_state.live_next_deadline(),
      base + Duration::from_secs(1_200)
    );
    assert_eq!(live_state.snapshot().live.coalesced_trigger_count, 1);
    let live_completed = live_state.handle(
      overdue + Duration::from_secs(1),
      CoordinatorEvent::LiveFinished(execution_success(
        live.generation,
        live.source_generation,
        1,
        overdue + Duration::from_secs(1),
      )),
    );
    assert_eq!(live_starts(&live_completed), 0);
    assert!(live_waiter_outcome(&live_completed, live_waiter).is_some());
    assert!(!live_state.snapshot().live.pending);
  }

  #[test]
  fn different_source_manual_at_normal_due_keeps_one_scheduled_follow_up() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let waiter = TokenWaiterId(80);

    let actions = state.handle(
      base + interval,
      CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-b"))),
    );
    assert_eq!(token_starts(&actions), 1);
    let manual = actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("different-source manual starts first");
    assert_eq!(
      manual.request.codex_home.as_deref(),
      Some("/normalized/home-b")
    );
    assert_eq!(manual.request.waiter_ids(), &[waiter]);
    assert!(!manual.request.reasons.contains(RefreshReason::Scheduled));
    assert!(state
      .snapshot()
      .token
      .pending_reasons
      .contains(RefreshReason::Scheduled));
    assert_eq!(state.snapshot().token.coalesced_trigger_count, 1);

    let completed = state.handle(
      base + interval + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_success(
        manual.generation,
        manual.source_generation,
        1,
        base + interval + Duration::from_secs(1),
      )),
    );
    assert!(matches!(
      token_waiter_outcome(&completed, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: true,
        ..
      }) if *generation == manual.generation
    ));
    let scheduled = completed
      .iter()
      .filter_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .collect::<Vec<_>>();
    assert_eq!(scheduled.len(), 1);
    assert!(scheduled[0]
      .request
      .reasons
      .contains(RefreshReason::Scheduled));
    assert!(scheduled[0].request.waiter_ids().is_empty());
    assert_eq!(
      scheduled[0].request.codex_home.as_deref(),
      Some("/normalized/home-a")
    );
  }

  #[test]
  fn due_work_merges_into_matching_protected_source_before_different_manual() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let home_a = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let waiter = TokenWaiterId(81);

    let queued = state.handle(
      base + interval,
      CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-c"))),
    );
    assert_eq!(token_starts(&queued), 0);
    assert!(token_waiter_outcome(&queued, waiter).is_none());
    assert_eq!(state.snapshot().token.coalesced_trigger_count, 3);

    let protected_actions = state.handle(
      base + interval + Duration::from_secs(1),
      CoordinatorEvent::TokenFinished(execution_success(
        home_a.generation,
        home_a.source_generation,
        1,
        base + interval + Duration::from_secs(1),
      )),
    );
    let protected = protected_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("protected home-b source refresh starts first");
    assert_eq!(
      protected.request.codex_home.as_deref(),
      Some("/normalized/home-b")
    );
    assert!(protected
      .request
      .reasons
      .contains(RefreshReason::SettingsChanged));
    assert!(protected.request.reasons.contains(RefreshReason::Scheduled));
    assert!(protected.request.waiter_ids().is_empty());

    let manual_actions = state.handle(
      base + interval + Duration::from_secs(2),
      CoordinatorEvent::TokenFinished(execution_success(
        protected.generation,
        protected.source_generation,
        2,
        base + interval + Duration::from_secs(2),
      )),
    );
    let manual = manual_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("different-source manual starts after protected refresh");
    assert_eq!(
      manual.request.codex_home.as_deref(),
      Some("/normalized/home-c")
    );
    assert_eq!(manual.request.waiter_ids(), &[waiter]);

    let completed = state.handle(
      base + interval + Duration::from_secs(3),
      CoordinatorEvent::TokenFinished(execution_success(
        manual.generation,
        manual.source_generation,
        3,
        base + interval + Duration::from_secs(3),
      )),
    );
    assert_eq!(token_starts(&completed), 0);
    assert!(matches!(
      token_waiter_outcome(&completed, waiter),
      Some(RefreshWaiterOutcome::Completed {
        generation,
        succeeded: true,
        ..
      }) if *generation == manual.generation
    ));
    assert!(!state.snapshot().token.pending);
  }

  #[test]
  fn due_work_merges_into_matching_future_protected_retry() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let home_a = start_token_generation(&mut state, base);
    let mut home_b = test_config(interval, Some(wall));
    home_b.codex_home = Some("/normalized/home-b".to_string());
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(home_b),
    );
    let home_b = state
      .handle(
        base + Duration::from_secs(2),
        CoordinatorEvent::TokenFinished(execution_success(
          home_a.generation,
          home_a.source_generation,
          1,
          base + Duration::from_secs(2),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("home-b protected source refresh starts");
    state.handle(
      base + Duration::from_secs(298),
      CoordinatorEvent::TokenFinished(execution_failure(
        home_b.generation,
        home_b.source_generation,
        Duration::ZERO,
      )),
    );
    assert_eq!(
      state.token_retry_at(),
      Some(base + Duration::from_secs(303))
    );
    let waiter = TokenWaiterId(82);
    state.handle(
      base + interval,
      CoordinatorEvent::RequestToken(manual_token_request(waiter, Some("/normalized/home-c"))),
    );
    assert_eq!(state.snapshot().token.coalesced_trigger_count, 3);

    let retry = state
      .handle(base + Duration::from_secs(303), CoordinatorEvent::Timer)
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("protected home-b retry starts first");
    assert_eq!(
      retry.request.codex_home.as_deref(),
      Some("/normalized/home-b")
    );
    assert!(retry.request.reasons.contains(RefreshReason::Scheduled));

    let manual = state
      .handle(
        base + Duration::from_secs(304),
        CoordinatorEvent::TokenFinished(execution_success(
          retry.generation,
          retry.source_generation,
          2,
          base + Duration::from_secs(304),
        )),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("manual home-c request starts after protected retry");
    assert_eq!(manual.request.waiter_ids(), &[waiter]);
    let completed = state.handle(
      base + Duration::from_secs(305),
      CoordinatorEvent::TokenFinished(execution_success(
        manual.generation,
        manual.source_generation,
        3,
        base + Duration::from_secs(305),
      )),
    );
    assert_eq!(token_starts(&completed), 0);
    assert!(token_waiter_outcome(&completed, waiter).is_some());
    assert!(!state.snapshot().token.pending);
  }

  #[test]
  fn merged_request_keeps_earliest_planned_due() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut token_state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let token_running = start_token_generation(&mut token_state, base);
    token_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason_at(
        RefreshReason::Scheduled,
        base + Duration::from_secs(40),
      )),
    );
    token_state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason_at(
        RefreshReason::Wake,
        base + Duration::from_secs(20),
      )),
    );
    token_state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestToken(TokenRequest::manual_full(None)),
    );
    let token_actions = token_state.handle(
      base + Duration::from_secs(4),
      CoordinatorEvent::TokenFinished(execution_success(
        token_running.generation,
        token_running.source_generation,
        1,
        base + Duration::from_secs(4),
      )),
    );
    let token_follow_up = token_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartToken(request) => Some(request),
        _ => None,
      })
      .expect("merged token follow-up starts");
    assert_eq!(
      token_follow_up.request.planned_due_at,
      Some(base + Duration::from_secs(20))
    );

    let mut live_state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    let live_running = start_live_generation(&mut live_state, base);
    live_state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestLive(LiveRequest::for_reason_at(
        RefreshReason::Scheduled,
        base + Duration::from_secs(30),
      )),
    );
    live_state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestLive(LiveRequest::for_reason_at(
        RefreshReason::Wake,
        base + Duration::from_secs(10),
      )),
    );
    let live_actions = live_state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::LiveFinished(execution_success(
        live_running.generation,
        live_running.source_generation,
        1,
        base + Duration::from_secs(3),
      )),
    );
    let live_follow_up = live_actions
      .iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("merged live follow-up starts");
    assert_eq!(
      live_follow_up.planned_due_at,
      Some(base + Duration::from_secs(10))
    );
  }

  #[test]
  fn snapshot_reports_running_and_pending_state() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut config = test_config(interval, Some(wall));
    config.codex_home = Some("/normalized/home-a".to_string());
    let mut state = CoordinatorState::new(config, base, wall);
    let token = start_token_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason(RefreshReason::Wake)),
    );
    let live = start_live_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::LiveFinished(execution_failure(
        live.generation,
        live.source_generation,
        Duration::ZERO,
      )),
    );

    let snapshot = state.snapshot();
    assert_eq!(snapshot.token.running_generation, Some(token.generation));
    assert_eq!(snapshot.token.next_normal_deadline, base + interval);
    assert_eq!(snapshot.token.retry_deadline, None);
    assert_eq!(snapshot.token.failure_streak, 0);
    assert!(snapshot.token.pending);
    assert!(snapshot.token.pending_reasons.contains(RefreshReason::Wake));
    assert_eq!(snapshot.live.running_generation, None);
    assert_eq!(
      snapshot.live.retry_deadline,
      Some(base + Duration::from_secs(7))
    );
    assert_eq!(snapshot.live.failure_streak, 1);
    assert!(snapshot.live.pending);
    assert!(snapshot
      .live
      .pending_reasons
      .contains(RefreshReason::Scheduled));
    assert_eq!(snapshot.source_generation, 0);
    assert_eq!(snapshot.interval, interval);
    assert!(snapshot.auto_scan_enabled);
    assert_eq!(std::mem::size_of::<ReasonSet>(), 1);
    assert_eq!(
      RefreshReason::Wake as u8,
      snapshot.token.pending_reasons.bits().trailing_zeros() as u8
    );
  }

  #[test]
  fn missed_deadline_counter_is_saturating_and_fixed() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(10);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    state.token.missed_deadline_count = u64::MAX;

    state.handle(base + Duration::from_secs(35), CoordinatorEvent::Timer);

    let snapshot = state.snapshot();
    assert_eq!(snapshot.token.missed_deadline_count, u64::MAX);
    assert_eq!(snapshot.live.missed_deadline_count, 2);
  }

  #[test]
  fn many_missed_intervals_advance_in_constant_work() {
    let base = Instant::now();
    let interval = Duration::from_nanos(10);
    let now = base + Duration::from_secs(100);

    let (next, missed) = advance_fixed_deadline(base + interval, interval, now);

    assert_eq!(next, now + interval);
    assert_eq!(missed, 9_999_999_999);
  }

  #[test]
  fn huge_interval_never_overflows_monotonic_deadlines() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let huge = Duration::MAX;
    let mut state = CoordinatorState::new(test_config(huge, Some(wall)), base, wall);
    assert!(state.token_next_deadline() > base);
    assert!(state.live_next_deadline() > base);
    assert!(state.snapshot().interval < huge);
    assert!(base.checked_add(state.snapshot().interval).is_some());

    let shortened = state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(test_config(Duration::from_secs(60), Some(wall))),
    );
    assert!(shortened.is_empty());
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(60));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(60));

    let (advanced, missed) = advance_fixed_deadline(base, huge, base);
    assert!(advanced > base);
    assert_eq!(missed, 0);

    let mut changed =
      CoordinatorState::new(test_config(Duration::from_secs(60), Some(wall)), base, wall);
    let actions = changed.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(test_config(huge, Some(wall))),
    );
    assert!(actions.is_empty());
    assert!(changed.token_next_deadline() > base + Duration::from_secs(1));
    assert!(changed.live_next_deadline() > base + Duration::from_secs(1));
  }

  #[test]
  fn disabled_intervals_do_not_count_as_missed() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    let mut state = CoordinatorState::new(disabled, base, wall);

    assert!(state
      .handle(base + Duration::from_secs(1_800), CoordinatorEvent::Timer)
      .is_empty());
    assert_eq!(state.snapshot().token.missed_deadline_count, 0);
    assert_eq!(state.snapshot().live.missed_deadline_count, 0);

    let reenabled = state.handle(
      base + Duration::from_secs(1_800),
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );
    assert_eq!(token_starts(&reenabled), 1);
    assert_eq!(live_starts(&reenabled), 1);
    assert_eq!(state.snapshot().token.missed_deadline_count, 0);
    assert_eq!(state.snapshot().live.missed_deadline_count, 0);
  }

  #[test]
  fn enabled_overdue_misses_survive_disable_and_reenable() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;

    let disabling = state.handle(
      base + Duration::from_secs(950),
      CoordinatorEvent::SettingsChanged(disabled),
    );
    assert!(disabling.is_empty());
    assert_eq!(state.snapshot().token.missed_deadline_count, 2);
    assert_eq!(state.snapshot().live.missed_deadline_count, 2);

    let reenabled = state.handle(
      base + Duration::from_secs(1_850),
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );
    assert_eq!(token_starts(&reenabled), 1);
    assert_eq!(live_starts(&reenabled), 1);
    assert_eq!(state.snapshot().token.missed_deadline_count, 2);
    assert_eq!(state.snapshot().live.missed_deadline_count, 2);
  }

  #[test]
  fn disabled_deadline_catch_up_is_planned_when_reenabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    let mut state = CoordinatorState::new(disabled, base, wall);
    let reenabled_at = base + Duration::from_secs(1_800);

    let actions = state.handle(
      reenabled_at,
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );

    let token = actions.iter().find_map(|action| match action {
      CoordinatorAction::StartToken(request) => Some(request),
      _ => None,
    });
    let live = actions.iter().find_map(|action| match action {
      CoordinatorAction::StartLive(request) => Some(request),
      _ => None,
    });
    assert_eq!(
      token.and_then(|value| value.request.planned_due_at),
      Some(reenabled_at)
    );
    assert_eq!(
      live.and_then(|value| value.planned_due_at),
      Some(reenabled_at)
    );
  }

  #[test]
  fn disabled_time_does_not_inflate_preexisting_normal_start_lag() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let disabled_at = base + Duration::from_secs(950);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    state.handle(disabled_at, CoordinatorEvent::SettingsChanged(disabled));
    let reenabled_at = base + Duration::from_secs(1_850);

    let actions = state.handle(
      reenabled_at,
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );
    let expected_due = reenabled_at - disabled_at.duration_since(base + interval);
    let token = actions.iter().find_map(|action| match action {
      CoordinatorAction::StartToken(request) => Some(request),
      _ => None,
    });
    let live = actions.iter().find_map(|action| match action {
      CoordinatorAction::StartLive(request) => Some(request),
      _ => None,
    });
    assert_eq!(
      token.and_then(|value| value.request.planned_due_at),
      Some(expected_due)
    );
    assert_eq!(
      live.and_then(|value| value.planned_due_at),
      Some(expected_due)
    );
    assert_eq!(state.snapshot().token.missed_deadline_count, 2);
    assert_eq!(state.snapshot().live.missed_deadline_count, 2);
  }

  #[test]
  fn automatic_retry_due_while_disabled_is_planned_when_reenabled() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut state = CoordinatorState::new(test_config(interval, Some(wall)), base, wall);
    let token = start_token_generation(&mut state, base);
    state.handle(
      base,
      CoordinatorEvent::TokenFinished(execution_failure(
        token.generation,
        token.source_generation,
        Duration::ZERO,
      )),
    );
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::SettingsChanged(disabled),
    );
    let reenabled_at = base + Duration::from_secs(100);

    let actions = state.handle(
      reenabled_at,
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );
    let retry = actions.iter().find_map(|action| match action {
      CoordinatorAction::StartToken(request) => Some(request),
      _ => None,
    });
    assert_eq!(
      retry.and_then(|value| value.request.planned_due_at),
      Some(reenabled_at)
    );
  }

  #[test]
  fn reenable_before_deadline_does_not_suppress_future_misses() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let interval = Duration::from_secs(300);
    let mut disabled = test_config(interval, Some(wall));
    disabled.auto_scan_enabled = false;
    let mut state = CoordinatorState::new(disabled, base, wall);
    let reenabled = state.handle(
      base + Duration::from_secs(100),
      CoordinatorEvent::SettingsChanged(test_config(interval, Some(wall))),
    );
    assert!(reenabled.is_empty());

    state.handle(base + Duration::from_secs(950), CoordinatorEvent::Timer);

    assert_eq!(state.snapshot().token.missed_deadline_count, 2);
    assert_eq!(state.snapshot().live.missed_deadline_count, 2);
  }

  #[test]
  fn coalesced_trigger_counter_tracks_merged_work() {
    let base = Instant::now();
    let wall = utc("2026-07-10T10:00:00Z");
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(300), Some(wall)),
      base,
      wall,
    );
    start_token_generation(&mut state, base);
    start_live_generation(&mut state, base);
    state.handle(
      base + Duration::from_secs(1),
      CoordinatorEvent::RequestToken(TokenRequest::scheduled()),
    );
    state.handle(
      base + Duration::from_secs(2),
      CoordinatorEvent::RequestToken(TokenRequest::for_reason(RefreshReason::Wake)),
    );
    state.handle(
      base + Duration::from_secs(3),
      CoordinatorEvent::RequestLive(LiveRequest::scheduled()),
    );

    let snapshot = state.snapshot();
    assert_eq!(snapshot.token.coalesced_trigger_count, 2);
    assert_eq!(snapshot.live.coalesced_trigger_count, 1);
  }
}

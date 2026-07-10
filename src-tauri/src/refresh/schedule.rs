use super::{
  CommitMarker, DisplayInvalidation, ExecutionCompletion, LiveExecutionRequest, LiveRequest,
  LiveWaiterId, ReasonSet, RefreshCompletedEvent, RefreshConfig, RefreshLane, RefreshReason,
  TokenExecutionRequest, TokenRequest, TokenScanKind,
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
    generation: u64,
    succeeded: bool,
    failure: Option<String>,
  },
}

struct LaneState {
  next_deadline: Instant,
  startup_due: bool,
  immediate_due: bool,
  last_generation: u64,
  running_generation: Option<u64>,
  failure_streak: u32,
  retry_at: Option<Instant>,
}

impl LaneState {
  fn new(next_deadline: Instant, monotonic_now: Instant) -> Self {
    Self {
      next_deadline,
      startup_due: next_deadline <= monotonic_now,
      immediate_due: false,
      last_generation: 0,
      running_generation: None,
      failure_streak: 0,
      retry_at: None,
    }
  }

  fn recalculate_interval(&mut self, now: Instant, old_interval: Duration, new_interval: Duration) {
    if self.startup_due || old_interval == new_interval {
      return;
    }

    let elapsed = if self.next_deadline > now {
      old_interval.saturating_sub(self.next_deadline.duration_since(now))
    } else {
      old_interval.saturating_add(now.duration_since(self.next_deadline))
    };
    let remaining = if self.next_deadline.checked_sub(old_interval).is_some() {
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
    self.next_deadline = now + remaining;
    self.immediate_due = elapsed >= new_interval;
  }

  fn take_normal_due(
    &mut self,
    now: Instant,
    interval: Duration,
    trigger_reason: RefreshReason,
  ) -> Option<RefreshReason> {
    if !self.immediate_due && self.next_deadline > now {
      return None;
    }

    self.immediate_due = false;
    if self.next_deadline <= now {
      let (next_deadline, _) = advance_fixed_deadline(self.next_deadline, interval, now);
      self.next_deadline = next_deadline;
    }
    let reason = if self.startup_due {
      RefreshReason::Startup
    } else {
      trigger_reason
    };
    self.startup_due = false;
    Some(reason)
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
  live_retry_reasons: ReasonSet,
  live_waiters: Vec<LiveWaiterId>,
  source_generation: u64,
  refresh_revision: u64,
  usage_revision: u64,
  quota_revision: u64,
  settings_revision: u64,
}

impl CoordinatorState {
  pub(crate) fn new(
    config: RefreshConfig,
    monotonic_now: Instant,
    wall_now: DateTime<Utc>,
  ) -> Self {
    assert!(
      !config.interval.is_zero(),
      "refresh interval must be positive"
    );
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
      live_retry_reasons: ReasonSet::default(),
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
      CoordinatorEvent::RequestToken(request) => {
        if !self.config.auto_scan_enabled && !request.reasons.contains(RefreshReason::Manual) {
          return Vec::new();
        }
        let mut actions = Vec::with_capacity(1);
        self.submit_token_request(request, &mut actions);
        actions
      }
      CoordinatorEvent::RequestLive(request) => {
        if !self.config.auto_scan_enabled && !request.reasons.contains(RefreshReason::Manual) {
          return Vec::new();
        }
        let mut actions = Vec::with_capacity(1);
        self.submit_live_request(request, &mut actions);
        actions
      }
      CoordinatorEvent::TokenPrepared {
        generation,
        source_generation,
      } => self.handle_token_prepared(generation, source_generation),
      CoordinatorEvent::TokenFinished(completion) => {
        self.handle_token_finished(now, completion)
      }
      CoordinatorEvent::LiveFinished(completion) => {
        self.handle_live_finished(now, completion)
      }
    }
  }

  fn handle_due(&mut self, now: Instant, trigger_reason: RefreshReason) -> Vec<CoordinatorAction> {
    let mut token_request = self.take_due_token_request(now, trigger_reason);
    let mut live_reasons = self.take_due_live_reasons(now, trigger_reason);
    let mut actions = Vec::with_capacity(2);

    if let Some((request, source_refresh)) = token_request.take() {
      if source_refresh {
        self.submit_source_refresh_request(request, &mut actions);
      } else {
        self.submit_token_request(request, &mut actions);
      }
    }
    if !live_reasons.is_empty() {
      self.submit_live_request(
        LiveRequest {
          reasons: std::mem::take(&mut live_reasons),
          waiter: None,
        },
        &mut actions,
      );
    }

    actions
  }

  fn handle_settings_changed(
    &mut self,
    now: Instant,
    config: RefreshConfig,
  ) -> Vec<CoordinatorAction> {
    assert!(
      !config.interval.is_zero(),
      "refresh interval must be positive"
    );
    let old_interval = self.config.interval;
    let source_changed = self.config.codex_home != config.codex_home;
    let disabling_auto_scan = self.config.auto_scan_enabled && !config.auto_scan_enabled;
    let settings_changed = self.config.auto_scan_enabled != config.auto_scan_enabled
      || old_interval != config.interval
      || source_changed;

    self
      .token
      .recalculate_interval(now, old_interval, config.interval);
    self
      .live
      .recalculate_interval(now, old_interval, config.interval);
    self.config = config;

    if disabling_auto_scan {
      self.prune_automatic_pending_work();
    }

    if settings_changed {
      self.settings_revision = self.settings_revision.saturating_add(1);
    }

    let mut token_request = None;
    let mut token_request_is_source_refresh = false;
    let mut live_reasons = ReasonSet::default();
    if source_changed {
      self.source_generation = self
        .source_generation
        .checked_add(1)
        .expect("refresh source generation overflowed");
      self.token.failure_streak = 0;
      self.token.retry_at = None;
      self.token_retry_request = None;
      self.token_retry_source_refresh = false;
      self.live.failure_streak = 0;
      self.live.retry_at = None;
      self.live_retry_reasons = ReasonSet::default();

      let mut request = TokenRequest {
        reasons: RefreshReason::SettingsChanged.into(),
        kind: TokenScanKind::Full,
        codex_home: self.config.codex_home.clone(),
      };
      if let Some(previous_source_refresh) = self.token_source_refresh_pending.take() {
        request.reasons.merge(previous_source_refresh.reasons);
      }
      if let Some(pending) = self.token_pending_automatic.take() {
        request.reasons.merge(pending.reasons);
      }
      if let Some(mut pending) = self.token_pending_manual.take() {
        let manual_for_another_home = pending.reasons.contains(RefreshReason::Manual)
          && pending.codex_home != self.config.codex_home;
        if manual_for_another_home {
          let mut automatic_reasons = pending.reasons;
          automatic_reasons.remove(RefreshReason::Manual);
          request.reasons.merge(automatic_reasons);
          pending.reasons = RefreshReason::Manual.into();
          self.token_pending_manual = Some(pending);
        } else {
          request.reasons.merge(pending.reasons);
        }
      }
      token_request = Some(request);
      token_request_is_source_refresh = true;
      if self.config.auto_scan_enabled {
        live_reasons.insert(RefreshReason::SettingsChanged);
      }
    }

    if let Some((due, due_is_source_refresh)) =
      self.take_due_token_request(now, RefreshReason::SettingsChanged)
    {
      merge_token_request(&mut token_request, due);
      token_request_is_source_refresh |= due_is_source_refresh;
    }
    live_reasons.merge(self.take_due_live_reasons(now, RefreshReason::SettingsChanged));

    let mut actions = Vec::with_capacity(2);
    if let Some(request) = token_request {
      if token_request_is_source_refresh {
        self.submit_source_refresh_request(request, &mut actions);
      } else {
        self.submit_token_request(request, &mut actions);
      }
    }
    if !live_reasons.is_empty() {
      self.submit_live_request(
        LiveRequest {
          reasons: live_reasons,
          waiter: None,
        },
        &mut actions,
      );
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
        if let Some(retry) = self.token_retry_request.take() {
          merge_token_request(&mut request, retry);
          source_refresh = self.token_retry_source_refresh;
          self.token_retry_source_refresh = false;
        }
      }
    }

    if self.config.auto_scan_enabled {
      if let Some(reason) =
        self
          .token
          .take_normal_due(now, self.config.interval, trigger_reason)
      {
        merge_token_request(
          &mut request,
          TokenRequest {
            reasons: reason.into(),
            kind: TokenScanKind::Incremental,
            codex_home: self.config.codex_home.clone(),
          },
        );
      }
    }
    request.map(|request| (request, source_refresh))
  }

  fn take_due_live_reasons(
    &mut self,
    now: Instant,
    trigger_reason: RefreshReason,
  ) -> ReasonSet {
    let mut reasons = ReasonSet::default();
    if self.live.retry_at.is_some_and(|retry_at| retry_at <= now) {
      let retry_allowed = self.config.auto_scan_enabled
        || self.live_retry_reasons.contains(RefreshReason::Manual);
      if retry_allowed {
        self.live.retry_at = None;
        reasons.merge(std::mem::take(&mut self.live_retry_reasons));
      }
    }

    if self.config.auto_scan_enabled {
      if let Some(reason) =
        self
          .live
          .take_normal_due(now, self.config.interval, trigger_reason)
      {
        reasons.insert(reason);
      }
    }
    reasons
  }

  fn submit_token_request(
    &mut self,
    mut request: TokenRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if request.reasons.is_empty() {
      return;
    }
    if request.codex_home.is_none() {
      request.codex_home = self.config.codex_home.clone();
    }

    if self.token.running_generation.is_some() {
      if !self.token_running_source_refresh {
        if let Some(source_refresh) = self.token_source_refresh_pending.as_mut() {
          if source_refresh.codex_home == request.codex_home {
            source_refresh.merge(request);
            return;
          }
        }
      }
      self.queue_token_pending_request(request);
      return;
    }

    if self.token_retry_source_refresh {
      if let Some(source_retry) = self.token_retry_request.as_mut() {
        if source_retry.codex_home == request.codex_home {
          source_retry.merge(request);
        } else {
          self.queue_token_pending_request(request);
        }
        return;
      }
      self.token_retry_source_refresh = false;
    }

    if let Some(mut retry) = self.token_retry_request.take() {
      if retry.codex_home == request.codex_home {
        retry.merge(request);
        request = retry;
      }
    }
    self.token.retry_at = None;
    self.start_token_request(request, false, actions);
  }

  fn queue_token_pending_request(&mut self, mut request: TokenRequest) {
    if request.reasons.contains(RefreshReason::Manual) {
      let automatic_matches = self
        .token_pending_automatic
        .as_ref()
        .is_some_and(|pending| pending.codex_home == request.codex_home);
      if automatic_matches {
        if let Some(automatic) = self.token_pending_automatic.take() {
          request.merge(automatic);
        }
      }
      if let Some(manual) = self.token_pending_manual.as_mut() {
        if manual.codex_home == request.codex_home {
          manual.merge(request);
        } else {
          *manual = request;
        }
      } else {
        self.token_pending_manual = Some(request);
      }
      return;
    }

    if let Some(manual) = self.token_pending_manual.as_mut() {
      if manual.codex_home == request.codex_home {
        manual.merge(request);
        return;
      }
    }
    if let Some(automatic) = self.token_pending_automatic.as_mut() {
      if automatic.codex_home == request.codex_home {
        automatic.merge(request);
      } else {
        *automatic = request;
      }
    } else {
      self.token_pending_automatic = Some(request);
    }
  }

  fn start_token_request(
    &mut self,
    request: TokenRequest,
    source_refresh: bool,
    actions: &mut Vec<CoordinatorAction>,
  ) {
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
          .is_some_and(|running| running.request.codex_home == request.codex_home);
      if matches_running_source_refresh {
        merge_token_request(&mut self.token_source_refresh_pending, request);
        return;
      }
      if let Some(previous) = self.token_source_refresh_pending.take() {
        request.reasons.merge(previous.reasons);
      }
      self.token_source_refresh_pending = Some(request);
      return;
    }
    self.token.retry_at = None;
    self.token_retry_request = None;
    self.token_retry_source_refresh = false;
    self.start_token_request(request, true, actions);
  }

  fn submit_live_request(
    &mut self,
    mut request: LiveRequest,
    actions: &mut Vec<CoordinatorAction>,
  ) {
    if self.live.running_generation.is_some() {
      if let Some(waiter) = request.waiter {
        push_unique_waiter(&mut self.live_waiters, waiter);
      }
      request.reasons.remove(RefreshReason::Manual);
      self.live_pending.merge(request.reasons);
      return;
    }

    if let Some(waiter) = request.waiter {
      push_unique_waiter(&mut self.live_waiters, waiter);
    }
    request.reasons.merge(std::mem::take(&mut self.live_retry_reasons));
    self.live.retry_at = None;
    if request.reasons.is_empty() {
      return;
    }

    let generation = self.live.start_generation();
    let execution = LiveExecutionRequest {
      generation,
      source_generation: self.source_generation,
      reasons: request.reasons,
    };
    self.live_running = Some(execution.clone());
    actions.push(CoordinatorAction::StartLive(execution));
  }

  fn handle_token_prepared(
    &mut self,
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

    if running.source_generation == source_generation
      && source_generation == self.source_generation
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
    if self.token_source_refresh_pending.is_none() {
      let mut request = stale.request;
      request.kind = TokenScanKind::Full;
      request.codex_home = self.config.codex_home.clone();
      request.reasons.insert(RefreshReason::SettingsChanged);
      self.token_source_refresh_pending = Some(request);
    }
    self.start_pending_token(&mut actions);
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

    let running = self
      .token_running
      .take()
      .expect("matching token generation remains present");
    let running_source_refresh = self.token_running_source_refresh;
    self.token.clear_running();
    self.token_running_source_refresh = false;
    if running.source_generation != completion.source_generation
      || completion.source_generation != self.source_generation
    {
      let mut actions = Vec::with_capacity(1);
      self.start_pending_token(&mut actions);
      return actions;
    }

    let completion = normalize_completion(completion);
    let mut actions = Vec::with_capacity(3);
    if completion.succeeded {
      self.token.failure_streak = 0;
      self.token.retry_at = None;
      self.token_retry_request = None;
      self.token_retry_source_refresh = false;
      self.usage_revision = self.usage_revision.saturating_add(1);
      actions.push(CoordinatorAction::PublishInvalidation(
        self.invalidation(completion.commit.expect("normalized success has commit marker")),
      ));
    } else {
      self.token.failure_streak = self.token.failure_streak.saturating_add(1);
      let jitter = completion.retry_jitter.min(Duration::from_secs(1));
      let delay = retry_delay(self.token.failure_streak, self.config.interval, jitter);
      self.token.retry_at = Some(now.checked_add(delay).unwrap_or(now));
      let mut retry_request = running.request;
      if running_source_refresh {
        if let Some(pending) = self.token_source_refresh_pending.take() {
          retry_request.merge(pending);
        }
      }
      self.token_retry_request = Some(retry_request);
      self.token_retry_source_refresh = running_source_refresh;
    }
    actions.push(CoordinatorAction::PublishCompletion(
      self.completed_event(RefreshLane::Token, &completion),
    ));
    self.start_pending_token(&mut actions);
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
      if !waiters.is_empty() {
        actions.push(CoordinatorAction::ResolveLiveWaiters {
          waiter_ids: waiters,
          generation: completion.generation,
          succeeded: false,
          failure: Some("refresh source changed".to_string()),
        });
      }
      self.start_pending_live(&mut actions);
      return actions;
    }

    let completion = normalize_completion(completion);
    let mut actions = Vec::with_capacity(4);
    if completion.succeeded {
      self.live.failure_streak = 0;
      self.live.retry_at = None;
      self.live_retry_reasons = ReasonSet::default();
      self.quota_revision = self.quota_revision.saturating_add(1);
      actions.push(CoordinatorAction::PublishInvalidation(
        self.invalidation(completion.commit.expect("normalized success has commit marker")),
      ));
    } else {
      self.live.failure_streak = self.live.failure_streak.saturating_add(1);
      let jitter = completion.retry_jitter.min(Duration::from_secs(1));
      let delay = retry_delay(self.live.failure_streak, self.config.interval, jitter);
      self.live.retry_at = Some(now.checked_add(delay).unwrap_or(now));
      self.live_retry_reasons = running.reasons;
    }
    actions.push(CoordinatorAction::PublishCompletion(
      self.completed_event(RefreshLane::Live, &completion),
    ));
    if !waiters.is_empty() {
      actions.push(CoordinatorAction::ResolveLiveWaiters {
        waiter_ids: waiters,
        generation: completion.generation,
        succeeded: completion.succeeded,
        failure: completion.failure.clone(),
      });
    }
    self.start_pending_live(&mut actions);
    actions
  }

  fn start_pending_token(&mut self, actions: &mut Vec<CoordinatorAction>) {
    if self.token_retry_source_refresh {
      return;
    }
    if let Some(request) = self.token_source_refresh_pending.take() {
      self.submit_source_refresh_request(request, actions);
      return;
    }
    if let Some(request) = self.token_pending_manual.take() {
      self.submit_token_request(request, actions);
      return;
    }
    if let Some(request) = self.token_pending_automatic.take() {
      if self.config.auto_scan_enabled {
        self.submit_token_request(request, actions);
      }
    }
  }

  fn prune_automatic_pending_work(&mut self) {
    if let Some(pending) = self.token_pending_manual.as_mut() {
      pending.reasons = RefreshReason::Manual.into();
    }
    self.token_pending_automatic = None;
    self.live_pending = ReasonSet::default();
  }

  fn start_pending_live(&mut self, actions: &mut Vec<CoordinatorAction>) {
    let reasons = std::mem::take(&mut self.live_pending);
    if !reasons.is_empty() {
      self.submit_live_request(
        LiveRequest {
          reasons,
          waiter: None,
        },
        actions,
      );
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
}

fn merge_token_request(target: &mut Option<TokenRequest>, request: TokenRequest) {
  if let Some(target) = target {
    target.merge(request);
  } else {
    *target = Some(request);
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
    completion.failure = Some("successful refresh completion missing commit marker".to_string());
  } else if !completion.succeeded && completion.failure.is_none() {
    completion.failure = Some("refresh failed without an error".to_string());
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

fn advance_fixed_deadline(
  mut deadline: Instant,
  interval: Duration,
  now: Instant,
) -> (Instant, u64) {
  let mut elapsed_intervals = 0_u64;
  while deadline <= now {
    deadline += interval;
    elapsed_intervals += 1;
  }
  (deadline, elapsed_intervals.saturating_sub(1))
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
  monotonic_now + interval.saturating_sub(age)
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
    let mut state = CoordinatorState::new(
      test_config(Duration::from_secs(60), Some(wall)),
      base,
      wall,
    );
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
      .handle(
        now,
        CoordinatorEvent::RequestLive(LiveRequest::scheduled()),
      )
      .into_iter()
      .find_map(|action| match action {
        CoordinatorAction::StartLive(request) => Some(request),
        _ => None,
      })
      .expect("live generation starts")
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
    assert!(starts[0]
      .reasons
      .contains(RefreshReason::SettingsChanged));
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
        generation,
        succeeded: true,
        failure: None,
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
        generation,
        succeeded: false,
        failure: Some(failure),
      } if waiter_ids == &[waiter_id]
        && *generation == first.generation
        && failure == "refresh source changed"
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
}

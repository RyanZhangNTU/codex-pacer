use super::{RefreshConfig, RefreshReason, TokenScanKind};
use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub(crate) enum CoordinatorEvent {
  Timer,
  Wake,
  SettingsChanged(RefreshConfig),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CoordinatorAction {
  StartToken {
    kind: TokenScanKind,
    reason: RefreshReason,
  },
  StartLive {
    reason: RefreshReason,
  },
}

struct LaneState {
  next_deadline: Instant,
  running: bool,
  startup_due: bool,
}

impl LaneState {
  fn new(next_deadline: Instant, monotonic_now: Instant) -> Self {
    Self {
      next_deadline,
      running: false,
      startup_due: next_deadline <= monotonic_now,
    }
  }

  fn recalculate_interval(&mut self, old_interval: Duration, new_interval: Duration) {
    if self.startup_due || old_interval == new_interval {
      return;
    }

    let Some(previous_planned_deadline) = self.next_deadline.checked_sub(old_interval) else {
      return;
    };
    let Some(next_deadline) = previous_planned_deadline.checked_add(new_interval) else {
      return;
    };
    self.next_deadline = next_deadline;
  }

  fn take_due(
    &mut self,
    now: Instant,
    interval: Duration,
    trigger_reason: RefreshReason,
  ) -> Option<RefreshReason> {
    if self.next_deadline > now {
      return None;
    }

    let (next_deadline, _) = advance_fixed_deadline(self.next_deadline, interval, now);
    self.next_deadline = next_deadline;
    let reason = if self.startup_due {
      RefreshReason::Startup
    } else {
      trigger_reason
    };
    self.startup_due = false;

    if self.running {
      return None;
    }

    self.running = true;
    Some(reason)
  }
}

pub(crate) struct CoordinatorState {
  config: RefreshConfig,
  token: LaneState,
  live: LaneState,
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
    }
  }

  pub(crate) fn handle(&mut self, now: Instant, event: CoordinatorEvent) -> Vec<CoordinatorAction> {
    let trigger_reason = match event {
      CoordinatorEvent::Timer => RefreshReason::Scheduled,
      CoordinatorEvent::Wake => RefreshReason::Wake,
      CoordinatorEvent::SettingsChanged(config) => {
        assert!(
          !config.interval.is_zero(),
          "refresh interval must be positive"
        );
        let old_interval = self.config.interval;
        self
          .token
          .recalculate_interval(old_interval, config.interval);
        self
          .live
          .recalculate_interval(old_interval, config.interval);
        self.config = config;
        RefreshReason::SettingsChanged
      }
    };

    if !self.config.auto_scan_enabled {
      return Vec::new();
    }

    let mut actions = Vec::with_capacity(2);
    if let Some(reason) = self
      .token
      .take_due(now, self.config.interval, trigger_reason)
    {
      actions.push(CoordinatorAction::StartToken {
        kind: TokenScanKind::Incremental,
        reason,
      });
    }
    if let Some(reason) = self
      .live
      .take_due(now, self.config.interval, trigger_reason)
    {
      actions.push(CoordinatorAction::StartLive { reason });
    }
    actions
  }

  pub(crate) fn token_next_deadline(&self) -> Instant {
    self.token.next_deadline
  }

  pub(crate) fn live_next_deadline(&self) -> Instant {
    self.live.next_deadline
  }
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
      .filter(|value| matches!(value, CoordinatorAction::StartToken { .. }))
      .count()
  }

  fn live_starts(actions: &[CoordinatorAction]) -> usize {
    actions
      .iter()
      .filter(|value| matches!(value, CoordinatorAction::StartLive { .. }))
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
        CoordinatorAction::StartToken {
          kind: TokenScanKind::Incremental,
          reason: RefreshReason::Startup,
        },
        CoordinatorAction::StartLive {
          reason: RefreshReason::Startup,
        },
      ]
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
      .any(|value| matches!(value, CoordinatorAction::StartToken { .. })));
    assert!(actions
      .iter()
      .any(|value| matches!(value, CoordinatorAction::StartLive { .. })));
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
      [CoordinatorAction::StartLive {
        reason: RefreshReason::Scheduled,
      }]
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
        CoordinatorAction::StartToken {
          reason: RefreshReason::Wake,
          ..
        },
        CoordinatorAction::StartLive {
          reason: RefreshReason::Wake,
        },
      ]
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
        CoordinatorAction::StartToken {
          reason: RefreshReason::SettingsChanged,
          ..
        },
        CoordinatorAction::StartLive {
          reason: RefreshReason::SettingsChanged,
        },
      ]
    ));
    assert_eq!(state.token_next_deadline(), base + Duration::from_secs(90));
    assert_eq!(state.live_next_deadline(), base + Duration::from_secs(90));
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
}

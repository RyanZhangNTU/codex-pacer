#[cfg(test)]
mod tests {
  use super::{
    EpochMaintenanceBatch, MetricsState, PanicPhase, PreparedTokenRefresh, RefreshClock,
    RefreshConfig, RefreshError, RefreshStatus, RuntimeTestRig, SaturatingCounter, TestClock,
    TestEpochMaintenanceExecutor, TestLiveExecutor, TestRigSchedule,
  };
  use crate::refresh::{RefreshFailureCode, RefreshRejectionCode, REFRESH_WAITER_CAPACITY};
  use chrono::{DateTime, Duration as ChronoDuration};
  use std::sync::atomic::Ordering;
  use std::sync::{mpsc, Arc};
  use std::thread;
  use std::time::Duration;

  const TEST_TIMEOUT: Duration = Duration::from_secs(2);

  fn assert_same_deadline(expected: &Option<String>, actual: &Option<String>) {
    let expected = DateTime::parse_from_rfc3339(expected.as_deref().expect("expected deadline"))
      .expect("expected RFC3339 deadline");
    let actual = DateTime::parse_from_rfc3339(actual.as_deref().expect("actual deadline"))
      .expect("actual RFC3339 deadline");
    assert!(
      actual
        .signed_duration_since(expected)
        .num_microseconds()
        .unwrap_or(i64::MAX)
        .unsigned_abs()
        <= 1_000,
      "normal live deadline moved: expected {expected}, actual {actual}"
    );
  }

  #[test]
  fn token_worker_does_not_delay_live_worker_start() {
    let rig = RuntimeTestRig::disabled();
    let parse = rig.token.block_next_parse();
    let fetch = rig.live.block_next_fetch();
    let token_ticket = rig.handle.request_manual_token(None).expect("token ticket");
    parse.wait_entered(TEST_TIMEOUT);

    let live_ticket = rig.handle.request_manual_live().expect("live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.token.parse_calls(), 1);
    assert_eq!(rig.live.fetch_calls(), 1);

    fetch.release();
    parse.release();
    assert!(token_ticket.wait().is_ok());
    assert!(live_ticket.wait().is_ok());
    rig.shutdown();
  }

  #[test]
  fn concurrent_live_callers_share_one_executor_generation() {
    let rig = RuntimeTestRig::disabled();
    let fetch = rig.live.block_next_fetch();
    let first = rig.handle.request_manual_live().expect("first live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    let second = rig
      .handle
      .request_manual_live()
      .expect("second live ticket");

    fetch.release();
    let first = first.wait().expect("first live result");
    let second = second.wait().expect("second live result");
    assert!(Arc::ptr_eq(&first, &second));
    assert_eq!(rig.live.fetch_calls(), 1);
    rig.shutdown();
  }

  #[test]
  fn active_live_children_never_exceeds_one() {
    let rig = RuntimeTestRig::disabled();
    let fetch = rig.live.block_next_fetch();
    let first = rig.handle.request_manual_live().expect("first live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    let mut joined = Vec::new();
    for _ in 1..REFRESH_WAITER_CAPACITY {
      joined.push(
        rig
          .handle
          .request_manual_live()
          .expect("joined live ticket"),
      );
    }

    assert_eq!(rig.metrics().live.active_executor_count, 1);
    assert_eq!(rig.live.maximum_active_fetches(), 1);
    fetch.release();
    assert!(first.wait_timeout(TEST_TIMEOUT).is_ok());
    for ticket in joined {
      assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    }
    assert_eq!(rig.metrics().live.active_executor_count, 0);
    assert_eq!(rig.live.maximum_active_fetches(), 1);
    rig.shutdown();
  }

  #[test]
  fn startup_status_is_busy_before_worker_body_runs() {
    let (rig, parse, fetch) = RuntimeTestRig::startup_due_with_pre_body_gates();
    parse.wait_worker_ready(TEST_TIMEOUT);
    fetch.wait_worker_ready(TEST_TIMEOUT);

    let status = rig.handle.status();
    assert!(status.token.running);
    assert!(status.live.running);
    assert_eq!(status.token.generation, Some(1));
    assert_eq!(status.live.generation, Some(1));
    assert_eq!(status.mutation_phase, Some(super::MutationPhase::Parsing));
    assert_eq!(rig.token.parse_calls(), 0, "executor body has not entered");
    assert_eq!(rig.live.fetch_calls(), 0, "executor body has not entered");

    rig.clock.advance(Duration::from_secs(7));
    parse.release();
    fetch.release();
    parse.wait_entered(TEST_TIMEOUT);
    fetch.wait_entered(TEST_TIMEOUT);
    rig.wait_until_idle(TEST_TIMEOUT);
    let metrics = rig.metrics();
    assert!(metrics.token.lane.start_lag_ms > 5_000);
    assert!(metrics.live.lane.start_lag_ms > 5_000);
    assert_eq!(metrics.start_lag_warning_count, 2);
    rig.shutdown();
  }

  #[test]
  fn completion_services_one_pending_follow_up() {
    let rig = RuntimeTestRig::disabled();
    let first_parse = rig.token.block_next_parse();
    let follow_up_parse = rig.token.block_parse_call(2);
    let first = rig
      .handle
      .request_manual_token(None)
      .expect("first token ticket");
    first_parse.wait_entered(TEST_TIMEOUT);
    let follow_up = rig
      .handle
      .request_manual_token(None)
      .expect("follow-up token ticket");
    first_parse.release();

    follow_up_parse.wait_worker_ready(TEST_TIMEOUT);
    assert!(
      first.wait_timeout(TEST_TIMEOUT).is_ok(),
      "first waiter resolves before follow-up body"
    );
    assert_eq!(
      rig.events.trace_prefix(),
      [
        "token_invalidation",
        "token_completion",
        "token_waiter_reply",
        "token_follow_up_start"
      ]
    );
    assert!(rig.current_completion_slots_are_empty());
    follow_up_parse.release();
    assert!(follow_up.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.token.wait_for_parse_calls(2, TEST_TIMEOUT);
    assert_eq!(rig.token.parse_calls(), 2);
    assert_eq!(rig.token.commit_calls(), 2);
    assert!(!rig.handle.status().token.pending);
    rig.shutdown();
  }

  #[test]
  fn successful_token_waiter_receives_exact_scan_result() {
    let rig = RuntimeTestRig::disabled();
    let first_parse = rig.token.block_next_parse();
    let first = rig
      .handle
      .request_manual_token(None)
      .expect("first token ticket");
    first_parse.wait_entered(TEST_TIMEOUT);
    let follow_up_one = rig
      .handle
      .request_manual_token(None)
      .expect("first follow-up ticket");
    let follow_up_two = rig
      .handle
      .request_manual_token(None)
      .expect("second follow-up ticket");
    first_parse.release();

    let first = first
      .wait_timeout(TEST_TIMEOUT)
      .expect("first generation result");
    let follow_up_one = follow_up_one
      .wait_timeout(TEST_TIMEOUT)
      .expect("first follow-up result");
    let follow_up_two = follow_up_two
      .wait_timeout(TEST_TIMEOUT)
      .expect("second follow-up result");
    let produced = rig.token.committed_arc(2, TEST_TIMEOUT);
    assert!(!Arc::ptr_eq(&first, &follow_up_one));
    assert!(Arc::ptr_eq(&follow_up_one, &follow_up_two));
    assert!(Arc::ptr_eq(&follow_up_one, &produced));
    rig.token.assert_result_for_generation(&follow_up_one, 2);
    assert_eq!(rig.token.commit_calls(), 2);
    rig.shutdown();
  }

  #[test]
  fn successful_live_waiters_receive_exact_same_snapshot() {
    let rig = RuntimeTestRig::disabled();
    let fetch = rig.live.block_next_fetch();
    let first = rig.handle.request_manual_live().expect("first live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    let second = rig
      .handle
      .request_manual_live()
      .expect("second live ticket");
    fetch.release();

    let first = first.wait().expect("first snapshot");
    let second = second.wait().expect("second snapshot");
    let produced = rig.live.fetched_arc(1, TEST_TIMEOUT);
    assert!(Arc::ptr_eq(&first, &second));
    assert!(Arc::ptr_eq(&first, &produced));
    assert!(rig.current_completion_slots_are_empty());
    rig.shutdown();
  }

  #[test]
  fn prepared_discard_drops_spool_before_follow_up() {
    let rig = RuntimeTestRig::disabled();
    let parse = rig.token.block_next_spooled_parse_with_drop_probe();
    rig
      .token
      .assert_probe_dropped_before_next_parse(parse.probe());
    let first = rig
      .handle
      .request_manual_token(None)
      .expect("first token ticket");
    parse.wait_entered(TEST_TIMEOUT);
    rig
      .handle
      .update_settings(rig.config_with_source("replacement"))
      .expect("source update");
    parse.release();

    rig.token.wait_for_parse_calls(2, TEST_TIMEOUT);
    parse.wait_dropped(TEST_TIMEOUT);
    assert!(parse.used_spool());
    assert!(rig.token.follow_up_observed_probe_dropped());
    assert!(matches!(
      first.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Failed {
        code: RefreshFailureCode::SourceChanged,
        ..
      })
    ));
    rig.shutdown();
  }

  #[test]
  fn parse_panic_becomes_failure_and_worker_recovers() {
    let rig = RuntimeTestRig::disabled();
    rig.token.panic_once(PanicPhase::Parse);
    let failed = rig
      .handle
      .request_manual_token(None)
      .expect("failed token ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(matches!(
      failed,
      Err(RefreshError::Failed {
        code: RefreshFailureCode::WorkerPanicked,
        ..
      })
    ));
    assert_eq!(
      rig.handle.status().mutation_phase,
      Some(super::MutationPhase::Failed)
    );
    assert!(!rig.handle.status().token.running);

    let recovered = rig
      .handle
      .request_manual_token(None)
      .expect("recovery token ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(recovered.is_ok());
    assert_eq!(rig.token.parse_calls(), 2);
    assert_eq!(rig.token.unique_parse_worker_ids(), 1);
    assert_eq!(rig.token.worker_name(), "codex-pacer-refresh-token");
    assert_eq!(rig.activities.active(), 0);
    rig.shutdown();
  }

  #[test]
  fn commit_panic_becomes_failure_and_worker_recovers() {
    let rig = RuntimeTestRig::disabled();
    rig.token.panic_once(PanicPhase::Commit);
    let failed = rig
      .handle
      .request_manual_token(None)
      .expect("failed token ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(matches!(
      failed,
      Err(RefreshError::Failed {
        code: RefreshFailureCode::WorkerPanicked,
        ..
      })
    ));

    assert!(rig
      .handle
      .request_manual_token(None)
      .expect("recovery token ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    assert_eq!(rig.token.commit_calls(), 2);
    assert_eq!(rig.token.unique_commit_worker_ids(), 1);
    assert_eq!(rig.token.worker_name(), "codex-pacer-refresh-token");
    assert_eq!(rig.activities.active(), 0);
    assert!(rig.mutation_slot_is_free());
    rig.shutdown();
  }

  #[test]
  fn fetch_panic_becomes_failure_and_worker_recovers() {
    let rig = RuntimeTestRig::disabled();
    rig.live.panic_once(PanicPhase::Fetch);
    let failed = rig
      .handle
      .request_manual_live()
      .expect("failed live ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(matches!(
      failed,
      Err(RefreshError::Failed {
        code: RefreshFailureCode::WorkerPanicked,
        ..
      })
    ));

    assert!(rig
      .handle
      .request_manual_live()
      .expect("recovery live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.live.fetch_calls(), 2);
    assert_eq!(rig.live.unique_fetch_worker_ids(), 1);
    assert_eq!(rig.live.worker_name(), "codex-pacer-refresh-live");
    assert_eq!(rig.activities.active(), 0);
    rig.shutdown();
  }

  #[test]
  fn persist_panic_does_not_fail_live_and_retry_recovers() {
    let rig = RuntimeTestRig::disabled();
    rig.live.panic_once(PanicPhase::Persist);
    let result = rig
      .handle
      .request_manual_live()
      .expect("failed live ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(
      result.is_ok(),
      "persistence panic cannot fail fetched live quota"
    );
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.live.fetch_calls(), 1);
    assert_eq!(rig.live.persist_calls(), 1);
    assert_eq!(rig.events.invalidation_count(), 1);

    rig.clock.advance(Duration::from_secs(5));
    rig.handle.wake().expect("wake persistence retry");
    rig.wait_for_persist_outcomes(2, TEST_TIMEOUT);
    assert_eq!(rig.live.persist_calls(), 2);
    assert_eq!(rig.live.fetch_calls(), 1, "retry cannot refetch");
    assert_eq!(rig.activities.active(), 0);
    rig.shutdown();
  }

  #[test]
  fn disabled_scheduler_runs_manual_requests() {
    let rig = RuntimeTestRig::disabled();
    assert!(!rig.handle.status().auto_scan_enabled);

    let token = rig.handle.request_manual_token(None).expect("token ticket");
    let live = rig.handle.request_manual_live().expect("live ticket");
    assert!(token.wait_timeout(TEST_TIMEOUT).is_ok());
    assert!(live.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.token.commit_calls(), 1);
    assert_eq!(rig.live.persist_calls(), 1);
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_runs_one_batch_per_maintenance_dispatch() {
    assert_eq!(super::EPOCH_MAINTENANCE_COMMAND_CAPACITY, 1);
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 1_000,
      complete: false,
    }));
    let first = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );

    first.wait_entered(TEST_TIMEOUT);
    assert_eq!(maintenance.limits(), [1_000]);
    for _ in 0..4 {
      rig.handle.wake().expect("wake gated maintenance");
      rig.handle.barrier().expect("drain wake");
    }
    assert_eq!(maintenance.calls(), 1, "only one bounded batch is active");

    first.release();
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    rig.handle.wake().expect("wake before pacing deadline");
    rig.handle.barrier().expect("drain early wake");
    assert_eq!(maintenance.calls(), 1, "outcome alone cannot chain a batch");
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_progresses_when_auto_scan_is_disabled() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );

    maintenance.wait_for_calls(1, TEST_TIMEOUT);
    assert!(!rig.handle.status().auto_scan_enabled);
    rig.wait_for_maintenance_exit(TEST_TIMEOUT);
    assert_eq!(maintenance.calls(), 1);
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_waits_while_token_or_live_lane_is_busy() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let (rig, parse, fetch) =
      RuntimeTestRig::startup_due_with_pre_body_gates_and_maintenance(Arc::clone(&maintenance));
    parse.wait_worker_ready(TEST_TIMEOUT);
    fetch.wait_worker_ready(TEST_TIMEOUT);
    rig.handle.barrier().expect("observe both busy lanes");
    assert_eq!(maintenance.calls(), 0);

    parse.release();
    rig.token.wait_for_commit_calls(1, TEST_TIMEOUT);
    rig.handle.barrier().expect("observe live lane still busy");
    assert_eq!(maintenance.calls(), 0);

    fetch.release();
    maintenance.wait_for_calls(1, TEST_TIMEOUT);
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_respects_thirty_second_refresh_deadline_guard() {
    let exact = Arc::new(TestEpochMaintenanceExecutor::new());
    let exact_rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::ThirtySecondDeadline,
      Arc::clone(&exact),
    );
    exact_rig.handle.barrier().expect("observe exact deadline");
    assert_eq!(exact.calls(), 0, "exactly thirty seconds is guarded");
    exact_rig.shutdown();

    let beyond = Arc::new(TestEpochMaintenanceExecutor::new());
    beyond.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let beyond_rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::ThirtyOneSecondDeadline,
      Arc::clone(&beyond),
    );
    beyond.wait_for_calls(1, TEST_TIMEOUT);
    beyond_rig.shutdown();
  }

  #[test]
  fn epoch_backfill_incomplete_batches_are_paced_without_busy_loop() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 1_000,
      complete: false,
    }));
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 7,
      complete: true,
    }));
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    rig.handle.wake().expect("wake before two-second pace");
    rig.handle.barrier().expect("drain early wake");
    assert_eq!(maintenance.calls(), 1);

    rig.clock.advance(Duration::from_secs(2));
    rig.handle.wake().expect("wake at pacing deadline");
    maintenance.wait_for_calls(2, TEST_TIMEOUT);
    rig.wait_for_maintenance_exit(TEST_TIMEOUT);
    assert_eq!(maintenance.unique_worker_ids(), 1);
    rig.shutdown();
  }

  #[test]
  fn stale_or_duplicate_epoch_backfill_outcomes_are_ignored() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 1_000,
      complete: false,
    }));
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);

    rig.inject_maintenance_outcome(
      1,
      Ok(EpochMaintenanceBatch::Progress {
        processed_rows: 0,
        complete: true,
      }),
    );
    rig.handle.barrier().expect("drain duplicate outcome");
    rig.clock.advance(Duration::from_secs(2));
    rig.handle.wake().expect("wake next real attempt");

    maintenance.wait_for_calls(2, TEST_TIMEOUT);
    rig.wait_for_maintenance_exit(TEST_TIMEOUT);
    assert_eq!(maintenance.calls(), 2, "duplicate did not complete the repair");
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_failure_uses_backoff_without_hot_loop() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.queue_result(Err("injected maintenance failure".to_string()));
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);

    rig.clock.advance(Duration::from_secs(29));
    rig.handle.wake().expect("wake before retry backoff");
    rig.handle.barrier().expect("drain early retry wake");
    assert_eq!(maintenance.calls(), 1);
    rig.clock.advance(Duration::from_secs(1));
    rig.handle.wake().expect("wake at retry backoff");
    maintenance.wait_for_calls(2, TEST_TIMEOUT);
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_failure_backoff_is_bounded_to_five_minutes() {
    assert_eq!(
      super::epoch_maintenance_retry_delay(1),
      Duration::from_secs(30)
    );
    assert_eq!(
      super::epoch_maintenance_retry_delay(2),
      Duration::from_secs(60)
    );
    assert_eq!(
      super::epoch_maintenance_retry_delay(5),
      Duration::from_secs(5 * 60)
    );
    assert_eq!(
      super::epoch_maintenance_retry_delay(u32::MAX),
      Duration::from_secs(5 * 60)
    );
  }

  #[test]
  fn epoch_backfill_panic_uses_backoff_and_worker_recovers() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    maintenance.panic_batch(1);
    maintenance.queue_result(Ok(EpochMaintenanceBatch::Progress {
      processed_rows: 0,
      complete: true,
    }));
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    assert_eq!(maintenance.calls(), 1);

    rig.clock.advance(Duration::from_secs(30));
    rig.handle.wake().expect("wake after panic backoff");
    maintenance.wait_for_calls(2, TEST_TIMEOUT);
    rig.wait_for_maintenance_exit(TEST_TIMEOUT);
    assert_eq!(maintenance.unique_worker_ids(), 1);
    rig.shutdown();
  }

  #[test]
  fn snapshot_getter_remains_available_while_epoch_backfill_waits() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let gate = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    gate.wait_entered(TEST_TIMEOUT);

    let status = rig.handle.status();
    let metrics = rig.handle.metrics();
    assert!(!status.token.running && !status.live.running);
    assert_eq!(metrics.token.lane.running_generation, None);

    gate.release();
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    rig.shutdown();
  }

  #[test]
  fn refresh_priority_overtakes_queued_epoch_maintenance() {
    let mutation = crate::refresh::UsageMutationCoordinator::new();
    let blocker_mutation = mutation.clone();
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let blocker = thread::spawn(move || {
      blocker_mutation.run(crate::refresh::MutationPriority::Pricing, || {
        entered_tx.send(()).expect("report blocker entry");
        release_rx.recv().expect("release blocker");
      });
    });
    entered_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("pricing blocker owns mutation slot");
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let retry_gate = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance_and_mutation(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
      mutation,
    );
    rig.wait_for_mutation_queue(1, TEST_TIMEOUT);
    let token = rig.handle.request_manual_token(None).expect("token ticket");
    rig.token.wait_until_waiting_to_commit(TEST_TIMEOUT);
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    rig.wait_for_mutation_queue(1, TEST_TIMEOUT);
    assert_eq!(maintenance.calls(), 0, "queued maintenance never enters executor");

    release_tx.send(()).expect("release blocker");
    assert!(token.wait_timeout(TEST_TIMEOUT).is_ok());
    assert_eq!(rig.token.commit_calls(), 1);

    rig.clock.advance(Duration::from_secs(2));
    rig.handle.wake().expect("wake paced maintenance retry");
    retry_gate.wait_entered(TEST_TIMEOUT);
    retry_gate.release();
    blocker.join().expect("blocker exits");
    rig.shutdown();
  }

  #[test]
  fn ready_live_persistence_cancels_epoch_maintenance_then_persists_first() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let first = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    first.wait_entered(TEST_TIMEOUT);

    let live = rig.handle.request_manual_live().expect("live ticket");
    assert!(live.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.handle.barrier().expect("process ready persistence");
    assert!(maintenance.cancellation(1).load(Ordering::Acquire));
    assert_eq!(rig.live.persist_calls(), 0, "persistence waits for batch outcome");

    first.release();
    rig.wait_for_maintenance_outcomes(1, TEST_TIMEOUT);
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.live.persist_calls(), 1);
    assert_eq!(maintenance.calls(), 1, "maintenance retry remains paced");
    rig.shutdown();
  }

  #[test]
  fn epoch_backfill_shutdown_joins_worker_without_followup() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let first = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    first.wait_entered(TEST_TIMEOUT);

    let shutdown = rig.shutdown_in_background();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    assert!(maintenance.cancellation(1).load(Ordering::Acquire));
    assert!(!shutdown.is_finished());
    first.release();

    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.coordinator_joined && joined.token_joined && joined.live_joined);
    assert_eq!(maintenance.calls(), 1);
    assert_eq!(maintenance.unique_worker_ids(), 1);
  }

  #[test]
  fn epoch_backfill_shutdown_drains_saturated_outcome_without_deadlock() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let first = maintenance.block_batch(1);
    let rig = RuntimeTestRig::build_with_maintenance(
      TestRigSchedule::Disabled,
      Arc::clone(&maintenance),
    );
    first.wait_entered(TEST_TIMEOUT);
    let pause = rig.pause_coordinator();
    rig.fill_runtime_channel_until_busy();

    let shutdown = rig.shutdown_in_background();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    first.release();
    pause.release();

    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.coordinator_joined && joined.token_joined && joined.live_joined);
    assert_eq!(maintenance.calls(), 1);
    assert_eq!(maintenance.unique_worker_ids(), 1);
  }

  #[test]
  fn epoch_backfill_shutdown_publish_cancels_attempt_installed_across_race() {
    let maintenance = Arc::new(TestEpochMaintenanceExecutor::new());
    let (rig, before_install, shutdown_gap, between_install_and_send) =
      RuntimeTestRig::build_with_maintenance_shutdown_install_gates(Arc::clone(&maintenance));
    before_install.wait_worker_ready(TEST_TIMEOUT);

    let shutdown = rig.shutdown_in_background();
    shutdown_gap.wait_worker_ready(TEST_TIMEOUT);
    before_install.release();
    between_install_and_send.wait_worker_ready(TEST_TIMEOUT);
    let was_cancelled_before_send = rig.maintenance_cancelled_between_install_and_send();
    between_install_and_send.release();
    shutdown_gap.release();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);

    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.coordinator_joined && joined.token_joined && joined.live_joined);
    assert!(
      was_cancelled_before_send,
      "shutdown is visible and cancels the attempt before its command is sent"
    );
    assert_eq!(maintenance.calls(), 0, "shutdown enters no maintenance executor");
  }

  #[test]
  fn scheduled_start_lag_is_recorded() {
    let rig = RuntimeTestRig::scheduled_overdue(Duration::from_secs(2));
    rig.token.wait_for_parse_calls(1, TEST_TIMEOUT);
    rig.live.wait_for_fetch_calls(1, TEST_TIMEOUT);
    rig.wait_until_idle(TEST_TIMEOUT);

    let metrics = rig.metrics();
    assert!(metrics.token.lane.scheduled_due_at.is_some());
    assert!(metrics.live.lane.scheduled_due_at.is_some());
    assert!(metrics.token.lane.started_at.is_some());
    assert!(metrics.live.lane.started_at.is_some());
    assert!(metrics.token.lane.start_lag_ms >= 1_000);
    assert!(metrics.live.lane.start_lag_ms >= 1_000);
    assert_eq!(metrics.start_lag_histogram.iter().sum::<u64>(), 2);
    assert!(metrics.token.lane.duration_ms > 0);
    assert!(metrics.live.lane.duration_ms > 0);
    assert!(metrics.token.lane.last_success_age_ms.is_some());
    assert!(metrics.live.lane.last_success_age_ms.is_some());
    assert_eq!(metrics.token.lane.failure_streak, 0);
    assert_eq!(metrics.live.lane.failure_streak, 0);
    assert!(metrics.token.lane.retry_at.is_none());
    assert!(metrics.live.lane.retry_at.is_none());
    assert_eq!(metrics.token.lane.running_generation, None);
    assert_eq!(metrics.live.lane.running_generation, None);
    assert_eq!(metrics.token.lane.pending_reasons, 0);
    assert_eq!(metrics.live.lane.pending_reasons, 0);
    assert_eq!(metrics.token.append_fast_path_count, 0);
    assert!(metrics.token.files_visited > 0);
    assert!(metrics.token.bytes_read > 0);
    assert!(metrics.token.full_rebuild_count > 0);
    assert!(metrics.token.commit_wait_ms <= metrics.token.lane.duration_ms);
    assert_eq!(metrics.token.database_busy_count, 0);
    assert_eq!(metrics.live.last_query_timeout_ms, 10_000);
    assert!(metrics.live.app_server_duration_ms > 0);
    assert_eq!(metrics.live.timeout_count, 0);
    assert_eq!(metrics.live.active_executor_count, 0);
    assert_eq!(metrics.live.waiter_count, 0);
    assert!(metrics.live.fallback_age_ms.is_none());
    assert!(rig.handle.status().token.next_due_at.is_some());
    assert!(rig.handle.status().live.next_due_at.is_some());
    rig.shutdown();
  }

  #[test]
  fn start_lag_above_five_seconds_warns() {
    let rig = RuntimeTestRig::scheduled_overdue(Duration::from_secs(7));
    rig.token.wait_for_parse_calls(1, TEST_TIMEOUT);
    rig.live.wait_for_fetch_calls(1, TEST_TIMEOUT);
    rig.wait_until_idle(TEST_TIMEOUT);

    let metrics = rig.metrics();
    assert!(metrics.token.lane.start_lag_ms > 5_000);
    assert!(metrics.live.lane.start_lag_ms > 5_000);
    assert_eq!(metrics.start_lag_warning_count, 2);
    rig.shutdown();
  }

  #[test]
  fn resume_starts_overdue_lanes_within_five_seconds() {
    let rig = RuntimeTestRig::paused_clock();
    rig.clock.advance(Duration::from_secs(61));
    rig.handle.wake().expect("wake command");
    rig.token.wait_for_parse_calls(1, TEST_TIMEOUT);
    rig.live.wait_for_fetch_calls(1, TEST_TIMEOUT);

    let metrics = rig.metrics();
    assert!(metrics.token.lane.start_lag_ms <= 5_000);
    assert!(metrics.live.lane.start_lag_ms <= 5_000);
    rig.wait_until_idle(TEST_TIMEOUT);
    rig.shutdown();
  }

  #[test]
  fn token_parse_runs_before_usage_commit_lock() {
    let rig = RuntimeTestRig::disabled();
    let mutation = rig.hold_mutation_slot();
    let parse = rig.token.block_next_parse();
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");

    parse.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.token.parse_calls(), 1);
    assert_eq!(rig.token.commit_calls(), 0);
    parse.release();
    mutation.wait_until_refresh_queued(TEST_TIMEOUT);
    assert_eq!(rig.token.commit_calls(), 0);
    mutation.release();
    assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.shutdown();
  }

  #[test]
  fn held_usage_commit_lock_does_not_delay_live_lane() {
    let rig = RuntimeTestRig::disabled();
    let mutation = rig.hold_mutation_slot();
    let token = rig.handle.request_manual_token(None).expect("token ticket");
    mutation.wait_until_refresh_queued(TEST_TIMEOUT);

    let fetch = rig.live.block_next_fetch();
    let live = rig.handle.request_manual_live().expect("live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.live.fetch_calls(), 1);
    assert_eq!(rig.token.commit_calls(), 0);
    fetch.release();
    assert!(live.wait_timeout(TEST_TIMEOUT).is_ok());

    mutation.release();
    assert!(token.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.shutdown();
  }

  #[test]
  fn source_change_while_waiting_skips_token_commit() {
    let rig = RuntimeTestRig::disabled();
    let mutation = rig.hold_mutation_slot();
    let old = rig.token.use_spooled_prepared_for_next_parse();
    let replacement = rig.token.block_parse_call(2);
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");
    mutation.wait_until_refresh_queued(TEST_TIMEOUT);
    rig
      .handle
      .update_settings(rig.config_with_source("replacement"))
      .expect("source update");

    mutation.release();
    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Failed {
        code: RefreshFailureCode::SourceChanged,
        ..
      })
    ));
    assert_eq!(rig.token.commit_calls(), 0);
    old.wait_dropped(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 0);
    replacement.wait_worker_ready(TEST_TIMEOUT);
    replacement.release();
    rig.token.wait_for_commit_calls(1, TEST_TIMEOUT);
    assert_eq!(rig.token.commit_calls_for_source("replacement"), 1);
    rig.shutdown();
  }

  #[test]
  fn missing_or_mismatched_prepared_slot_fails_without_hang() {
    let rig = RuntimeTestRig::disabled();
    rig.token.omit_prepared_payload_once();
    let missing = rig
      .handle
      .request_manual_token(None)
      .expect("missing token ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(matches!(
      missing,
      Err(RefreshError::Failed {
        code: RefreshFailureCode::PreparedPayloadMissing,
        ..
      })
    ));
    assert!(!rig.handle.status().token.running);

    rig.token.return_mismatched_prepared_once();
    let malformed = rig
      .handle
      .request_manual_token(None)
      .expect("malformed token ticket")
      .wait_timeout(TEST_TIMEOUT);
    assert!(matches!(
      malformed,
      Err(RefreshError::Failed {
        code: RefreshFailureCode::PreparedPayloadMissing,
        ..
      })
    ));
    assert!(!rig.handle.status().token.running);

    assert!(rig
      .handle
      .request_manual_token(None)
      .expect("recovery token ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    assert_eq!(rig.token.commit_calls(), 1);
    rig.shutdown();
  }

  #[test]
  fn duplicate_worker_outcome_is_ignored() {
    let rig = RuntimeTestRig::disabled();
    let first = rig
      .handle
      .request_manual_token(None)
      .expect("token ticket")
      .wait_timeout(TEST_TIMEOUT)
      .expect("token result");
    let completions = rig.events.completion_count();
    rig.inject_duplicate_prepared_after_take(1);
    rig.inject_duplicate_token_completion(1, Arc::clone(&first));
    let next_parse = rig.token.block_parse_call(2);
    let next = rig
      .handle
      .request_manual_token(None)
      .expect("next token ticket");
    next_parse.wait_worker_ready(TEST_TIMEOUT);
    rig.inject_duplicate_token_completion(1, Arc::clone(&first));
    rig.handle.barrier().expect("coordinator barrier");

    assert_eq!(rig.events.completion_count(), completions);
    assert_eq!(rig.handle.status().token.generation, Some(2));
    next_parse.release();
    assert!(next.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.shutdown();
  }

  #[test]
  fn waiter_and_command_capacity_are_bounded() {
    let rig = RuntimeTestRig::disabled();
    let fetch = rig.live.block_next_fetch();
    let mut tickets = Vec::new();
    tickets.push(rig.handle.request_manual_live().expect("first live ticket"));
    fetch.wait_entered(TEST_TIMEOUT);
    for _ in 1..REFRESH_WAITER_CAPACITY {
      tickets.push(
        rig
          .handle
          .request_manual_live()
          .expect("bounded live ticket"),
      );
    }
    assert!(matches!(
      rig.handle.request_manual_live(),
      Err(RefreshError::Busy)
    ));
    assert_eq!(
      rig.metrics().live.waiter_count,
      REFRESH_WAITER_CAPACITY as u64
    );

    let parse = rig.token.block_next_parse();
    let active_token = rig
      .handle
      .request_manual_token(None)
      .expect("active token ticket");
    parse.wait_entered(TEST_TIMEOUT);
    let mut token_tickets = Vec::new();
    for _ in 1..REFRESH_WAITER_CAPACITY {
      match rig.handle.request_manual_token(None) {
        Ok(ticket) => token_tickets.push(ticket),
        Err(RefreshError::Busy) => break,
        Err(error) => panic!("unexpected token capacity error: {error:?}"),
      }
    }
    assert_eq!(token_tickets.len(), REFRESH_WAITER_CAPACITY - 1);
    assert!(matches!(
      rig.handle.request_manual_token(None),
      Err(RefreshError::Busy)
    ));
    assert_eq!(rig.token_schedule_waiter_count(), REFRESH_WAITER_CAPACITY);

    let pause = rig.pause_coordinator();
    for _ in 0..super::RUNTIME_COMMAND_CAPACITY {
      rig.handle.try_wake().expect("bounded command slot");
    }
    assert!(matches!(rig.handle.try_wake(), Err(RefreshError::Busy)));
    pause.release();

    fetch.release();
    for ticket in tickets {
      assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    }
    parse.release();
    assert!(active_token.wait_timeout(TEST_TIMEOUT).is_ok());
    for ticket in token_tickets {
      assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    }
    assert!(
      rig.handle.request_manual_live().is_ok(),
      "live capacity recovers"
    );
    assert!(
      rig.handle.request_manual_token(None).is_ok(),
      "token capacity recovers"
    );
    rig.shutdown();
  }

  #[test]
  fn settings_update_waits_for_saturated_queue_and_is_not_lost() {
    let rig = RuntimeTestRig::disabled();
    let pause = rig.pause_coordinator();
    rig.fill_runtime_channel_until_busy();
    let mut replacement = rig.config_with_source("replacement");
    replacement.auto_scan_enabled = true;
    let handle = rig.handle.clone();
    let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
    let update = std::thread::spawn(move || {
      let _ = result_tx.send(handle.update_settings(replacement));
    });

    rig.wait_for_reliable_in_flight(1, TEST_TIMEOUT);
    assert_eq!(rig.handle.try_wake(), Err(RefreshError::Busy));
    assert!(matches!(
      rig.handle.request_manual_token(None),
      Err(RefreshError::Busy)
    ));
    assert!(matches!(
      rig.handle.request_manual_live(),
      Err(RefreshError::Busy)
    ));
    let shutdown = rig.shutdown_in_background();
    rig.wait_for_intake_closed(TEST_TIMEOUT);
    assert!(
      !rig
        .runtime
        .lifecycle
        .shutdown_requested
        .load(std::sync::atomic::Ordering::Acquire),
      "shutdown waits for the accepted settings update to finish"
    );
    assert!(matches!(
      rig
        .handle
        .update_settings(rig.config_with_source("rejected-after-shutdown")),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    pause.release();
    let result = result_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("settings update is acknowledged after capacity recovers");
    update.join().expect("settings update thread exits");
    let joined = shutdown.wait(TEST_TIMEOUT);

    assert_eq!(result, Ok(()));
    assert!(joined.coordinator_joined && joined.token_joined && joined.live_joined);
    assert_eq!(
      super::lock(&rig.handle.inner.intake).reliable_in_flight,
      0
    );
    let status = rig.handle.status();
    assert_eq!(status.source_generation, 1);
    assert!(status.auto_scan_enabled);
  }

  #[test]
  fn fixed_counters_saturate_without_wrap() {
    let counter = SaturatingCounter::new(u64::MAX - 1);
    counter.increment();
    counter.increment();
    assert_eq!(counter.load(), u64::MAX);

    let rig = RuntimeTestRig::disabled();
    rig.metrics_handle.set_warning_count_for_test(u64::MAX - 1);
    rig
      .metrics_handle
      .set_start_lag_bucket_for_test(super::HISTOGRAM_BUCKETS - 2, u64::MAX - 1);
    rig.metrics_handle.record_start_lag(Duration::from_secs(6));
    rig.metrics_handle.record_start_lag(Duration::from_secs(6));
    let metrics = rig.metrics();
    assert_eq!(metrics.start_lag_warning_count, u64::MAX);
    assert_eq!(metrics.start_lag_histogram.len(), super::HISTOGRAM_BUCKETS);
    assert_eq!(
      metrics.start_lag_histogram[super::HISTOGRAM_BUCKETS - 2],
      u64::MAX
    );
    rig.shutdown();
  }

  #[test]
  fn prepared_token_refresh_constructor_initializes_test_defaults() {
    let rig = RuntimeTestRig::disabled();
    let (seed, _) = rig.token.make_prepared_for_test(1, 0, false);
    let super::PreparedTokenRefresh { prepared_scan, .. } = seed;
    let started_at = rig.clock.wall_now();

    let prepared = PreparedTokenRefresh::new(7, 3, started_at, prepared_scan);

    assert_eq!(prepared.generation, 7);
    assert_eq!(prepared.source_generation, 3);
    assert_eq!(prepared.started_at, started_at);
    assert!(!prepared.omit_payload_for_test());
    assert!(prepared.drop_probe.is_none());
    rig.shutdown();
  }

  #[test]
  fn coordinator_shutdown_resolves_waiters() {
    let rig = RuntimeTestRig::disabled();
    let parse = rig.token.block_next_parse();
    let fetch = rig.live.block_next_fetch();
    let token = rig.handle.request_manual_token(None).expect("token ticket");
    let live = rig.handle.request_manual_live().expect("live ticket");
    parse.wait_entered(TEST_TIMEOUT);
    fetch.wait_entered(TEST_TIMEOUT);

    let pause = rig.pause_coordinator();
    for _ in 0..(super::RUNTIME_COMMAND_CAPACITY - 1) {
      rig.handle.try_wake().expect("reserve final command slot");
    }
    let race = rig.start_intake_race_after_accept_check();
    race.wait_checked(TEST_TIMEOUT);
    let shutdown = rig.shutdown_in_background();
    race.release();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    parse.release();
    fetch.release();
    pause.release();
    assert!(matches!(
      token.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    assert!(matches!(
      live.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    assert!(matches!(
      rig.handle.request_manual_live(),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    assert!(matches!(
      race.wait_result(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.coordinator_joined && joined.token_joined && joined.live_joined);
  }

  #[test]
  fn shutdown_during_parse_wait_drops_prepared() {
    let rig = RuntimeTestRig::disabled();
    let parse = rig.token.block_next_spooled_parse_with_drop_probe();
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");
    parse.wait_entered(TEST_TIMEOUT);
    let shutdown = rig.shutdown_in_background();
    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));

    parse.release();
    parse.wait_dropped(TEST_TIMEOUT);
    assert!(parse.used_spool());
    shutdown.wait(TEST_TIMEOUT);
    assert_eq!(rig.token.commit_calls(), 0);
  }

  #[test]
  fn shutdown_with_prepared_slot_drops_spool() {
    let rig = RuntimeTestRig::disabled();
    let prepared = rig.install_spooled_prepared_slot_via_coordinator();
    assert!(prepared.used_spool());

    let shutdown = rig.runtime.shutdown_and_join().expect("shutdown");
    prepared.wait_dropped(TEST_TIMEOUT);
    assert!(shutdown.token_joined && shutdown.live_joined && shutdown.coordinator_joined);
    assert!(rig.prepared_slot_is_empty_via_coordinator());
  }

  #[test]
  fn shutdown_during_commit_queue_skips_commit_and_joins() {
    let rig = RuntimeTestRig::disabled();
    let mutation = rig.hold_mutation_slot();
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");
    rig.token.wait_for_parse_calls(1, TEST_TIMEOUT);
    mutation.wait_until_refresh_queued(TEST_TIMEOUT);

    let shutdown = rig.shutdown_in_background();
    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    mutation.release();
    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.token_joined && joined.live_joined && joined.coordinator_joined);
    assert_eq!(rig.token.commit_calls(), 0);
  }

  #[test]
  fn shutdown_is_idempotent_and_joins_all_threads() {
    let rig = RuntimeTestRig::disabled();
    let first = rig.runtime.shutdown_and_join().expect("first shutdown");
    let second = rig.runtime.shutdown_and_join().expect("second shutdown");

    assert!(Arc::ptr_eq(&first, &second));
    assert!(first.token_joined && first.live_joined && first.coordinator_joined);
    assert_eq!(
      rig.thread_names(),
      [
        "codex-pacer-refresh-coordinator",
        "codex-pacer-refresh-live",
        "codex-pacer-refresh-token",
      ]
    );
  }

  #[test]
  fn shutdown_drains_saturated_channel_and_joins_persistence_task() {
    let rig = RuntimeTestRig::disabled();
    let persist = rig.live.block_next_persist();
    let ticket = rig.handle.request_manual_live().expect("live ticket");
    persist.wait_entered(TEST_TIMEOUT);
    assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());

    let pause = rig.pause_coordinator();
    rig.fill_runtime_channel_until_busy();
    let shutdown = rig.shutdown_in_background();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    persist.release();
    pause.release();

    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.token_joined && joined.live_joined && joined.coordinator_joined);
    assert_eq!(rig.activities.active(), 0);
    assert!(!rig.live_cache.state().refreshing);
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
  }

  #[test]
  fn shutdown_during_live_fetch_joins_after_bounded_completion() {
    let rig = RuntimeTestRig::disabled();
    let fetch = rig.live.block_next_fetch();
    let ticket = rig.handle.request_manual_live().expect("live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    assert_eq!(
      rig.live.last_timeout(),
      Some(crate::refresh::LIVE_QUERY_TIMEOUT)
    );

    let shutdown = rig.shutdown_in_background();
    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Rejected {
        code: RefreshRejectionCode::Shutdown,
        ..
      })
    ));
    assert!(
      !shutdown.is_finished(),
      "join waits for bounded in-flight fetch"
    );
    fetch.release();
    let joined = shutdown.wait(TEST_TIMEOUT);
    assert!(joined.live_joined && joined.token_joined && joined.coordinator_joined);
    assert_eq!(rig.live.persist_calls(), 0);
  }

  #[test]
  fn source_change_during_commit_is_not_published_as_success() {
    let rig = RuntimeTestRig::disabled();
    let commit = rig.token.block_next_commit();
    let replacement = rig.token.block_parse_call(2);
    let previous_success = rig.handle.status().token.last_success_at;
    let invalidations = rig.events.invalidation_count();
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");
    commit.wait_entered(TEST_TIMEOUT);
    rig
      .handle
      .update_settings(rig.config_with_source("replacement"))
      .expect("source update during commit");
    commit.release();

    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Failed {
        code: RefreshFailureCode::SourceChanged,
        ..
      })
    ));
    replacement.wait_worker_ready(TEST_TIMEOUT);
    assert_eq!(rig.events.invalidation_count(), invalidations);
    assert_eq!(rig.handle.status().token.last_success_at, previous_success);
    let shutdown = rig.shutdown_in_background();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    replacement.release();
    shutdown.wait(TEST_TIMEOUT);
  }

  #[test]
  fn stale_persist_outcome_does_not_clear_newer_pending_snapshot() {
    let rig = RuntimeTestRig::disabled();
    let persist = rig.live.block_next_persist();
    let replacement = rig.token.block_parse_call(1);
    let invalidations = rig.events.invalidation_count();
    let ticket = rig.handle.request_manual_live().expect("live ticket");
    persist.wait_entered(TEST_TIMEOUT);
    assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    assert_eq!(rig.events.invalidation_count(), invalidations + 1);
    rig
      .handle
      .update_settings(rig.config_with_source("replacement"))
      .expect("source update during persistence");
    replacement.wait_worker_ready(TEST_TIMEOUT);

    let newer = TestLiveExecutor::snapshot_at("2026-07-11T00:02:00Z");
    rig.live.queue_snapshot(Arc::clone(&newer));
    let latest = rig
      .handle
      .request_manual_live()
      .expect("new-source live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .expect("new-source live result");
    assert_eq!(latest.fetched_at, newer.fetched_at);
    persist.release();
    rig.wait_for_persist_outcomes(2, TEST_TIMEOUT);
    assert_eq!(rig.events.invalidation_count(), invalidations + 2);
    assert_eq!(rig.live.persist_calls(), 2);
    assert_eq!(
      rig.live.persisted_fetched_at(),
      ["2026-07-11T00:00:00Z", "2026-07-11T00:02:00Z"]
    );
    let shutdown = rig.shutdown_in_background();
    rig.wait_for_shutdown_requested(TEST_TIMEOUT);
    replacement.release();
    shutdown.wait(TEST_TIMEOUT);
  }

  #[test]
  fn persisted_success_age_survives_short_monotonic_uptime() {
    let clock = TestClock::new();
    let success = clock.wall_now() - ChronoDuration::hours(24);
    let config = RefreshConfig {
      auto_scan_enabled: false,
      interval: Duration::from_secs(60),
      codex_home: None,
      token_last_success_wall: Some(success),
      live_last_success_wall: Some(success),
    };
    let status = RefreshStatus::new(&config);
    assert_eq!(status.token.last_success_at, Some(success.to_rfc3339()));
    assert_eq!(status.live.last_success_at, Some(success.to_rfc3339()));
    let metrics = MetricsState::new(&config, &clock);
    let first = metrics.snapshot(0, clock.monotonic_now());
    assert!(first.token.lane.last_success_age_ms.unwrap() >= 86_400_000);
    clock.advance(Duration::from_secs(2));
    let second = metrics.snapshot(0, clock.monotonic_now());
    assert!(
      second.token.lane.last_success_age_ms.unwrap()
        >= first.token.lane.last_success_age_ms.unwrap() + 2_000
    );
  }

  #[test]
  fn extreme_interval_status_timestamp_is_clamped_without_panic() {
    let rig = RuntimeTestRig::huge_interval();
    let status = rig.handle.status();
    assert!(status.token.next_due_at.is_some());
    assert!(status.live.next_due_at.is_some());
    DateTime::parse_from_rfc3339(status.token.next_due_at.as_deref().unwrap())
      .expect("clamped token deadline is RFC3339");
    DateTime::parse_from_rfc3339(status.live.next_due_at.as_deref().unwrap())
      .expect("clamped live deadline is RFC3339");
    rig.shutdown();
  }

  #[test]
  fn activity_guard_excludes_wait_and_queue_time() {
    let rig = RuntimeTestRig::disabled();
    assert_eq!(rig.activities.active(), 0, "idle coordinator owns no guard");
    let mutation = rig.hold_mutation_slot();
    let parse = rig.token.block_next_parse();
    let commit = rig.token.block_next_commit();
    let ticket = rig.handle.request_manual_token(None).expect("token ticket");

    parse.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 1, "parse body owns one guard");
    parse.release();
    mutation.wait_until_refresh_queued(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 0, "mutation wait owns no guard");

    mutation.release();
    commit.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 1, "commit body owns one guard");
    commit.release();
    assert!(ticket.wait_timeout(TEST_TIMEOUT).is_ok());
    assert_eq!(rig.activities.active(), 0);

    let fetch = rig.live.block_next_fetch();
    let persist = rig.live.block_next_persist();
    let live = rig.handle.request_manual_live().expect("live ticket");
    fetch.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 1, "fetch body owns one guard");
    fetch.release();
    persist.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 1, "persist body owns one guard");
    persist.release();
    assert!(live.wait_timeout(TEST_TIMEOUT).is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.activities.active(), 0);
    rig.shutdown();
  }

  #[test]
  fn fresh_value_is_visible_before_persistence_finishes() {
    let rig = RuntimeTestRig::disabled();
    let persist = rig.live.block_next_persist();
    let ticket = rig.handle.request_manual_live().expect("live ticket");
    persist.wait_entered(TEST_TIMEOUT);

    let result = ticket
      .wait_timeout(TEST_TIMEOUT)
      .expect("waiter resolves before persistence finishes");
    let produced = rig.live.fetched_arc(1, TEST_TIMEOUT);
    let cached = rig.live_cache.rate_limits().expect("published live cache");
    assert!(Arc::ptr_eq(&result, &produced));
    assert!(Arc::ptr_eq(&result, &cached));
    assert_eq!(
      rig.events.trace_prefix(),
      [
        "live_cache_publish",
        "live_invalidation",
        "live_completion",
        "live_waiter_reply",
        "live_persist_start",
      ]
    );

    persist.release();
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    rig.shutdown();
  }

  #[test]
  fn fetch_receives_ten_second_timeout() {
    let rig = RuntimeTestRig::disabled();
    assert!(rig
      .handle
      .request_manual_live()
      .expect("live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    assert_eq!(
      rig.live.last_timeout(),
      Some(crate::refresh::LIVE_QUERY_TIMEOUT)
    );
    assert_eq!(rig.live.last_timeout(), Some(Duration::from_secs(10)));
    rig.shutdown();
  }

  #[test]
  fn live_failure_does_not_run_token_inline() {
    let rig = RuntimeTestRig::paused_clock();
    let fallback = TestLiveExecutor::snapshot_at("2026-07-10T23:59:00Z");
    rig
      .live
      .fail_next_fetch_with_fallback(Arc::clone(&fallback));
    let parse = rig.token.block_next_parse();
    let ticket = rig.handle.request_manual_live().expect("live ticket");

    assert!(matches!(
      ticket.wait_timeout(TEST_TIMEOUT),
      Err(RefreshError::Failed {
        code: RefreshFailureCode::ExecutionFailed,
        ..
      })
    ));
    parse.wait_entered(TEST_TIMEOUT);
    assert_eq!(rig.live.fallback_calls(), 1);
    assert!(rig.live_cache.state().is_fallback);
    assert_eq!(
      rig.events.trace_prefix(),
      [
        "live_cache_fallback",
        "live_completion",
        "live_waiter_reply",
        "token_fallback_start",
      ]
    );

    parse.release();
    rig.token.wait_for_commit_calls(1, TEST_TIMEOUT);
    rig.shutdown();

    let no_fallback = RuntimeTestRig::paused_clock();
    no_fallback.live.fail_next_fetch();
    let parse = no_fallback.token.block_next_parse();
    let ticket = no_fallback
      .handle
      .request_manual_live()
      .expect("live ticket without fallback");
    assert!(ticket.wait_timeout(TEST_TIMEOUT).is_err());
    parse.wait_entered(TEST_TIMEOUT);
    assert_eq!(
      no_fallback.events.trace_prefix(),
      [
        "live_completion",
        "live_waiter_reply",
        "token_fallback_start",
      ]
    );
    parse.release();
    no_fallback.token.wait_for_commit_calls(1, TEST_TIMEOUT);
    no_fallback.shutdown();
  }

  #[test]
  fn persistence_failure_retries_without_refetch() {
    let rig = RuntimeTestRig::disabled();
    rig.live.fail_next_persist();
    assert!(rig
      .handle
      .request_manual_live()
      .expect("live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_eq!(rig.live.fetch_calls(), 1);
    assert_eq!(rig.live.persist_calls(), 1);

    rig.clock.advance(Duration::from_secs(5));
    rig.handle.wake().expect("wake persistence retry");
    rig.live.wait_for_persist_calls(2, TEST_TIMEOUT);
    rig.wait_for_persist_outcomes(2, TEST_TIMEOUT);
    assert_eq!(rig.live.fetch_calls(), 1, "retry must not refetch");
    assert_eq!(rig.live.persist_calls(), 2);
    rig.shutdown();
  }

  #[test]
  fn newer_live_snapshot_supersedes_pending_persistence_retry() {
    let rig = RuntimeTestRig::disabled();
    rig.live.fail_next_persist();
    assert!(rig
      .handle
      .request_manual_live()
      .expect("first live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);

    let newer = TestLiveExecutor::snapshot_at("2026-07-11T00:01:00Z");
    rig.live.queue_snapshot(Arc::clone(&newer));
    let second = rig
      .handle
      .request_manual_live()
      .expect("second live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .expect("second live result");
    assert_eq!(second.fetched_at, newer.fetched_at);
    rig.wait_for_persist_outcomes(2, TEST_TIMEOUT);
    assert_eq!(
      rig.live.persisted_fetched_at(),
      ["2026-07-11T00:00:00Z", "2026-07-11T00:01:00Z"]
    );

    rig.clock.advance(Duration::from_secs(5));
    rig.handle.wake().expect("wake past superseded retry");
    rig.handle.barrier().expect("drain wake");
    assert_eq!(rig.live.persist_calls(), 2, "old retry stays superseded");
    rig.shutdown();
  }

  #[test]
  fn persistence_retry_does_not_move_live_deadline() {
    let rig = RuntimeTestRig::disabled();
    let initial_deadline = rig.handle.status().live.next_due_at;
    rig.live.fail_next_persist();
    assert!(rig
      .handle
      .request_manual_live()
      .expect("live ticket")
      .wait_timeout(TEST_TIMEOUT)
      .is_ok());
    rig.wait_for_persist_outcomes(1, TEST_TIMEOUT);
    assert_same_deadline(&initial_deadline, &rig.handle.status().live.next_due_at);

    rig.clock.advance(Duration::from_secs(5));
    rig.handle.wake().expect("wake persistence retry");
    rig.wait_for_persist_outcomes(2, TEST_TIMEOUT);
    assert_same_deadline(&initial_deadline, &rig.handle.status().live.next_due_at);
    assert_eq!(rig.live.fetch_calls(), 1);
    rig.shutdown();
  }
}
use super::power::{ActivityFactory, SystemActivityFactory};
use super::{
  CommitMarker, CoordinatorAction, CoordinatorEvent, CoordinatorState, DisplayInvalidation,
  ExecutionCompletion, LiveExecutionRequest, LivePersistenceRetryState, LivePersistenceWork,
  LiveQuotaCache, LiveRequest, LiveWaiterId, MutationPriority, RefreshCompletedEvent,
  RefreshConfig, RefreshDetail, RefreshFailureCode, RefreshReason, RefreshRejectionCode,
  RefreshWaiterOutcome, TokenExecutionRequest, TokenRequest, TokenWaiterId,
  UsageMutationCoordinator, LIVE_QUERY_TIMEOUT, REFRESH_WAITER_CAPACITY,
};
use crate::importer::{PreparedScan, PreparedScanStats};
use crate::models::{LiveRateLimitSnapshot, ScanResult};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use std::array;
use std::collections::HashMap;
#[cfg(test)]
use std::collections::VecDeque;
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvError, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub(crate) const RUNTIME_COMMAND_CAPACITY: usize = REFRESH_WAITER_CAPACITY;
const WORKER_COMMAND_CAPACITY: usize = 1;
pub(crate) const EPOCH_MAINTENANCE_COMMAND_CAPACITY: usize = 1;
const EPOCH_MAINTENANCE_STACK_SIZE: usize = 512 * 1024;
const EPOCH_MAINTENANCE_BATCH_SIZE: usize = 1_000;
const EPOCH_MAINTENANCE_PACE: Duration = Duration::from_secs(2);
const EPOCH_MAINTENANCE_DEADLINE_GUARD: Duration = Duration::from_secs(30);
const EPOCH_MAINTENANCE_RETRY_BASE: Duration = Duration::from_secs(30);
const EPOCH_MAINTENANCE_RETRY_MAX: Duration = Duration::from_secs(5 * 60);
pub(crate) const HISTOGRAM_BUCKETS: usize = 8;
const START_LAG_WARNING: Duration = Duration::from_secs(5);
const HISTOGRAM_UPPER_BOUNDS_MS: [u64; HISTOGRAM_BUCKETS] =
  [0, 10, 100, 500, 1_000, 5_000, 30_000, u64::MAX];

pub(crate) trait TokenRefreshExecutor: Send + Sync {
  fn parse(&self, request: TokenExecutionRequest) -> Result<PreparedTokenRefresh, String>;
  fn commit(&self, prepared: PreparedTokenRefresh) -> Result<ScanResult, String>;
}

pub(crate) struct PreparedTokenRefresh {
  pub generation: u64,
  pub source_generation: u64,
  pub started_at: DateTime<Utc>,
  pub prepared_scan: PreparedScan,
  #[cfg(test)]
  drop_probe: Option<TestPreparedDropProbe>,
  #[cfg(test)]
  omit_payload: bool,
}

impl PreparedTokenRefresh {
  pub(crate) fn new(
    generation: u64,
    source_generation: u64,
    started_at: DateTime<Utc>,
    prepared_scan: PreparedScan,
  ) -> Self {
    Self {
      generation,
      source_generation,
      started_at,
      prepared_scan,
      #[cfg(test)]
      drop_probe: None,
      #[cfg(test)]
      omit_payload: false,
    }
  }
}

pub(crate) trait LiveQuotaFetcher: Send + Sync {
  fn fetch(&self, timeout: Duration) -> Result<LiveRateLimitSnapshot, String>;

  fn fallback(&self) -> Option<LiveRateLimitSnapshot> {
    None
  }
}

pub(crate) trait LiveQuotaPersister: Send + Sync {
  fn persist(&self, snapshot: &LiveRateLimitSnapshot) -> Result<(), String>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EpochMaintenanceBatch {
  Progress {
    processed_rows: usize,
    complete: bool,
  },
  Cancelled,
}

pub(crate) trait EpochMaintenanceExecutor: Send + Sync {
  fn run_batch(
    &self,
    limit: usize,
    cancellation: Arc<AtomicBool>,
  ) -> Result<EpochMaintenanceBatch, String>;
}

pub(crate) trait RefreshEventSink: Send + Sync {
  fn publish_invalidation(&self, value: DisplayInvalidation);
  fn publish_completion(&self, value: RefreshCompletedEvent);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MutationPhase {
  Queued,
  Parsing,
  WaitingToCommit,
  Committed,
  Failed,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LaneStatus {
  pub running: bool,
  pub generation: Option<u64>,
  pub pending: bool,
  pub last_success_at: Option<String>,
  pub next_due_at: Option<String>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshStatus {
  pub token: LaneStatus,
  pub live: LaneStatus,
  pub mutation_phase: Option<MutationPhase>,
  pub source_generation: u64,
  pub auto_scan_enabled: bool,
}

impl RefreshStatus {
  fn new(config: &RefreshConfig) -> Self {
    let token = LaneStatus {
      running: false,
      generation: None,
      pending: false,
      last_success_at: config
        .token_last_success_wall
        .map(|value| value.to_rfc3339()),
      next_due_at: None,
    };
    let live = LaneStatus {
      last_success_at: config
        .live_last_success_wall
        .map(|value| value.to_rfc3339()),
      ..token.clone()
    };
    Self {
      token,
      live,
      mutation_phase: None,
      source_generation: 0,
      auto_scan_enabled: config.auto_scan_enabled,
    }
  }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct RefreshLaneMetrics {
  pub scheduled_due_at: Option<String>,
  pub started_at: Option<String>,
  pub start_lag_ms: u64,
  pub duration_ms: u64,
  pub last_success_age_ms: Option<u64>,
  pub failure_streak: u32,
  pub retry_at: Option<String>,
  pub missed_deadline_count: u64,
  pub coalesced_trigger_count: u64,
  pub running_generation: Option<u64>,
  pub pending_reasons: u8,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct TokenRefreshMetrics {
  pub lane: RefreshLaneMetrics,
  pub files_visited: u64,
  pub bytes_read: u64,
  pub append_fast_path_count: u64,
  pub full_rebuild_count: u64,
  pub commit_wait_ms: u64,
  pub database_busy_count: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct LiveRefreshMetrics {
  pub lane: RefreshLaneMetrics,
  pub app_server_duration_ms: u64,
  pub last_query_timeout_ms: u64,
  pub timeout_count: u64,
  pub active_executor_count: u64,
  pub waiter_count: u64,
  pub fallback_age_ms: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RefreshMetricsSnapshot {
  pub token: TokenRefreshMetrics,
  pub live: LiveRefreshMetrics,
  pub start_lag_warning_count: u64,
  pub active_live_warning_count: u64,
  pub start_lag_histogram: [u64; HISTOGRAM_BUCKETS],
  pub duration_histogram: [u64; HISTOGRAM_BUCKETS],
}

#[derive(Debug)]
pub(crate) struct SaturatingCounter(AtomicU64);

impl SaturatingCounter {
  pub(crate) const fn new(value: u64) -> Self {
    Self(AtomicU64::new(value))
  }

  pub(crate) fn increment(&self) -> u64 {
    self.add(1)
  }

  pub(crate) fn add(&self, amount: u64) -> u64 {
    let mut current = self.0.load(Ordering::Acquire);
    loop {
      let next = current.saturating_add(amount);
      match self
        .0
        .compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire)
      {
        Ok(_) => return next,
        Err(observed) => current = observed,
      }
    }
  }

  pub(crate) fn load(&self) -> u64 {
    self.0.load(Ordering::Acquire)
  }

  #[cfg(test)]
  fn store(&self, value: u64) {
    self.0.store(value, Ordering::Release);
  }
}

struct FixedHistogram {
  buckets: [SaturatingCounter; HISTOGRAM_BUCKETS],
}

impl FixedHistogram {
  fn new() -> Self {
    Self {
      buckets: array::from_fn(|_| SaturatingCounter::new(0)),
    }
  }

  fn record(&self, duration: Duration) {
    let value = duration_as_millis(duration);
    let index = HISTOGRAM_UPPER_BOUNDS_MS
      .iter()
      .position(|upper| value <= *upper)
      .unwrap_or(HISTOGRAM_BUCKETS - 1);
    self.buckets[index].increment();
  }

  fn snapshot(&self) -> [u64; HISTOGRAM_BUCKETS] {
    array::from_fn(|index| self.buckets[index].load())
  }
}

#[derive(Default)]
struct MetricsMutable {
  token: TokenRefreshMetrics,
  live: LiveRefreshMetrics,
  token_last_success: Option<SuccessAgeAnchor>,
  live_last_success: Option<SuccessAgeAnchor>,
  token_started: Option<Instant>,
  live_started: Option<Instant>,
}

struct SuccessAgeAnchor {
  baseline_age: Duration,
  observed_at: Instant,
}

struct MetricsState {
  mutable: Mutex<MetricsMutable>,
  start_lag_warning_count: SaturatingCounter,
  active_live_warning_count: SaturatingCounter,
  live_timeout_count: SaturatingCounter,
  database_busy_count: SaturatingCounter,
  active_live: AtomicU64,
  start_lag_histogram: FixedHistogram,
  duration_histogram: FixedHistogram,
}

impl MetricsState {
  fn new(config: &RefreshConfig, clock: &dyn RefreshClock) -> Self {
    let now = clock.monotonic_now();
    Self {
      mutable: Mutex::new(MetricsMutable {
        token_last_success: config
          .token_last_success_wall
          .map(|wall| success_age_anchor(now, clock.wall_now(), wall)),
        live_last_success: config
          .live_last_success_wall
          .map(|wall| success_age_anchor(now, clock.wall_now(), wall)),
        ..MetricsMutable::default()
      }),
      start_lag_warning_count: SaturatingCounter::new(0),
      active_live_warning_count: SaturatingCounter::new(0),
      live_timeout_count: SaturatingCounter::new(0),
      database_busy_count: SaturatingCounter::new(0),
      active_live: AtomicU64::new(0),
      start_lag_histogram: FixedHistogram::new(),
      duration_histogram: FixedHistogram::new(),
    }
  }

  fn snapshot(&self, waiter_count: usize, now: Instant) -> RefreshMetricsSnapshot {
    let mut mutable = lock(&self.mutable);
    mutable.token.lane.last_success_age_ms = mutable.token_last_success.as_ref().map(|success| {
      duration_as_millis(
        success
          .baseline_age
          .saturating_add(now.saturating_duration_since(success.observed_at)),
      )
    });
    mutable.live.lane.last_success_age_ms = mutable.live_last_success.as_ref().map(|success| {
      duration_as_millis(
        success
          .baseline_age
          .saturating_add(now.saturating_duration_since(success.observed_at)),
      )
    });
    mutable.live.waiter_count = waiter_count as u64;
    mutable.live.active_executor_count = self.active_live.load(Ordering::Acquire);
    mutable.live.timeout_count = self.live_timeout_count.load();
    mutable.token.database_busy_count = self.database_busy_count.load();
    RefreshMetricsSnapshot {
      token: mutable.token.clone(),
      live: mutable.live.clone(),
      start_lag_warning_count: self.start_lag_warning_count.load(),
      active_live_warning_count: self.active_live_warning_count.load(),
      start_lag_histogram: self.start_lag_histogram.snapshot(),
      duration_histogram: self.duration_histogram.snapshot(),
    }
  }

  fn record_start_lag(&self, lag: Duration) {
    self.start_lag_histogram.record(lag);
    if lag > START_LAG_WARNING {
      self.start_lag_warning_count.increment();
      log::warn!("Refresh worker start lag exceeded five seconds.");
    }
  }

  fn record_worker_start(
    &self,
    token: bool,
    generation: u64,
    due: Option<Instant>,
    clock: &dyn RefreshClock,
  ) {
    let now = clock.monotonic_now();
    let wall = clock.wall_now();
    let lag = due.map_or(Duration::ZERO, |due| now.saturating_duration_since(due));
    self.record_start_lag(lag);
    let mut metrics = lock(&self.mutable);
    let lane = if token {
      metrics.token_started = Some(now);
      &mut metrics.token.lane
    } else {
      metrics.live_started = Some(now);
      &mut metrics.live.lane
    };
    lane.scheduled_due_at = due.map(|due| wall_time_for_instant(clock, due).to_rfc3339());
    lane.started_at = Some(wall.to_rfc3339());
    lane.start_lag_ms = duration_as_millis(lag);
    lane.running_generation = Some(generation);
  }

  #[cfg(test)]
  fn set_warning_count_for_test(&self, value: u64) {
    self.start_lag_warning_count.store(value);
  }

  #[cfg(test)]
  fn set_start_lag_bucket_for_test(&self, index: usize, value: u64) {
    self.start_lag_histogram.buckets[index].store(value);
  }
}

pub(crate) trait RefreshClock: Send + Sync {
  fn monotonic_now(&self) -> Instant;
  fn wall_now(&self) -> DateTime<Utc>;
}

#[derive(Default)]
struct SystemRefreshClock;

impl RefreshClock for SystemRefreshClock {
  fn monotonic_now(&self) -> Instant {
    Instant::now()
  }

  fn wall_now(&self) -> DateTime<Utc> {
    Utc::now()
  }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum RefreshError {
  Busy,
  Failed {
    code: RefreshFailureCode,
    detail: Option<RefreshDetail>,
  },
  Rejected {
    code: RefreshRejectionCode,
    detail: Option<RefreshDetail>,
  },
  CoordinatorUnavailable,
}

pub(crate) struct ManualRefreshTicket<T> {
  reply: Receiver<Result<Arc<T>, RefreshError>>,
}

impl<T> ManualRefreshTicket<T> {
  pub(crate) fn wait(self) -> Result<Arc<T>, RefreshError> {
    self
      .reply
      .recv()
      .unwrap_or(Err(RefreshError::CoordinatorUnavailable))
  }

  pub(crate) fn wait_timeout(self, timeout: Duration) -> Result<Arc<T>, RefreshError> {
    match self.reply.recv_timeout(timeout) {
      Ok(result) => result,
      Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
        Err(RefreshError::CoordinatorUnavailable)
      }
    }
  }
}

pub(crate) type ManualTokenTicket = ManualRefreshTicket<ScanResult>;
pub(crate) type ManualLiveTicket = ManualRefreshTicket<LiveRateLimitSnapshot>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ShutdownResult {
  pub coordinator_joined: bool,
  pub token_joined: bool,
  pub live_joined: bool,
}

struct WaiterRegistries {
  token: HashMap<TokenWaiterId, SyncSender<Result<Arc<ScanResult>, RefreshError>>>,
  live: HashMap<LiveWaiterId, SyncSender<Result<Arc<LiveRateLimitSnapshot>, RefreshError>>>,
}

impl WaiterRegistries {
  fn new() -> Self {
    Self {
      token: HashMap::with_capacity(REFRESH_WAITER_CAPACITY),
      live: HashMap::with_capacity(REFRESH_WAITER_CAPACITY),
    }
  }
}

struct IntakeState {
  accepting: bool,
  reliable_in_flight: usize,
  sender: SyncSender<RuntimeMessage>,
  #[cfg(test)]
  pause_after_check: Option<Arc<TestGateState>>,
}

struct HandleInner {
  intake: Arc<Mutex<IntakeState>>,
  reliable_changed: Arc<Condvar>,
  waiters: Arc<Mutex<WaiterRegistries>>,
  status: Arc<Mutex<RefreshStatus>>,
  metrics: Arc<MetricsState>,
  clock: Arc<dyn RefreshClock>,
  next_token_waiter: AtomicU64,
  next_live_waiter: AtomicU64,
}

struct ReliableInFlightGuard {
  intake: Arc<Mutex<IntakeState>>,
  changed: Arc<Condvar>,
}

impl Drop for ReliableInFlightGuard {
  fn drop(&mut self) {
    let mut intake = lock(&self.intake);
    if intake.reliable_in_flight == 0 {
      log::error!("Reliable refresh intake guard dropped without registration.");
    } else {
      intake.reliable_in_flight -= 1;
    }
    drop(intake);
    self.changed.notify_all();
  }
}

#[derive(Clone)]
pub(crate) struct RefreshCoordinatorHandle {
  inner: Arc<HandleInner>,
}

impl RefreshCoordinatorHandle {
  pub(crate) fn request_manual_token(
    &self,
    codex_home: Option<String>,
  ) -> Result<ManualTokenTicket, RefreshError> {
    let waiter = TokenWaiterId(next_id(&self.inner.next_token_waiter)?);
    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
    #[allow(unused_mut)]
    let mut intake = lock(&self.inner.intake);
    if !intake.accepting {
      return Err(shutdown_error());
    }
    #[cfg(test)]
    wait_on_optional_gate(&mut intake.pause_after_check);
    {
      let mut waiters = lock(&self.inner.waiters);
      if waiters.token.len() >= REFRESH_WAITER_CAPACITY {
        return Err(RefreshError::Busy);
      }
      waiters.token.insert(waiter, reply_tx);
    }
    let request = TokenRequest::manual_incremental_with_waiter(codex_home, waiter);
    if let Err(error) = try_send_public(&intake.sender, RuntimeMessage::RequestToken(request)) {
      lock(&self.inner.waiters).token.remove(&waiter);
      return Err(error);
    }
    Ok(ManualRefreshTicket { reply: reply_rx })
  }

  pub(crate) fn request_manual_live(&self) -> Result<ManualLiveTicket, RefreshError> {
    let waiter = LiveWaiterId(next_id(&self.inner.next_live_waiter)?);
    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
    #[allow(unused_mut)]
    let mut intake = lock(&self.inner.intake);
    if !intake.accepting {
      return Err(shutdown_error());
    }
    #[cfg(test)]
    wait_on_optional_gate(&mut intake.pause_after_check);
    {
      let mut waiters = lock(&self.inner.waiters);
      if waiters.live.len() >= REFRESH_WAITER_CAPACITY {
        return Err(RefreshError::Busy);
      }
      waiters.live.insert(waiter, reply_tx);
    }
    if let Err(error) = try_send_public(
      &intake.sender,
      RuntimeMessage::RequestLive(LiveRequest::manual(waiter)),
    ) {
      lock(&self.inner.waiters).live.remove(&waiter);
      return Err(error);
    }
    Ok(ManualRefreshTicket { reply: reply_rx })
  }

  pub(crate) fn update_settings(&self, config: RefreshConfig) -> Result<(), RefreshError> {
    self.send_reliable_acknowledged(|reply| RuntimeMessage::SettingsChanged(config, reply))
  }

  pub(crate) fn wake(&self) -> Result<(), RefreshError> {
    self.send_acknowledged(RuntimeMessage::Wake)
  }

  pub(crate) fn try_wake(&self) -> Result<(), RefreshError> {
    let intake = lock(&self.inner.intake);
    if !intake.accepting {
      return Err(shutdown_error());
    }
    try_send_public(&intake.sender, RuntimeMessage::WakeNoReply)
  }

  pub(crate) fn barrier(&self) -> Result<(), RefreshError> {
    self.send_acknowledged(RuntimeMessage::Barrier)
  }

  fn send_acknowledged(
    &self,
    build: impl FnOnce(SyncSender<()>) -> RuntimeMessage,
  ) -> Result<(), RefreshError> {
    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
    let intake = lock(&self.inner.intake);
    if !intake.accepting {
      return Err(shutdown_error());
    }
    try_send_public(&intake.sender, build(reply_tx))?;
    drop(intake);
    reply_rx
      .recv()
      .map_err(|_| RefreshError::CoordinatorUnavailable)
  }

  fn send_reliable_acknowledged(
    &self,
    build: impl FnOnce(SyncSender<()>) -> RuntimeMessage,
  ) -> Result<(), RefreshError> {
    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
    let (sender, in_flight) = {
      let mut intake = lock(&self.inner.intake);
      if !intake.accepting {
        return Err(shutdown_error());
      }
      intake.reliable_in_flight = intake
        .reliable_in_flight
        .checked_add(1)
        .ok_or(RefreshError::Busy)?;
      (
        intake.sender.clone(),
        ReliableInFlightGuard {
          intake: Arc::clone(&self.inner.intake),
          changed: Arc::clone(&self.inner.reliable_changed),
        },
      )
    };
    self.inner.reliable_changed.notify_all();
    sender
      .send(build(reply_tx))
      .map_err(|_| RefreshError::CoordinatorUnavailable)?;
    let result = reply_rx
      .recv()
      .map_err(|_| RefreshError::CoordinatorUnavailable);
    drop(in_flight);
    result
  }

  pub(crate) fn status(&self) -> RefreshStatus {
    lock(&self.inner.status).clone()
  }

  pub(crate) fn metrics(&self) -> RefreshMetricsSnapshot {
    let live_waiters = lock(&self.inner.waiters).live.len();
    self
      .inner
      .metrics
      .snapshot(live_waiters, self.inner.clock.monotonic_now())
  }
}

pub(crate) struct RefreshRuntimeDependencies {
  pub config: RefreshConfig,
  pub token_executor: Arc<dyn TokenRefreshExecutor>,
  pub live_fetcher: Arc<dyn LiveQuotaFetcher>,
  pub live_persister: Arc<dyn LiveQuotaPersister>,
  pub live_cache: LiveQuotaCache,
  pub event_sink: Arc<dyn RefreshEventSink>,
  pub mutation: UsageMutationCoordinator,
  pub activity_factory: Arc<dyn ActivityFactory>,
  pub clock: Arc<dyn RefreshClock>,
  pub epoch_maintenance_executor: Option<Arc<dyn EpochMaintenanceExecutor>>,
  #[cfg(test)]
  test_hooks: Option<Arc<RuntimeTestHooks>>,
}

impl RefreshRuntimeDependencies {
  #[allow(dead_code)]
  pub(crate) fn with_system_defaults(
    config: RefreshConfig,
    token_executor: Arc<dyn TokenRefreshExecutor>,
    live_fetcher: Arc<dyn LiveQuotaFetcher>,
    live_persister: Arc<dyn LiveQuotaPersister>,
    live_cache: LiveQuotaCache,
    event_sink: Arc<dyn RefreshEventSink>,
    mutation: UsageMutationCoordinator,
  ) -> Self {
    Self {
      config,
      token_executor,
      live_fetcher,
      live_persister,
      live_cache,
      event_sink,
      mutation,
      activity_factory: Arc::new(SystemActivityFactory),
      clock: Arc::new(SystemRefreshClock),
      epoch_maintenance_executor: None,
      #[cfg(test)]
      test_hooks: None,
    }
  }

  pub(crate) fn with_epoch_maintenance(
    mut self,
    executor: Arc<dyn EpochMaintenanceExecutor>,
  ) -> Self {
    self.epoch_maintenance_executor = Some(executor);
    self
  }
}

enum ShutdownLifecycle {
  Running,
  ShuttingDown,
  Complete(Arc<ShutdownResult>),
  Failed(RefreshError),
}

struct RuntimeLifecycle {
  state: Mutex<ShutdownLifecycle>,
  changed: Condvar,
  coordinator: Mutex<Option<JoinHandle<()>>>,
  intake: Arc<Mutex<IntakeState>>,
  reliable_changed: Arc<Condvar>,
  shutdown_requested: Arc<AtomicBool>,
  shutdown: Arc<AtomicBool>,
  maintenance_control: Option<Arc<EpochMaintenanceControl>>,
}

struct EpochMaintenanceControl {
  current: Mutex<Option<(u64, Arc<AtomicBool>)>>,
  mutation: UsageMutationCoordinator,
}

impl EpochMaintenanceControl {
  fn new(mutation: UsageMutationCoordinator) -> Self {
    Self {
      current: Mutex::new(None),
      mutation,
    }
  }

  fn install(&self, attempt_id: u64, cancellation: Arc<AtomicBool>) {
    *lock(&self.current) = Some((attempt_id, cancellation));
  }

  fn clear(&self, attempt_id: u64) {
    let mut current = lock(&self.current);
    if current.as_ref().is_some_and(|(id, _)| *id == attempt_id) {
      *current = None;
    }
  }

  fn cancel_current(&self) {
    if let Some((_, cancellation)) = lock(&self.current).as_ref() {
      self.mutation.cancel(cancellation.as_ref());
    }
  }
}

pub(crate) struct RefreshRuntime {
  handle: RefreshCoordinatorHandle,
  lifecycle: Arc<RuntimeLifecycle>,
  #[cfg(test)]
  test_hooks: Arc<RuntimeTestHooks>,
}

impl RefreshRuntime {
  pub(crate) fn start(dependencies: RefreshRuntimeDependencies) -> Result<Self, String> {
    start_runtime(dependencies)
  }

  pub(crate) fn handle(&self) -> RefreshCoordinatorHandle {
    self.handle.clone()
  }

  pub(crate) fn shutdown_and_join(&self) -> Result<Arc<ShutdownResult>, RefreshError> {
    let owns_shutdown = {
      let mut state = lock(&self.lifecycle.state);
      loop {
        match &*state {
          ShutdownLifecycle::Complete(result) => return Ok(Arc::clone(result)),
          ShutdownLifecycle::Failed(error) => return Err(error.clone()),
          ShutdownLifecycle::Running => {
            *state = ShutdownLifecycle::ShuttingDown;
            break true;
          }
          ShutdownLifecycle::ShuttingDown => {
            state = self
              .lifecycle
              .changed
              .wait(state)
              .unwrap_or_else(|poisoned| poisoned.into_inner());
          }
        }
      }
    };

    if owns_shutdown {
      let operation: Result<Arc<ShutdownResult>, RefreshError> = (|| {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        let sender = {
          let mut intake = lock(&self.lifecycle.intake);
          intake.accepting = false;
          intake.sender.clone()
        };
        self.lifecycle.reliable_changed.notify_all();
        // Accepted settings updates finish before shutdown is published, while
        // ordinary intake remains free to observe the closed state.
        {
          let mut intake = lock(&self.lifecycle.intake);
          while intake.reliable_in_flight != 0 {
            intake = self
              .lifecycle
              .reliable_changed
              .wait(intake)
              .unwrap_or_else(|poisoned| poisoned.into_inner());
          }
        }
        {
          let shutdown_state = lock(&self.lifecycle.state);
          self
            .lifecycle
            .shutdown_requested
            .store(true, Ordering::Release);
          #[cfg(test)]
          self.test_hooks.between_shutdown_publish_and_cancel();
          if let Some(control) = &self.lifecycle.maintenance_control {
            control.cancel_current();
          }
          self.lifecycle.changed.notify_all();
          drop(shutdown_state);
        }
        sender
          .send(RuntimeMessage::Shutdown(reply_tx))
          .map_err(|_| RefreshError::CoordinatorUnavailable)?;
        let mut result = reply_rx
          .recv()
          .map_err(|_| RefreshError::CoordinatorUnavailable)?;
        if let Some(coordinator) = lock(&self.lifecycle.coordinator).take() {
          coordinator
            .join()
            .map_err(|_| RefreshError::CoordinatorUnavailable)?;
          result.coordinator_joined = true;
        }
        Ok(Arc::new(result))
      })();
      let mut state = lock(&self.lifecycle.state);
      match &operation {
        Ok(result) => *state = ShutdownLifecycle::Complete(Arc::clone(result)),
        Err(error) => *state = ShutdownLifecycle::Failed(error.clone()),
      }
      drop(state);
      self.lifecycle.changed.notify_all();
      return operation;
    }
    unreachable!("shutdown owner is selected in the lifecycle loop")
  }
}

fn next_id(sequence: &AtomicU64) -> Result<u64, RefreshError> {
  let mut current = sequence.load(Ordering::Acquire);
  loop {
    if current == u64::MAX {
      return Err(RefreshError::Busy);
    }
    let next = current + 1;
    match sequence.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire) {
      Ok(_) => return Ok(next),
      Err(observed) => current = observed,
    }
  }
}

fn try_send_public(
  sender: &SyncSender<RuntimeMessage>,
  message: RuntimeMessage,
) -> Result<(), RefreshError> {
  match sender.try_send(message) {
    Ok(()) => Ok(()),
    Err(TrySendError::Full(_)) => Err(RefreshError::Busy),
    Err(TrySendError::Disconnected(_)) => Err(RefreshError::CoordinatorUnavailable),
  }
}

fn shutdown_error() -> RefreshError {
  RefreshError::Rejected {
    code: RefreshRejectionCode::Shutdown,
    detail: None,
  }
}

fn duration_as_millis(value: Duration) -> u64 {
  value.as_millis().min(u64::MAX as u128) as u64
}

fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
  value
    .lock()
    .unwrap_or_else(|poisoned| poisoned.into_inner())
}

enum RuntimeMessage {
  RequestToken(TokenRequest),
  RequestLive(LiveRequest),
  SettingsChanged(RefreshConfig, SyncSender<()>),
  Wake(SyncSender<()>),
  WakeNoReply,
  Barrier(SyncSender<()>),
  Worker(WorkerOutcome),
  Persistence(PersistenceWorkerOutcome),
  Shutdown(SyncSender<ShutdownResult>),
  #[cfg(test)]
  PauseCoordinator(Arc<TestGateState>, SyncSender<()>),
  #[cfg(test)]
  InstallPreparedSlot(PreparedTokenRefresh, SyncSender<()>),
  #[cfg(test)]
  PreparedSlotEmpty(SyncSender<bool>),
}

enum WorkerOutcome {
  Token(TokenWorkerOutcome),
  Live(LiveWorkerOutcome),
  Maintenance(EpochMaintenanceWorkerOutcome),
  Exited(WorkerLane),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkerLane {
  Token,
  Live,
  Maintenance,
}

enum TokenWorkerCommand {
  Parse(TokenExecutionRequest),
  Commit(PreparedTokenRefresh),
}

enum LiveWorkerCommand {
  Run(LiveExecutionRequest),
}

struct EpochMaintenanceWorkerCommand {
  attempt_id: u64,
  cancellation: Arc<AtomicBool>,
}

struct EpochMaintenanceWorkerOutcome {
  attempt_id: u64,
  result: Result<EpochMaintenanceBatch, String>,
}

enum TokenWorkerOutcome {
  Prepared {
    expected_generation: u64,
    expected_source_generation: u64,
    prepared: PreparedTokenRefresh,
  },
  PreparedMissing {
    generation: u64,
    source_generation: u64,
  },
  Committed {
    generation: u64,
    source_generation: u64,
    result: Arc<ScanResult>,
    commit: CommitMarker,
    queue_wait: Duration,
  },
  Failed {
    generation: u64,
    source_generation: u64,
    code: RefreshFailureCode,
    detail: RefreshDetail,
    queue_wait: Option<Duration>,
  },
  Stale {
    generation: u64,
    source_generation: u64,
  },
}

enum LiveWorkerOutcome {
  Completed {
    generation: u64,
    source_generation: u64,
    snapshot: Arc<LiveRateLimitSnapshot>,
    commit: CommitMarker,
    fetch_duration: Duration,
  },
  Failed {
    generation: u64,
    source_generation: u64,
    code: RefreshFailureCode,
    detail: RefreshDetail,
    fetch_duration: Duration,
    fallback: Option<Arc<LiveRateLimitSnapshot>>,
  },
  Stale {
    generation: u64,
    source_generation: u64,
  },
}

enum PersistenceWorkerResult {
  Completed(Result<(), String>),
  Stale,
}

struct PersistenceWorkerOutcome {
  work: LivePersistenceWork,
  result: PersistenceWorkerResult,
}

struct PreparedSlot {
  generation: u64,
  source_generation: u64,
  prepared: PreparedTokenRefresh,
}

struct EpochMaintenanceAttempt {
  id: u64,
}

struct EpochMaintenanceState {
  pending: bool,
  running: Option<EpochMaintenanceAttempt>,
  next_attempt_id: u64,
  next_eligible_at: Option<Instant>,
  failure_streak: u32,
}

impl EpochMaintenanceState {
  fn new(pending: bool) -> Self {
    Self {
      pending,
      running: None,
      next_attempt_id: 0,
      next_eligible_at: None,
      failure_streak: 0,
    }
  }
}

struct CoordinatorRuntime {
  schedule: CoordinatorState,
  prepared_slot: Option<PreparedSlot>,
  token_commit_dispatched: Option<(u64, u64)>,
  current_token_result: Option<(u64, Arc<ScanResult>)>,
  current_live_result: Option<(u64, Arc<LiveRateLimitSnapshot>)>,
  token_sender: Option<SyncSender<TokenWorkerCommand>>,
  live_sender: Option<SyncSender<LiveWorkerCommand>>,
  maintenance_sender: Option<SyncSender<EpochMaintenanceWorkerCommand>>,
  maintenance_control: Arc<EpochMaintenanceControl>,
  runtime_sender: SyncSender<RuntimeMessage>,
  waiters: Arc<Mutex<WaiterRegistries>>,
  status: Arc<Mutex<RefreshStatus>>,
  metrics: Arc<MetricsState>,
  event_sink: Arc<dyn RefreshEventSink>,
  live_cache: LiveQuotaCache,
  live_persister: Arc<dyn LiveQuotaPersister>,
  activity_factory: Arc<dyn ActivityFactory>,
  persistence: LivePersistenceRetryState,
  persistence_handle: Option<JoinHandle<()>>,
  clock: Arc<dyn RefreshClock>,
  source_generation: Arc<AtomicU64>,
  shutdown: Arc<AtomicBool>,
  shutdown_requested: Arc<AtomicBool>,
  token_handle: Option<JoinHandle<()>>,
  live_handle: Option<JoinHandle<()>>,
  maintenance_handle: Option<JoinHandle<()>>,
  maintenance: EpochMaintenanceState,
  token_exited: bool,
  live_exited: bool,
  maintenance_exited: bool,
  #[cfg(test)]
  hooks: Arc<RuntimeTestHooks>,
}

fn start_runtime(dependencies: RefreshRuntimeDependencies) -> Result<RefreshRuntime, String> {
  let RefreshRuntimeDependencies {
    config,
    token_executor,
    live_fetcher,
    live_persister,
    live_cache,
    event_sink,
    mutation,
    activity_factory,
    clock,
    epoch_maintenance_executor,
    #[cfg(test)]
    test_hooks,
  } = dependencies;
  let (runtime_tx, runtime_rx) = mpsc::sync_channel(RUNTIME_COMMAND_CAPACITY);
  let (token_tx, token_rx) = mpsc::sync_channel(WORKER_COMMAND_CAPACITY);
  let (live_tx, live_rx) = mpsc::sync_channel(WORKER_COMMAND_CAPACITY);
  let waiters = Arc::new(Mutex::new(WaiterRegistries::new()));
  let status = Arc::new(Mutex::new(RefreshStatus::new(&config)));
  let metrics = Arc::new(MetricsState::new(&config, &*clock));
  let source_generation = Arc::new(AtomicU64::new(0));
  let shutdown = Arc::new(AtomicBool::new(false));
  let shutdown_requested = Arc::new(AtomicBool::new(false));
  let commit_sequence = Arc::new(SaturatingCounter::new(0));
  #[cfg(test)]
  let hooks = test_hooks.unwrap_or_else(|| Arc::new(RuntimeTestHooks::default()));
  #[cfg(test)]
  let returned_hooks = Arc::clone(&hooks);
  let maintenance_pending = epoch_maintenance_executor.is_some();
  let maintenance_control = Arc::new(EpochMaintenanceControl::new(mutation.clone()));

  let token_handle = spawn_token_worker(TokenWorkerParameters {
    receiver: token_rx,
    runtime_sender: runtime_tx.clone(),
    executor: token_executor,
    mutation: mutation.clone(),
    activity_factory: Arc::clone(&activity_factory),
    status: Arc::clone(&status),
    metrics: Arc::clone(&metrics),
    source_generation: Arc::clone(&source_generation),
    shutdown: Arc::clone(&shutdown),
    shutdown_requested: Arc::clone(&shutdown_requested),
    commit_sequence: Arc::clone(&commit_sequence),
    clock: Arc::clone(&clock),
    #[cfg(test)]
    hooks: Arc::clone(&hooks),
  })?;
  let (maintenance_sender, maintenance_handle) = match epoch_maintenance_executor {
    Some(executor) => {
      let (sender, receiver) =
        mpsc::sync_channel(EPOCH_MAINTENANCE_COMMAND_CAPACITY);
      let handle = spawn_epoch_maintenance_worker(EpochMaintenanceWorkerParameters {
        receiver,
        runtime_sender: runtime_tx.clone(),
        executor,
        mutation: mutation.clone(),
        #[cfg(test)]
        hooks: Arc::clone(&hooks),
      })?;
      (Some(sender), Some(handle))
    }
    None => (None, None),
  };
  let live_handle = spawn_live_worker(LiveWorkerParameters {
    receiver: live_rx,
    runtime_sender: runtime_tx.clone(),
    fetcher: live_fetcher,
    activity_factory: Arc::clone(&activity_factory),
    status: Arc::clone(&status),
    metrics: Arc::clone(&metrics),
    source_generation: Arc::clone(&source_generation),
    shutdown: Arc::clone(&shutdown),
    shutdown_requested: Arc::clone(&shutdown_requested),
    commit_sequence,
    clock: Arc::clone(&clock),
    #[cfg(test)]
    hooks: Arc::clone(&hooks),
  })?;

  let reliable_changed = Arc::new(Condvar::new());
  let shared_intake = Arc::new(Mutex::new(IntakeState {
    accepting: true,
    reliable_in_flight: 0,
    sender: runtime_tx.clone(),
    #[cfg(test)]
    pause_after_check: None,
  }));
  let handle = RefreshCoordinatorHandle {
    inner: Arc::new(HandleInner {
      intake: Arc::clone(&shared_intake),
      reliable_changed: Arc::clone(&reliable_changed),
      waiters: Arc::clone(&waiters),
      status: Arc::clone(&status),
      metrics: Arc::clone(&metrics),
      clock: Arc::clone(&clock),
      next_token_waiter: AtomicU64::new(0),
      next_live_waiter: AtomicU64::new(0),
    }),
  };

  let schedule = CoordinatorState::new(config, clock.monotonic_now(), clock.wall_now());
  let coordinator_runtime = CoordinatorRuntime {
    schedule,
    prepared_slot: None,
    token_commit_dispatched: None,
    current_token_result: None,
    current_live_result: None,
    token_sender: Some(token_tx),
    live_sender: Some(live_tx),
    maintenance_sender,
    maintenance_control: Arc::clone(&maintenance_control),
    runtime_sender: runtime_tx.clone(),
    waiters,
    status,
    metrics,
    event_sink,
    live_cache,
    live_persister,
    activity_factory,
    persistence: LivePersistenceRetryState::new(),
    persistence_handle: None,
    clock,
    source_generation,
    shutdown: Arc::clone(&shutdown),
    shutdown_requested: Arc::clone(&shutdown_requested),
    token_handle: Some(token_handle),
    live_handle: Some(live_handle),
    maintenance_handle,
    maintenance: EpochMaintenanceState::new(maintenance_pending),
    token_exited: false,
    live_exited: false,
    maintenance_exited: !maintenance_pending,
    #[cfg(test)]
    hooks,
  };
  coordinator_runtime.sync_schedule_snapshot();
  let coordinator = thread::Builder::new()
    .name("codex-pacer-refresh-coordinator".to_string())
    .spawn(move || coordinator_loop(runtime_rx, coordinator_runtime))
    .map_err(|error| format!("Failed to start refresh coordinator: {error}"))?;

  let lifecycle = Arc::new(RuntimeLifecycle {
    state: Mutex::new(ShutdownLifecycle::Running),
    changed: Condvar::new(),
    coordinator: Mutex::new(Some(coordinator)),
    intake: shared_intake,
    reliable_changed,
    shutdown_requested,
    shutdown,
    maintenance_control: maintenance_pending.then_some(maintenance_control),
  });
  Ok(RefreshRuntime {
    handle,
    lifecycle,
    #[cfg(test)]
    test_hooks: returned_hooks,
  })
}

struct EpochMaintenanceWorkerParameters {
  receiver: Receiver<EpochMaintenanceWorkerCommand>,
  runtime_sender: SyncSender<RuntimeMessage>,
  executor: Arc<dyn EpochMaintenanceExecutor>,
  mutation: UsageMutationCoordinator,
  #[cfg(test)]
  hooks: Arc<RuntimeTestHooks>,
}

fn spawn_epoch_maintenance_worker(
  parameters: EpochMaintenanceWorkerParameters,
) -> Result<JoinHandle<()>, String> {
  thread::Builder::new()
    .name("codex-pacer-epoch-maintenance".to_string())
    .stack_size(EPOCH_MAINTENANCE_STACK_SIZE)
    .spawn(move || {
      let sender = parameters.runtime_sender.clone();
      #[cfg(test)]
      parameters.hooks.record_thread_name();
      let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        while let Ok(command) = parameters.receiver.recv() {
          let attempt_id = command.attempt_id;
          let result = run_epoch_maintenance_batch(&parameters, command.cancellation);
          if sender
            .send(RuntimeMessage::Worker(WorkerOutcome::Maintenance(
              EpochMaintenanceWorkerOutcome { attempt_id, result },
            )))
            .is_err()
          {
            return;
          }
        }
      }));
      let _ = sender.send(RuntimeMessage::Worker(WorkerOutcome::Exited(
        WorkerLane::Maintenance,
      )));
    })
    .map_err(|error| format!("Failed to start epoch maintenance worker: {error}"))
}

fn run_epoch_maintenance_batch(
  parameters: &EpochMaintenanceWorkerParameters,
  cancellation: Arc<AtomicBool>,
) -> Result<EpochMaintenanceBatch, String> {
  let mutation = parameters.mutation.run_cancellable(
    MutationPriority::Maintenance,
    &cancellation,
    || {
      if cancellation.load(Ordering::Acquire) {
        return Ok(EpochMaintenanceBatch::Cancelled);
      }
      match panic::catch_unwind(AssertUnwindSafe(|| {
        parameters
          .executor
          .run_batch(EPOCH_MAINTENANCE_BATCH_SIZE, Arc::clone(&cancellation))
      })) {
        Ok(result) => result,
        Err(_) => Err("epoch maintenance executor panicked".to_string()),
      }
    },
  );
  mutation
    .map(|outcome| outcome.value)
    .unwrap_or(Ok(EpochMaintenanceBatch::Cancelled))
}

struct TokenWorkerParameters {
  receiver: Receiver<TokenWorkerCommand>,
  runtime_sender: SyncSender<RuntimeMessage>,
  executor: Arc<dyn TokenRefreshExecutor>,
  mutation: UsageMutationCoordinator,
  activity_factory: Arc<dyn ActivityFactory>,
  status: Arc<Mutex<RefreshStatus>>,
  metrics: Arc<MetricsState>,
  source_generation: Arc<AtomicU64>,
  shutdown: Arc<AtomicBool>,
  shutdown_requested: Arc<AtomicBool>,
  commit_sequence: Arc<SaturatingCounter>,
  clock: Arc<dyn RefreshClock>,
  #[cfg(test)]
  hooks: Arc<RuntimeTestHooks>,
}

fn spawn_token_worker(parameters: TokenWorkerParameters) -> Result<JoinHandle<()>, String> {
  thread::Builder::new()
    .name("codex-pacer-refresh-token".to_string())
    .spawn(move || {
      let sender = parameters.runtime_sender.clone();
      #[cfg(test)]
      parameters.hooks.record_thread_name();
      let _ = panic::catch_unwind(AssertUnwindSafe(|| token_worker_loop(parameters)));
      let _ = sender.send(RuntimeMessage::Worker(WorkerOutcome::Exited(
        WorkerLane::Token,
      )));
    })
    .map_err(|error| format!("Failed to start token refresh worker: {error}"))
}

fn token_worker_loop(parameters: TokenWorkerParameters) {
  while let Ok(command) = parameters.receiver.recv() {
    let outcome = match command {
      TokenWorkerCommand::Parse(request) => run_token_parse(&parameters, request),
      TokenWorkerCommand::Commit(prepared) => run_token_commit(&parameters, prepared),
    };
    if parameters
      .runtime_sender
      .send(RuntimeMessage::Worker(WorkerOutcome::Token(outcome)))
      .is_err()
    {
      return;
    }
  }
}

fn run_token_parse(
  parameters: &TokenWorkerParameters,
  request: TokenExecutionRequest,
) -> TokenWorkerOutcome {
  let generation = request.generation;
  let source_generation = request.source_generation;
  if parameters.shutdown.load(Ordering::Acquire)
    || parameters.shutdown_requested.load(Ordering::Acquire)
    || parameters.source_generation.load(Ordering::Acquire) != source_generation
  {
    return TokenWorkerOutcome::Stale {
      generation,
      source_generation,
    };
  }
  set_mutation_phase(&parameters.status, MutationPhase::Parsing);
  #[cfg(test)]
  parameters.hooks.before_token_parse();
  parameters.metrics.record_worker_start(
    true,
    generation,
    request.request.planned_due_at,
    &*parameters.clock,
  );
  let result = panic::catch_unwind(AssertUnwindSafe(|| {
    let _activity = parameters.activity_factory.begin();
    parameters.executor.parse(request)
  }));
  match result {
    Ok(Ok(prepared)) => {
      #[cfg(test)]
      if prepared.omit_payload_for_test() {
        return TokenWorkerOutcome::PreparedMissing {
          generation,
          source_generation,
        };
      }
      TokenWorkerOutcome::Prepared {
        expected_generation: generation,
        expected_source_generation: source_generation,
        prepared,
      }
    }
    Ok(Err(detail)) => TokenWorkerOutcome::Failed {
      generation,
      source_generation,
      code: RefreshFailureCode::ExecutionFailed,
      detail: RefreshDetail::new(detail),
      queue_wait: None,
    },
    Err(_) => TokenWorkerOutcome::Failed {
      generation,
      source_generation,
      code: RefreshFailureCode::WorkerPanicked,
      detail: RefreshDetail::new("token parse executor panicked"),
      queue_wait: None,
    },
  }
}

enum CommitAttempt {
  Committed(Result<ScanResult, String>),
  Panicked,
  Stale,
}

fn run_token_commit(
  parameters: &TokenWorkerParameters,
  prepared: PreparedTokenRefresh,
) -> TokenWorkerOutcome {
  let generation = prepared.generation;
  let source_generation = prepared.source_generation;
  set_mutation_phase(&parameters.status, MutationPhase::WaitingToCommit);
  #[cfg(test)]
  parameters.hooks.notify_token_waiting_to_commit();
  let mutation = parameters.mutation.run(MutationPriority::Refresh, || {
    if parameters.shutdown.load(Ordering::Acquire)
      || parameters.shutdown_requested.load(Ordering::Acquire)
      || parameters.source_generation.load(Ordering::Acquire) != source_generation
    {
      drop(prepared);
      return CommitAttempt::Stale;
    }
    #[cfg(test)]
    parameters.hooks.before_token_commit();
    match panic::catch_unwind(AssertUnwindSafe(|| {
      let _activity = parameters.activity_factory.begin();
      parameters.executor.commit(prepared)
    })) {
      Ok(result) => CommitAttempt::Committed(result),
      Err(_) => CommitAttempt::Panicked,
    }
  });
  {
    let mut metrics = lock(&parameters.metrics.mutable);
    metrics.token.commit_wait_ms = duration_as_millis(mutation.queue_wait);
  }
  match mutation.value {
    CommitAttempt::Committed(Ok(result)) => {
      if parameters.shutdown_requested.load(Ordering::Acquire)
        || parameters.shutdown.load(Ordering::Acquire)
        || parameters.source_generation.load(Ordering::Acquire) != source_generation
      {
        drop(result);
        set_mutation_phase(&parameters.status, MutationPhase::Failed);
        return TokenWorkerOutcome::Stale {
          generation,
          source_generation,
        };
      }
      set_mutation_phase(&parameters.status, MutationPhase::Committed);
      let result = Arc::new(result);
      #[cfg(test)]
      parameters
        .hooks
        .record_token_arc(generation, Arc::clone(&result));
      TokenWorkerOutcome::Committed {
        generation,
        source_generation,
        result,
        commit: CommitMarker {
          sequence: parameters.commit_sequence.increment(),
          committed_at: parameters.clock.monotonic_now(),
        },
        queue_wait: mutation.queue_wait,
      }
    }
    CommitAttempt::Committed(Err(detail)) => {
      set_mutation_phase(&parameters.status, MutationPhase::Failed);
      if is_database_busy(&detail) {
        parameters.metrics.database_busy_count.increment();
      }
      TokenWorkerOutcome::Failed {
        generation,
        source_generation,
        code: RefreshFailureCode::ExecutionFailed,
        detail: RefreshDetail::new(detail),
        queue_wait: Some(mutation.queue_wait),
      }
    }
    CommitAttempt::Panicked => {
      set_mutation_phase(&parameters.status, MutationPhase::Failed);
      TokenWorkerOutcome::Failed {
        generation,
        source_generation,
        code: RefreshFailureCode::WorkerPanicked,
        detail: RefreshDetail::new("token commit executor panicked"),
        queue_wait: Some(mutation.queue_wait),
      }
    }
    CommitAttempt::Stale => TokenWorkerOutcome::Stale {
      generation,
      source_generation,
    },
  }
}

struct LiveWorkerParameters {
  receiver: Receiver<LiveWorkerCommand>,
  runtime_sender: SyncSender<RuntimeMessage>,
  fetcher: Arc<dyn LiveQuotaFetcher>,
  activity_factory: Arc<dyn ActivityFactory>,
  status: Arc<Mutex<RefreshStatus>>,
  metrics: Arc<MetricsState>,
  source_generation: Arc<AtomicU64>,
  shutdown: Arc<AtomicBool>,
  shutdown_requested: Arc<AtomicBool>,
  commit_sequence: Arc<SaturatingCounter>,
  clock: Arc<dyn RefreshClock>,
  #[cfg(test)]
  hooks: Arc<RuntimeTestHooks>,
}

fn spawn_live_worker(parameters: LiveWorkerParameters) -> Result<JoinHandle<()>, String> {
  thread::Builder::new()
    .name("codex-pacer-refresh-live".to_string())
    .spawn(move || {
      let sender = parameters.runtime_sender.clone();
      #[cfg(test)]
      parameters.hooks.record_thread_name();
      let _ = panic::catch_unwind(AssertUnwindSafe(|| live_worker_loop(parameters)));
      let _ = sender.send(RuntimeMessage::Worker(WorkerOutcome::Exited(
        WorkerLane::Live,
      )));
    })
    .map_err(|error| format!("Failed to start live refresh worker: {error}"))
}

fn live_worker_loop(parameters: LiveWorkerParameters) {
  while let Ok(LiveWorkerCommand::Run(request)) = parameters.receiver.recv() {
    let outcome = run_live_refresh(&parameters, request);
    if parameters
      .runtime_sender
      .send(RuntimeMessage::Worker(WorkerOutcome::Live(outcome)))
      .is_err()
    {
      return;
    }
  }
}

fn run_live_refresh(
  parameters: &LiveWorkerParameters,
  request: LiveExecutionRequest,
) -> LiveWorkerOutcome {
  if parameters.shutdown.load(Ordering::Acquire)
    || parameters.shutdown_requested.load(Ordering::Acquire)
    || parameters.source_generation.load(Ordering::Acquire) != request.source_generation
  {
    return LiveWorkerOutcome::Stale {
      generation: request.generation,
      source_generation: request.source_generation,
    };
  }
  #[cfg(test)]
  parameters.hooks.before_live_fetch();
  parameters.metrics.record_worker_start(
    false,
    request.generation,
    request.planned_due_at,
    &*parameters.clock,
  );
  let previous = increment_saturating_atomic(&parameters.metrics.active_live).saturating_sub(1);
  let active_guard = ActiveLiveGuard {
    active: &parameters.metrics.active_live,
  };
  if previous >= 1 {
    parameters.metrics.active_live_warning_count.increment();
    log::warn!("More than one live quota executor became active.");
  }
  let fetch_started = Instant::now();
  let fetched = panic::catch_unwind(AssertUnwindSafe(|| {
    let _activity = parameters.activity_factory.begin();
    parameters.fetcher.fetch(LIVE_QUERY_TIMEOUT)
  }));
  let fetch_duration = fetch_started.elapsed();
  drop(active_guard);
  {
    let mut metrics = lock(&parameters.metrics.mutable);
    metrics.live.app_server_duration_ms = nonzero_duration_millis(fetch_duration);
    metrics.live.last_query_timeout_ms = duration_as_millis(LIVE_QUERY_TIMEOUT);
  }
  let snapshot = match fetched {
    Ok(Ok(snapshot)) => snapshot,
    Ok(Err(detail)) => {
      let normalized = detail.to_ascii_lowercase();
      if normalized.contains("timeout") || normalized.contains("timed out") {
        parameters.metrics.live_timeout_count.increment();
      }
      if parameters.shutdown_requested.load(Ordering::Acquire)
        || parameters.shutdown.load(Ordering::Acquire)
        || parameters.source_generation.load(Ordering::Acquire) != request.source_generation
      {
        return LiveWorkerOutcome::Stale {
          generation: request.generation,
          source_generation: request.source_generation,
        };
      }
      let fallback = panic::catch_unwind(AssertUnwindSafe(|| parameters.fetcher.fallback()))
        .ok()
        .flatten()
        .map(Arc::new);
      return LiveWorkerOutcome::Failed {
        generation: request.generation,
        source_generation: request.source_generation,
        code: RefreshFailureCode::ExecutionFailed,
        detail: RefreshDetail::new(detail),
        fetch_duration,
        fallback,
      };
    }
    Err(_) => {
      return LiveWorkerOutcome::Failed {
        generation: request.generation,
        source_generation: request.source_generation,
        code: RefreshFailureCode::WorkerPanicked,
        detail: RefreshDetail::new("live fetch executor panicked"),
        fetch_duration,
        fallback: None,
      };
    }
  };
  if parameters.shutdown_requested.load(Ordering::Acquire)
    || parameters.shutdown.load(Ordering::Acquire)
    || parameters.source_generation.load(Ordering::Acquire) != request.source_generation
  {
    drop(snapshot);
    return LiveWorkerOutcome::Stale {
      generation: request.generation,
      source_generation: request.source_generation,
    };
  }
  let snapshot = Arc::new(snapshot);
  #[cfg(test)]
  parameters
    .hooks
    .record_live_arc(request.generation, Arc::clone(&snapshot));
  LiveWorkerOutcome::Completed {
    generation: request.generation,
    source_generation: request.source_generation,
    snapshot,
    commit: CommitMarker {
      sequence: parameters.commit_sequence.increment(),
      committed_at: parameters.clock.monotonic_now(),
    },
    fetch_duration,
  }
}

fn set_mutation_phase(status: &Mutex<RefreshStatus>, phase: MutationPhase) {
  lock(status).mutation_phase = Some(phase);
}

fn is_database_busy(detail: &str) -> bool {
  let detail = detail.to_ascii_lowercase();
  detail.contains("database is locked") || detail.contains("database busy")
}

fn nonzero_duration_millis(value: Duration) -> u64 {
  if value.is_zero() {
    0
  } else {
    duration_as_millis(value).max(1)
  }
}

fn epoch_maintenance_retry_delay(failure_streak: u32) -> Duration {
  let shift = failure_streak.saturating_sub(1).min(4);
  let multiplier = 1_u64 << shift;
  Duration::from_secs(
    EPOCH_MAINTENANCE_RETRY_BASE
      .as_secs()
      .saturating_mul(multiplier)
      .min(EPOCH_MAINTENANCE_RETRY_MAX.as_secs()),
  )
}

fn wall_time_for_instant(clock: &dyn RefreshClock, target: Instant) -> DateTime<Utc> {
  let monotonic_now = clock.monotonic_now();
  let wall_now = clock.wall_now();
  if target >= monotonic_now {
    wall_now
      .checked_add_signed(
        ChronoDuration::from_std(target.duration_since(monotonic_now))
          .unwrap_or(ChronoDuration::MAX),
      )
      .unwrap_or_else(rfc3339_max_utc)
  } else {
    wall_now
      .checked_sub_signed(
        ChronoDuration::from_std(monotonic_now.duration_since(target))
          .unwrap_or(ChronoDuration::MAX),
      )
      .unwrap_or_else(rfc3339_min_utc)
  }
}

fn rfc3339_max_utc() -> DateTime<Utc> {
  DateTime::parse_from_rfc3339("9999-12-31T23:59:59.999999999Z")
    .expect("RFC3339 maximum timestamp is valid")
    .with_timezone(&Utc)
}

fn rfc3339_min_utc() -> DateTime<Utc> {
  DateTime::parse_from_rfc3339("0001-01-01T00:00:00Z")
    .expect("RFC3339 minimum timestamp is valid")
    .with_timezone(&Utc)
}

fn success_age_anchor(
  monotonic_now: Instant,
  wall_now: DateTime<Utc>,
  success_wall: DateTime<Utc>,
) -> SuccessAgeAnchor {
  let baseline_age = wall_now
    .signed_duration_since(success_wall)
    .to_std()
    .unwrap_or(Duration::ZERO);
  SuccessAgeAnchor {
    baseline_age,
    observed_at: monotonic_now,
  }
}

fn increment_saturating_atomic(value: &AtomicU64) -> u64 {
  let mut current = value.load(Ordering::Acquire);
  loop {
    let next = current.saturating_add(1);
    match value.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire) {
      Ok(_) => return next,
      Err(observed) => current = observed,
    }
  }
}

struct ActiveLiveGuard<'a> {
  active: &'a AtomicU64,
}

impl Drop for ActiveLiveGuard<'_> {
  fn drop(&mut self) {
    let mut current = self.active.load(Ordering::Acquire);
    loop {
      let next = current.saturating_sub(1);
      match self
        .active
        .compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire)
      {
        Ok(_) => return,
        Err(observed) => current = observed,
      }
    }
  }
}

struct PersistenceTaskParameters {
  work: LivePersistenceWork,
  runtime_sender: SyncSender<RuntimeMessage>,
  persister: Arc<dyn LiveQuotaPersister>,
  activity_factory: Arc<dyn ActivityFactory>,
  source_generation: Arc<AtomicU64>,
  shutdown: Arc<AtomicBool>,
  shutdown_requested: Arc<AtomicBool>,
  #[cfg(test)]
  hooks: Arc<RuntimeTestHooks>,
}

fn spawn_persistence_task(parameters: PersistenceTaskParameters) -> Result<JoinHandle<()>, String> {
  thread::Builder::new()
    .name("codex-pacer-live-persist".to_string())
    .spawn(move || {
      let result = run_persistence_task(&parameters);
      let _ =
        parameters
          .runtime_sender
          .send(RuntimeMessage::Persistence(PersistenceWorkerOutcome {
            work: parameters.work.clone(),
            result,
          }));
    })
    .map_err(|error| error.to_string())
}

fn run_persistence_task(parameters: &PersistenceTaskParameters) -> PersistenceWorkerResult {
  if persistence_task_is_stale(parameters) {
    return PersistenceWorkerResult::Stale;
  }
  #[cfg(test)]
  parameters.hooks.before_live_persist();
  if persistence_task_is_stale(parameters) {
    return PersistenceWorkerResult::Stale;
  }
  let result = panic::catch_unwind(AssertUnwindSafe(|| {
    let _activity = parameters.activity_factory.begin();
    parameters.persister.persist(parameters.work.snapshot())
  }));
  if persistence_task_is_stale(parameters) {
    return PersistenceWorkerResult::Stale;
  }
  match result {
    Ok(result) => PersistenceWorkerResult::Completed(result),
    Err(_) => PersistenceWorkerResult::Completed(Err(
      "live quota persistence executor panicked".to_string(),
    )),
  }
}

fn persistence_task_is_stale(parameters: &PersistenceTaskParameters) -> bool {
  parameters.shutdown.load(Ordering::Acquire)
    || parameters.shutdown_requested.load(Ordering::Acquire)
    || parameters.source_generation.load(Ordering::Acquire) != parameters.work.source_generation()
}

fn coordinator_loop(receiver: Receiver<RuntimeMessage>, mut runtime: CoordinatorRuntime) {
  #[cfg(test)]
  runtime.hooks.record_thread_name();
  runtime.drive_background_work();
  loop {
    let message = if runtime.shutdown_requested.load(Ordering::Acquire) {
      receiver.recv().map_err(|_| RecvError)
    } else {
      match runtime.next_wait() {
        Some(wait) => match receiver.recv_timeout(wait) {
          Ok(message) => Ok(message),
          Err(RecvTimeoutError::Timeout) => {
            runtime.process_schedule_event(CoordinatorEvent::Timer);
            runtime.drive_background_work();
            continue;
          }
          Err(RecvTimeoutError::Disconnected) => Err(RecvError),
        },
        None => receiver.recv(),
      }
    };
    let Ok(message) = message else {
      return;
    };

    if runtime.shutdown_requested.load(Ordering::Acquire)
      && !matches!(message, RuntimeMessage::Shutdown(_))
    {
      runtime.handle_message_while_shutdown_pending(message);
      continue;
    }

    match message {
      RuntimeMessage::RequestToken(request) => {
        runtime.process_schedule_event(CoordinatorEvent::RequestToken(request));
        runtime.drive_background_work();
      }
      RuntimeMessage::RequestLive(request) => {
        runtime.process_schedule_event(CoordinatorEvent::RequestLive(request));
        runtime.drive_background_work();
      }
      RuntimeMessage::SettingsChanged(config, reply) => {
        let previous_source_generation = runtime.schedule.snapshot().source_generation;
        let actions = runtime.schedule.handle(
          runtime.clock.monotonic_now(),
          CoordinatorEvent::SettingsChanged(config),
        );
        let snapshot = runtime.schedule.snapshot();
        runtime
          .source_generation
          .store(snapshot.source_generation, Ordering::Release);
        if snapshot.source_generation != previous_source_generation {
          runtime.persistence.reset_source(snapshot.source_generation);
        }
        runtime.sync_schedule_snapshot();
        runtime.process_actions(actions);
        runtime.drive_background_work();
        let _ = reply.send(());
      }
      RuntimeMessage::Wake(reply) => {
        runtime.process_schedule_event(CoordinatorEvent::Wake);
        runtime.drive_background_work();
        let _ = reply.send(());
      }
      RuntimeMessage::WakeNoReply => {
        runtime.process_schedule_event(CoordinatorEvent::Wake);
        runtime.drive_background_work();
      }
      RuntimeMessage::Barrier(reply) => {
        runtime.drive_background_work();
        let _ = reply.send(());
      }
      RuntimeMessage::Worker(outcome) => {
        runtime.process_worker_outcome(outcome);
        runtime.drive_background_work();
      }
      RuntimeMessage::Persistence(outcome) => {
        runtime.process_persistence_outcome(outcome);
        runtime.drive_background_work();
      }
      RuntimeMessage::Shutdown(reply) => {
        runtime.shutdown_and_join_workers(&receiver, reply);
        return;
      }
      #[cfg(test)]
      RuntimeMessage::PauseCoordinator(gate, ready) => {
        let _ = ready.send(());
        gate.wait_for_release();
      }
      #[cfg(test)]
      RuntimeMessage::InstallPreparedSlot(prepared, reply) => {
        runtime.prepared_slot = Some(PreparedSlot {
          generation: prepared.generation,
          source_generation: prepared.source_generation,
          prepared,
        });
        runtime.hooks.set_prepared_slot_empty(false);
        let _ = reply.send(());
      }
      #[cfg(test)]
      RuntimeMessage::PreparedSlotEmpty(reply) => {
        let _ = reply.send(runtime.prepared_slot.is_none());
      }
    }
  }
}

impl CoordinatorRuntime {
  fn next_wait(&self) -> Option<Duration> {
    let now = self.clock.monotonic_now();
    let schedule = self.schedule.next_wait(now);
    let live_running = self.schedule.snapshot().live.running_generation.is_some();
    let persistence = self.persistence.next_wait(now, live_running);
    let maintenance = self.maintenance_wait(now);
    [schedule, persistence, maintenance]
      .into_iter()
      .flatten()
      .min()
  }

  fn drive_background_work(&mut self) {
    self.maybe_start_persistence();
    self.maybe_start_maintenance();
  }

  fn maybe_start_persistence(&mut self) {
    if self.shutdown_requested.load(Ordering::Acquire)
      || self.shutdown.load(Ordering::Acquire)
      || self.persistence_handle.is_some()
    {
      return;
    }
    let now = self.clock.monotonic_now();
    let live_running = self.schedule.snapshot().live.running_generation.is_some();
    if self.persistence.next_wait(now, live_running) == Some(Duration::ZERO)
      && self.maintenance.running.is_some()
    {
      self.cancel_epoch_maintenance();
      return;
    }
    let Some(work) = self
      .persistence
      .take_ready(now, live_running)
    else {
      return;
    };
    #[cfg(test)]
    self.hooks.trace("live_persist_start");
    let spawn = spawn_persistence_task(PersistenceTaskParameters {
      work: work.clone(),
      runtime_sender: self.runtime_sender.clone(),
      persister: Arc::clone(&self.live_persister),
      activity_factory: Arc::clone(&self.activity_factory),
      source_generation: Arc::clone(&self.source_generation),
      shutdown: Arc::clone(&self.shutdown),
      shutdown_requested: Arc::clone(&self.shutdown_requested),
      #[cfg(test)]
      hooks: Arc::clone(&self.hooks),
    });
    match spawn {
      Ok(handle) => self.persistence_handle = Some(handle),
      Err(error) => {
        log::warn!("Failed to start live quota persistence task: {error}");
        self.persistence.finish(
          &work,
          Err(error),
          self.clock.monotonic_now(),
          self.schedule.snapshot().interval,
        );
        #[cfg(test)]
        self.hooks.record_persistence_outcome();
      }
    }
  }

  fn maintenance_wait(&self, now: Instant) -> Option<Duration> {
    if !self.maintenance_dispatch_gates_open(now) {
      return None;
    }
    Some(
      self
        .maintenance
        .next_eligible_at
        .map(|deadline| deadline.saturating_duration_since(now))
        .unwrap_or(Duration::ZERO),
    )
  }

  fn maintenance_dispatch_gates_open(&self, now: Instant) -> bool {
    if !self.maintenance.pending
      || self.maintenance.running.is_some()
      || self.maintenance_sender.is_none()
      || self.shutdown_requested.load(Ordering::Acquire)
      || self.shutdown.load(Ordering::Acquire)
      || self.persistence_handle.is_some()
    {
      return false;
    }
    let snapshot = self.schedule.snapshot();
    if snapshot.token.running_generation.is_some()
      || snapshot.live.running_generation.is_some()
      || snapshot.token.pending
      || snapshot.live.pending
    {
      return false;
    }
    if self
      .schedule
      .next_wait(now)
      .is_some_and(|wait| wait <= EPOCH_MAINTENANCE_DEADLINE_GUARD)
    {
      return false;
    }
    self.persistence.next_wait(now, false) != Some(Duration::ZERO)
  }

  fn maybe_start_maintenance(&mut self) {
    let now = self.clock.monotonic_now();
    if self.maintenance_wait(now) != Some(Duration::ZERO) {
      return;
    }
    #[cfg(test)]
    self.hooks.before_maintenance_install();
    let Some(sender) = self.maintenance_sender.clone() else {
      return;
    };
    let Some(attempt_id) = self.maintenance.next_attempt_id.checked_add(1) else {
      log::error!("Epoch maintenance attempt ID overflowed; disabling the repair worker.");
      self.maintenance.pending = false;
      self.maintenance_sender = None;
      return;
    };
    let cancellation = Arc::new(AtomicBool::new(false));
    self
      .maintenance_control
      .install(attempt_id, Arc::clone(&cancellation));
    if self.shutdown_requested.load(Ordering::Acquire) {
      self.maintenance_control.cancel_current();
    }
    #[cfg(test)]
    self
      .hooks
      .between_maintenance_install_and_send(&cancellation);
    let command = EpochMaintenanceWorkerCommand {
      attempt_id,
      cancellation: Arc::clone(&cancellation),
    };
    match sender.try_send(command) {
      Ok(()) => {
        self.maintenance.next_attempt_id = attempt_id;
        self.maintenance.next_eligible_at = None;
        self.maintenance.running = Some(EpochMaintenanceAttempt { id: attempt_id });
        if self.shutdown_requested.load(Ordering::Acquire) {
          self.maintenance_control.cancel_current();
        }
      }
      Err(TrySendError::Full(_)) => {
        self.maintenance_control.clear(attempt_id);
        log::warn!("Epoch maintenance command queue was unexpectedly full.");
        self.maintenance.next_eligible_at = now.checked_add(EPOCH_MAINTENANCE_PACE);
      }
      Err(TrySendError::Disconnected(_)) => {
        self.maintenance_control.clear(attempt_id);
        log::warn!("Epoch maintenance worker became unavailable.");
        self.maintenance.pending = false;
        self.maintenance_sender = None;
      }
    }
  }

  fn cancel_epoch_maintenance(&self) {
    if self.maintenance.running.is_some() {
      self.maintenance_control.cancel_current();
    }
  }

  fn process_maintenance_outcome(&mut self, outcome: EpochMaintenanceWorkerOutcome) {
    let Some(attempt) = self.maintenance.running.as_ref() else {
      return;
    };
    if attempt.id != outcome.attempt_id {
      return;
    }
    self.maintenance_control.clear(outcome.attempt_id);
    self.maintenance.running = None;
    #[cfg(test)]
    self.hooks.record_maintenance_outcome();
    if self.shutdown_requested.load(Ordering::Acquire) || self.shutdown.load(Ordering::Acquire) {
      return;
    }
    let now = self.clock.monotonic_now();
    match outcome.result {
      Ok(EpochMaintenanceBatch::Progress {
        processed_rows,
        complete,
      }) => {
        self.maintenance.failure_streak = 0;
        if complete {
          log::debug!("Epoch maintenance completed after a {processed_rows}-row slice.");
          self.maintenance.pending = false;
          self.maintenance.next_eligible_at = None;
          self.maintenance_sender = None;
        } else {
          self.maintenance.next_eligible_at = now.checked_add(EPOCH_MAINTENANCE_PACE);
        }
      }
      Ok(EpochMaintenanceBatch::Cancelled) => {
        self.maintenance.failure_streak = 0;
        self.maintenance.next_eligible_at = now.checked_add(EPOCH_MAINTENANCE_PACE);
      }
      Err(error) => {
        self.maintenance.failure_streak = self.maintenance.failure_streak.saturating_add(1);
        self.maintenance.next_eligible_at =
          now.checked_add(epoch_maintenance_retry_delay(self.maintenance.failure_streak));
        log::warn!("Epoch maintenance slice failed; retrying later: {error}");
      }
    }
  }

  fn process_persistence_outcome(&mut self, outcome: PersistenceWorkerOutcome) {
    if let Some(handle) = self.persistence_handle.take() {
      if handle.join().is_err() {
        log::warn!("Live quota persistence task panicked after reporting its outcome.");
      }
    }
    match outcome.result {
      PersistenceWorkerResult::Completed(result) => {
        if let Err(error) = &result {
          log::warn!("Failed to persist live quota snapshot: {error}");
        }
        self.persistence.finish(
          &outcome.work,
          result,
          self.clock.monotonic_now(),
          self.schedule.snapshot().interval,
        );
      }
      PersistenceWorkerResult::Stale => {
        self.persistence.abandon(&outcome.work);
      }
    }
    #[cfg(test)]
    self.hooks.record_persistence_outcome();
    if self.shutdown_requested.load(Ordering::Acquire) || self.shutdown.load(Ordering::Acquire) {
      self.persistence.cancel_pending();
    }
  }

  fn handle_message_while_shutdown_pending(&mut self, message: RuntimeMessage) {
    match message {
      RuntimeMessage::SettingsChanged(_, reply)
      | RuntimeMessage::Wake(reply)
      | RuntimeMessage::Barrier(reply) => {
        let _ = reply.send(());
      }
      RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Token)) => {
        self.token_exited = true;
      }
      RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Live)) => {
        self.live_exited = true;
      }
      RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Maintenance)) => {
        self.finish_maintenance_worker_exit();
      }
      RuntimeMessage::Worker(WorkerOutcome::Maintenance(outcome)) => {
        self.process_maintenance_outcome(outcome);
      }
      RuntimeMessage::Persistence(outcome) => {
        self.process_persistence_outcome(outcome);
        self.persistence.cancel_pending();
      }
      RuntimeMessage::Worker(_)
      | RuntimeMessage::RequestToken(_)
      | RuntimeMessage::RequestLive(_) => {}
      RuntimeMessage::WakeNoReply => {}
      RuntimeMessage::Shutdown(_) => unreachable!("shutdown message handled by the main loop"),
      #[cfg(test)]
      RuntimeMessage::PauseCoordinator(gate, ready) => {
        let _ = ready.send(());
        gate.wait_for_release();
      }
      #[cfg(test)]
      RuntimeMessage::InstallPreparedSlot(prepared, reply) => {
        drop(prepared);
        let _ = reply.send(());
      }
      #[cfg(test)]
      RuntimeMessage::PreparedSlotEmpty(reply) => {
        let _ = reply.send(true);
      }
    }
  }

  fn process_schedule_event(&mut self, event: CoordinatorEvent) {
    let actions = self.schedule.handle(self.clock.monotonic_now(), event);
    self.sync_schedule_snapshot();
    self.process_actions(actions);
  }

  fn process_worker_outcome(&mut self, outcome: WorkerOutcome) {
    match outcome {
      WorkerOutcome::Token(outcome) => self.process_token_outcome(outcome),
      WorkerOutcome::Live(outcome) => self.process_live_outcome(outcome),
      WorkerOutcome::Maintenance(outcome) => self.process_maintenance_outcome(outcome),
      WorkerOutcome::Exited(WorkerLane::Token) => self.token_exited = true,
      WorkerOutcome::Exited(WorkerLane::Live) => self.live_exited = true,
      WorkerOutcome::Exited(WorkerLane::Maintenance) => self.finish_maintenance_worker_exit(),
    }
  }

  fn finish_maintenance_worker_exit(&mut self) {
    self.maintenance_exited = true;
    if let Some(handle) = self.maintenance_handle.take() {
      if handle.join().is_err() {
        log::warn!("Epoch maintenance worker panicked while exiting.");
      }
    }
    if let Some(attempt) = self.maintenance.running.take() {
      self.maintenance_control.clear(attempt.id);
      log::warn!("Epoch maintenance worker exited before reporting its active attempt.");
    }
    self.maintenance.pending = false;
    self.maintenance_sender = None;
    #[cfg(test)]
    self.hooks.record_maintenance_exit();
  }

  fn process_token_outcome(&mut self, outcome: TokenWorkerOutcome) {
    match outcome {
      TokenWorkerOutcome::Prepared {
        expected_generation,
        expected_source_generation,
        prepared,
      } => {
        if self.schedule.snapshot().token.running_generation != Some(expected_generation) {
          drop(prepared);
          return;
        }
        if self.token_commit_dispatched == Some((expected_generation, expected_source_generation)) {
          drop(prepared);
          return;
        }
        if prepared.generation != expected_generation
          || prepared.source_generation != expected_source_generation
          || self.prepared_slot.is_some()
        {
          drop(prepared);
          self.fail_running_token(
            expected_generation,
            expected_source_generation,
            RefreshFailureCode::PreparedPayloadMissing,
            "prepared token payload did not match the running generation",
          );
          return;
        }
        self.record_prepared_stats(prepared.prepared_scan.stats());
        self.prepared_slot = Some(PreparedSlot {
          generation: expected_generation,
          source_generation: expected_source_generation,
          prepared,
        });
        #[cfg(test)]
        self.hooks.set_prepared_slot_empty(false);
        self.process_schedule_event(CoordinatorEvent::TokenPrepared {
          generation: expected_generation,
          source_generation: expected_source_generation,
        });
      }
      TokenWorkerOutcome::PreparedMissing {
        generation,
        source_generation,
      } => self.fail_running_token(
        generation,
        source_generation,
        RefreshFailureCode::PreparedPayloadMissing,
        "prepared token payload was missing",
      ),
      TokenWorkerOutcome::Committed {
        generation,
        source_generation,
        result,
        commit,
        queue_wait,
      } => {
        let snapshot = self.schedule.snapshot();
        if snapshot.token.running_generation != Some(generation) {
          return;
        }
        if snapshot.source_generation != source_generation {
          drop(result);
          self.token_commit_dispatched = None;
          set_mutation_phase(&self.status, MutationPhase::Failed);
          self.finish_token_timing(false);
          self.process_schedule_event(CoordinatorEvent::TokenFinished(failed_completion(
            generation,
            source_generation,
            RefreshFailureCode::SourceChanged,
            RefreshDetail::new("refresh source changed during token commit"),
            self.clock.wall_now(),
          )));
          return;
        }
        self.token_commit_dispatched = None;
        lock(&self.metrics.mutable).token.commit_wait_ms = duration_as_millis(queue_wait);
        self.finish_token_timing(true);
        #[cfg(test)]
        self.hooks.set_completion_slots_empty(false);
        self.current_token_result = Some((generation, result));
        let completion =
          successful_completion(generation, source_generation, commit, self.clock.wall_now());
        self.process_schedule_event(CoordinatorEvent::TokenFinished(completion));
        self.current_token_result = None;
        #[cfg(test)]
        self.hooks.set_completion_slots_empty(true);
      }
      TokenWorkerOutcome::Failed {
        generation,
        source_generation,
        code,
        detail,
        queue_wait,
      } => {
        if self.schedule.snapshot().token.running_generation != Some(generation) {
          return;
        }
        self.token_commit_dispatched = None;
        set_mutation_phase(&self.status, MutationPhase::Failed);
        if let Some(queue_wait) = queue_wait {
          lock(&self.metrics.mutable).token.commit_wait_ms = duration_as_millis(queue_wait);
        }
        self.finish_token_timing(false);
        self.process_schedule_event(CoordinatorEvent::TokenFinished(failed_completion(
          generation,
          source_generation,
          code,
          detail,
          self.clock.wall_now(),
        )));
      }
      TokenWorkerOutcome::Stale {
        generation,
        source_generation,
      } => {
        if self.schedule.snapshot().token.running_generation != Some(generation) {
          return;
        }
        self.token_commit_dispatched = None;
        set_mutation_phase(&self.status, MutationPhase::Failed);
        self.finish_token_timing(false);
        self.process_schedule_event(CoordinatorEvent::TokenFinished(failed_completion(
          generation,
          source_generation,
          RefreshFailureCode::SourceChanged,
          RefreshDetail::new("refresh source changed before token commit"),
          self.clock.wall_now(),
        )));
      }
    }
  }

  fn process_live_outcome(&mut self, outcome: LiveWorkerOutcome) {
    match outcome {
      LiveWorkerOutcome::Completed {
        generation,
        source_generation,
        snapshot,
        commit,
        fetch_duration,
      } => {
        let coordinator_snapshot = self.schedule.snapshot();
        if coordinator_snapshot.live.running_generation != Some(generation) {
          return;
        }
        if coordinator_snapshot.source_generation != source_generation {
          drop(snapshot);
          self.finish_live_timing(false);
          self.process_schedule_event(CoordinatorEvent::LiveFinished(failed_completion(
            generation,
            source_generation,
            RefreshFailureCode::SourceChanged,
            RefreshDetail::new("refresh source changed before live publication"),
            self.clock.wall_now(),
          )));
          return;
        }
        lock(&self.metrics.mutable).live.app_server_duration_ms =
          nonzero_duration_millis(fetch_duration);
        self.live_cache.publish_live(
          Arc::clone(&snapshot),
          self.clock.monotonic_now(),
          self.clock.wall_now(),
        );
        lock(&self.metrics.mutable).live.fallback_age_ms = None;
        #[cfg(test)]
        self.hooks.trace("live_cache_publish");
        self.finish_live_timing(true);
        #[cfg(test)]
        self.hooks.set_completion_slots_empty(false);
        self.current_live_result = Some((generation, Arc::clone(&snapshot)));
        self.process_schedule_event(CoordinatorEvent::LiveFinished(successful_completion(
          generation,
          source_generation,
          commit,
          self.clock.wall_now(),
        )));
        self.current_live_result = None;
        #[cfg(test)]
        self.hooks.set_completion_slots_empty(true);
        self
          .persistence
          .publish(snapshot, source_generation, self.clock.monotonic_now());
      }
      LiveWorkerOutcome::Failed {
        generation,
        source_generation,
        code,
        detail,
        fetch_duration,
        fallback,
      } => {
        let coordinator_snapshot = self.schedule.snapshot();
        if coordinator_snapshot.live.running_generation != Some(generation) {
          return;
        }
        if coordinator_snapshot.source_generation != source_generation {
          self.live_cache.set_refreshing(false);
          self.finish_live_timing(false);
          self.process_schedule_event(CoordinatorEvent::LiveFinished(failed_completion(
            generation,
            source_generation,
            RefreshFailureCode::SourceChanged,
            RefreshDetail::new("refresh source changed before live fallback publication"),
            self.clock.wall_now(),
          )));
          return;
        }
        lock(&self.metrics.mutable).live.app_server_duration_ms =
          nonzero_duration_millis(fetch_duration);
        let submit_fallback_intent = code == RefreshFailureCode::ExecutionFailed;
        if let Some(fallback) = fallback {
          let state = self.live_cache.publish_fallback(
            fallback,
            self.clock.monotonic_now(),
            self.clock.wall_now(),
          );
          self.record_fallback_age(state.source_fetched_at.as_deref());
          #[cfg(test)]
          self.hooks.trace("live_cache_fallback");
        } else {
          let state = self.live_cache.mark_current_as_fallback();
          self.record_fallback_age(state.source_fetched_at.as_deref());
        }
        self.finish_live_timing(false);
        self.process_schedule_event(CoordinatorEvent::LiveFinished(failed_completion(
          generation,
          source_generation,
          code,
          detail,
          self.clock.wall_now(),
        )));
        if submit_fallback_intent {
          self.process_schedule_event(CoordinatorEvent::RequestToken(TokenRequest::for_reason(
            RefreshReason::Fallback,
          )));
        }
      }
      LiveWorkerOutcome::Stale {
        generation,
        source_generation,
      } => {
        if self.schedule.snapshot().live.running_generation != Some(generation) {
          return;
        }
        self.live_cache.set_refreshing(false);
        self.finish_live_timing(false);
        self.process_schedule_event(CoordinatorEvent::LiveFinished(failed_completion(
          generation,
          source_generation,
          RefreshFailureCode::SourceChanged,
          RefreshDetail::new("refresh source changed before live fetch"),
          self.clock.wall_now(),
        )));
      }
    }
  }

  fn fail_running_token(
    &mut self,
    generation: u64,
    source_generation: u64,
    code: RefreshFailureCode,
    detail: &str,
  ) {
    if self.schedule.snapshot().token.running_generation != Some(generation) {
      return;
    }
    self.prepared_slot = None;
    #[cfg(test)]
    self.hooks.set_prepared_slot_empty(true);
    self.token_commit_dispatched = None;
    set_mutation_phase(&self.status, MutationPhase::Failed);
    self.finish_token_timing(false);
    self.process_schedule_event(CoordinatorEvent::TokenFinished(failed_completion(
      generation,
      source_generation,
      code,
      RefreshDetail::new(detail),
      self.clock.wall_now(),
    )));
  }

  fn process_actions(&mut self, actions: Vec<CoordinatorAction>) {
    for action in actions {
      match action {
        CoordinatorAction::StartToken(request) => self.start_token(request),
        CoordinatorAction::StartLive(request) => self.start_live(request),
        CoordinatorAction::CommitToken {
          generation,
          source_generation,
        } => self.commit_token(generation, source_generation),
        CoordinatorAction::DiscardToken {
          generation,
          source_generation,
        } => {
          let should_drop = self.prepared_slot.as_ref().is_some_and(|slot| {
            slot.generation == generation && slot.source_generation == source_generation
          });
          if should_drop {
            self.prepared_slot = None;
          }
        }
        CoordinatorAction::PublishInvalidation(value) => {
          #[cfg(test)]
          let is_live = self.current_live_result.is_some();
          self.event_sink.publish_invalidation(value);
          #[cfg(test)]
          self.hooks.trace(if is_live {
            "live_invalidation"
          } else {
            "token_invalidation"
          });
        }
        CoordinatorAction::PublishCompletion(value) => {
          #[cfg(test)]
          self.hooks.trace(match value.lane {
            super::RefreshLane::Token => "token_completion",
            super::RefreshLane::Live => "live_completion",
          });
          self.event_sink.publish_completion(value);
        }
        CoordinatorAction::ResolveLiveWaiters {
          waiter_ids,
          outcome,
        } => self.resolve_live_waiters(waiter_ids, outcome),
        CoordinatorAction::ResolveTokenWaiters {
          waiter_ids,
          outcome,
        } => self.resolve_token_waiters(waiter_ids, outcome),
      }
    }
  }

  fn start_token(&mut self, request: TokenExecutionRequest) {
    self.cancel_epoch_maintenance();
    self.record_lane_start(true, request.generation, request.request.planned_due_at);
    set_mutation_phase(&self.status, MutationPhase::Parsing);
    #[cfg(test)]
    if request.request.reasons.contains(RefreshReason::Fallback) {
      self.hooks.trace("token_fallback_start");
    } else if request.generation > 1 {
      self.hooks.trace("token_follow_up_start");
    }
    let result = self.token_sender.as_ref().ok_or(()).and_then(|sender| {
      sender
        .try_send(TokenWorkerCommand::Parse(request.clone()))
        .map_err(|_| ())
    });
    if result.is_err() {
      self.fail_running_token(
        request.generation,
        request.source_generation,
        RefreshFailureCode::ExecutionFailed,
        "token worker command queue was busy",
      );
    }
  }

  fn start_live(&mut self, request: LiveExecutionRequest) {
    self.cancel_epoch_maintenance();
    self.record_lane_start(false, request.generation, request.planned_due_at);
    self.live_cache.set_refreshing(true);
    let result = self.live_sender.as_ref().ok_or(()).and_then(|sender| {
      sender
        .try_send(LiveWorkerCommand::Run(request.clone()))
        .map_err(|_| ())
    });
    if result.is_err() {
      self.live_cache.set_refreshing(false);
      self.finish_live_timing(false);
      self.process_schedule_event(CoordinatorEvent::LiveFinished(failed_completion(
        request.generation,
        request.source_generation,
        RefreshFailureCode::ExecutionFailed,
        RefreshDetail::new("live worker command queue was busy"),
        self.clock.wall_now(),
      )));
    }
  }

  fn commit_token(&mut self, generation: u64, source_generation: u64) {
    let matching = self.prepared_slot.as_ref().is_some_and(|slot| {
      slot.generation == generation && slot.source_generation == source_generation
    });
    if !matching {
      self.prepared_slot = None;
      self.fail_running_token(
        generation,
        source_generation,
        RefreshFailureCode::PreparedPayloadMissing,
        "prepared token payload was missing at commit dispatch",
      );
      return;
    }
    let prepared = self
      .prepared_slot
      .take()
      .expect("matching prepared slot was checked")
      .prepared;
    #[cfg(test)]
    self.hooks.set_prepared_slot_empty(true);
    self.token_commit_dispatched = Some((generation, source_generation));
    let result = self.token_sender.as_ref().ok_or(()).and_then(|sender| {
      sender
        .try_send(TokenWorkerCommand::Commit(prepared))
        .map_err(|_| ())
    });
    if result.is_err() {
      self.fail_running_token(
        generation,
        source_generation,
        RefreshFailureCode::ExecutionFailed,
        "token worker commit queue was busy",
      );
    }
  }

  fn resolve_token_waiters(
    &mut self,
    waiter_ids: Vec<TokenWaiterId>,
    outcome: RefreshWaiterOutcome,
  ) {
    let result = waiter_result_for_token(&outcome, self.current_token_result.take());
    #[cfg(test)]
    self.hooks.set_completion_slots_empty(true);
    let mut waiters = lock(&self.waiters);
    for waiter in waiter_ids {
      if let Some(reply) = waiters.token.remove(&waiter) {
        let _ = reply.send(clone_result(&result));
      }
    }
    drop(waiters);
    #[cfg(test)]
    self.hooks.trace("token_waiter_reply");
  }

  fn resolve_live_waiters(&mut self, waiter_ids: Vec<LiveWaiterId>, outcome: RefreshWaiterOutcome) {
    let result = waiter_result_for_live(&outcome, self.current_live_result.take());
    #[cfg(test)]
    self.hooks.set_completion_slots_empty(true);
    let mut waiters = lock(&self.waiters);
    for waiter in waiter_ids {
      if let Some(reply) = waiters.live.remove(&waiter) {
        let _ = reply.send(clone_result(&result));
      }
    }
    drop(waiters);
    #[cfg(test)]
    self.hooks.trace("live_waiter_reply");
  }

  fn record_fallback_age(&self, source_fetched_at: Option<&str>) {
    let age = source_fetched_at
      .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
      .and_then(|fetched| {
        self
          .clock
          .wall_now()
          .signed_duration_since(fetched.with_timezone(&Utc))
          .to_std()
          .ok()
      })
      .map(duration_as_millis);
    lock(&self.metrics.mutable).live.fallback_age_ms = age;
  }

  fn record_lane_start(&mut self, token: bool, generation: u64, due: Option<Instant>) {
    let mut metrics = lock(&self.metrics.mutable);
    let lane = if token {
      &mut metrics.token.lane
    } else {
      &mut metrics.live.lane
    };
    lane.scheduled_due_at = due.map(|due| wall_time_for_instant(&*self.clock, due).to_rfc3339());
    lane.started_at = None;
    lane.start_lag_ms = 0;
    lane.running_generation = Some(generation);
    drop(metrics);
    self.sync_schedule_snapshot();
  }

  fn finish_token_timing(&mut self, succeeded: bool) {
    let started = lock(&self.metrics.mutable).token_started.take();
    if let Some(started) = started {
      let duration = self
        .clock
        .monotonic_now()
        .saturating_duration_since(started);
      self.metrics.duration_histogram.record(duration);
      let mut metrics = lock(&self.metrics.mutable);
      metrics.token.lane.duration_ms = nonzero_duration_millis(duration);
      metrics.token.lane.running_generation = None;
      if succeeded {
        metrics.token_last_success = Some(SuccessAgeAnchor {
          baseline_age: Duration::ZERO,
          observed_at: self.clock.monotonic_now(),
        });
        lock(&self.status).token.last_success_at = Some(self.clock.wall_now().to_rfc3339());
      }
    }
  }

  fn finish_live_timing(&mut self, succeeded: bool) {
    let started = lock(&self.metrics.mutable).live_started.take();
    if let Some(started) = started {
      let duration = self
        .clock
        .monotonic_now()
        .saturating_duration_since(started);
      self.metrics.duration_histogram.record(duration);
      let mut metrics = lock(&self.metrics.mutable);
      metrics.live.lane.duration_ms = nonzero_duration_millis(duration);
      metrics.live.lane.running_generation = None;
      if succeeded {
        metrics.live_last_success = Some(SuccessAgeAnchor {
          baseline_age: Duration::ZERO,
          observed_at: self.clock.monotonic_now(),
        });
        lock(&self.status).live.last_success_at = Some(self.clock.wall_now().to_rfc3339());
      }
    }
  }

  fn record_prepared_stats(&self, stats: PreparedScanStats) {
    let mut metrics = lock(&self.metrics.mutable);
    metrics.token.files_visited = stats.files_visited as u64;
    metrics.token.bytes_read = stats.source_bytes_read;
    if stats.full_rebuild {
      metrics.token.full_rebuild_count = metrics.token.full_rebuild_count.saturating_add(1);
    }
  }

  fn sync_schedule_snapshot(&self) {
    let snapshot = self.schedule.snapshot();
    let token_deadline = snapshot
      .token
      .retry_deadline
      .map_or(snapshot.token.next_normal_deadline, |retry| {
        retry.min(snapshot.token.next_normal_deadline)
      });
    let live_deadline = snapshot
      .live
      .retry_deadline
      .map_or(snapshot.live.next_normal_deadline, |retry| {
        retry.min(snapshot.live.next_normal_deadline)
      });
    let token_next_due = wall_time_for_instant(&*self.clock, token_deadline).to_rfc3339();
    let live_next_due = wall_time_for_instant(&*self.clock, live_deadline).to_rfc3339();
    {
      let mut status = lock(&self.status);
      status.token.running = snapshot.token.running_generation.is_some();
      status.token.generation = snapshot.token.running_generation;
      status.token.pending = snapshot.token.pending;
      status.token.next_due_at = Some(token_next_due);
      status.live.running = snapshot.live.running_generation.is_some();
      status.live.generation = snapshot.live.running_generation;
      status.live.pending = snapshot.live.pending;
      status.live.next_due_at = Some(live_next_due);
      status.source_generation = snapshot.source_generation;
      status.auto_scan_enabled = snapshot.auto_scan_enabled;
    }
    let mut metrics = lock(&self.metrics.mutable);
    sync_lane_metrics(&mut metrics.token.lane, snapshot.token, &*self.clock);
    sync_lane_metrics(&mut metrics.live.lane, snapshot.live, &*self.clock);
  }

  fn shutdown_and_join_workers(
    &mut self,
    receiver: &Receiver<RuntimeMessage>,
    reply: SyncSender<ShutdownResult>,
  ) {
    // Required order: deny is linearized by the owner, then drain, drop, flag, close.
    drain_waiters_for_shutdown(&self.waiters);
    self.live_cache.set_refreshing(false);
    self.persistence.cancel_pending();
    self.cancel_epoch_maintenance();
    self.maintenance.pending = false;
    self.maintenance_sender = None;
    self.prepared_slot = None;
    #[cfg(test)]
    self.hooks.set_prepared_slot_empty(true);
    self.shutdown.store(true, Ordering::Release);
    self.token_sender = None;
    self.live_sender = None;
    {
      let mut status = lock(&self.status);
      status.token.running = false;
      status.token.pending = false;
      status.live.running = false;
      status.live.pending = false;
      status.mutation_phase = None;
    }

    while !self.token_exited
      || !self.live_exited
      || !self.maintenance_exited
      || self.persistence_handle.is_some()
    {
      let Ok(message) = receiver.recv() else {
        break;
      };
      match message {
        RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Token)) => {
          self.token_exited = true;
        }
        RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Live)) => {
          self.live_exited = true;
        }
        RuntimeMessage::Worker(WorkerOutcome::Exited(WorkerLane::Maintenance)) => {
          self.finish_maintenance_worker_exit();
        }
        RuntimeMessage::Worker(WorkerOutcome::Maintenance(outcome)) => {
          self.process_maintenance_outcome(outcome);
        }
        RuntimeMessage::Persistence(outcome) => {
          self.process_persistence_outcome(outcome);
          self.persistence.cancel_pending();
        }
        RuntimeMessage::Worker(_) => {}
        RuntimeMessage::SettingsChanged(_, ack)
        | RuntimeMessage::Wake(ack)
        | RuntimeMessage::Barrier(ack) => {
          let _ = ack.send(());
        }
        RuntimeMessage::RequestToken(_)
        | RuntimeMessage::RequestLive(_)
        | RuntimeMessage::WakeNoReply => {}
        RuntimeMessage::Shutdown(other) => {
          let _ = other.send(ShutdownResult {
            coordinator_joined: false,
            token_joined: false,
            live_joined: false,
          });
        }
        #[cfg(test)]
        RuntimeMessage::PauseCoordinator(gate, ready) => {
          let _ = ready.send(());
          gate.wait_for_release();
        }
        #[cfg(test)]
        RuntimeMessage::InstallPreparedSlot(prepared, ack) => {
          drop(prepared);
          let _ = ack.send(());
        }
        #[cfg(test)]
        RuntimeMessage::PreparedSlotEmpty(value) => {
          let _ = value.send(true);
        }
      }
    }

    let token_joined = self
      .token_handle
      .take()
      .map(|handle| handle.join().is_ok())
      .unwrap_or(true);
    let live_joined = self
      .live_handle
      .take()
      .map(|handle| handle.join().is_ok())
      .unwrap_or(true);
    let _ = reply.send(ShutdownResult {
      coordinator_joined: false,
      token_joined,
      live_joined,
    });
  }
}

fn sync_lane_metrics(
  target: &mut RefreshLaneMetrics,
  source: super::LaneScheduleSnapshot,
  clock: &dyn RefreshClock,
) {
  target.failure_streak = source.failure_streak;
  target.retry_at = source
    .retry_deadline
    .map(|retry| wall_time_for_instant(clock, retry).to_rfc3339());
  target.missed_deadline_count = source.missed_deadline_count;
  target.coalesced_trigger_count = source.coalesced_trigger_count;
  target.running_generation = source.running_generation;
  target.pending_reasons = source.pending_reasons.bits();
}

fn successful_completion(
  generation: u64,
  source_generation: u64,
  commit: CommitMarker,
  completed_at: DateTime<Utc>,
) -> ExecutionCompletion {
  ExecutionCompletion {
    generation,
    source_generation,
    succeeded: true,
    failure_code: None,
    failure: None,
    completed_at: completed_at.to_rfc3339(),
    commit: Some(commit),
    retry_jitter: Duration::ZERO,
  }
}

fn failed_completion(
  generation: u64,
  source_generation: u64,
  code: RefreshFailureCode,
  detail: RefreshDetail,
  completed_at: DateTime<Utc>,
) -> ExecutionCompletion {
  ExecutionCompletion {
    generation,
    source_generation,
    succeeded: false,
    failure_code: Some(code),
    failure: Some(detail.as_str().to_string()),
    completed_at: completed_at.to_rfc3339(),
    commit: None,
    retry_jitter: Duration::ZERO,
  }
}

fn waiter_error(outcome: &RefreshWaiterOutcome) -> RefreshError {
  match outcome {
    RefreshWaiterOutcome::Completed {
      failure_code,
      detail,
      ..
    } => RefreshError::Failed {
      code: failure_code.unwrap_or(RefreshFailureCode::ExecutionFailed),
      detail: detail.clone(),
    },
    RefreshWaiterOutcome::Rejected { code, detail } => RefreshError::Rejected {
      code: *code,
      detail: detail.clone(),
    },
  }
}

fn waiter_result_for_token(
  outcome: &RefreshWaiterOutcome,
  current: Option<(u64, Arc<ScanResult>)>,
) -> Result<Arc<ScanResult>, RefreshError> {
  match outcome {
    RefreshWaiterOutcome::Completed {
      generation,
      succeeded: true,
      ..
    } => current
      .filter(|(result_generation, _)| result_generation == generation)
      .map(|(_, result)| result)
      .ok_or_else(|| RefreshError::Failed {
        code: RefreshFailureCode::PreparedPayloadMissing,
        detail: Some(RefreshDetail::new(
          "successful token completion had no exact result",
        )),
      }),
    _ => Err(waiter_error(outcome)),
  }
}

fn waiter_result_for_live(
  outcome: &RefreshWaiterOutcome,
  current: Option<(u64, Arc<LiveRateLimitSnapshot>)>,
) -> Result<Arc<LiveRateLimitSnapshot>, RefreshError> {
  match outcome {
    RefreshWaiterOutcome::Completed {
      generation,
      succeeded: true,
      ..
    } => current
      .filter(|(result_generation, _)| result_generation == generation)
      .map(|(_, result)| result)
      .ok_or_else(|| RefreshError::Failed {
        code: RefreshFailureCode::PreparedPayloadMissing,
        detail: Some(RefreshDetail::new(
          "successful live completion had no exact snapshot",
        )),
      }),
    _ => Err(waiter_error(outcome)),
  }
}

fn clone_result<T>(result: &Result<Arc<T>, RefreshError>) -> Result<Arc<T>, RefreshError> {
  match result {
    Ok(value) => Ok(Arc::clone(value)),
    Err(error) => Err(error.clone()),
  }
}

fn drain_waiters_for_shutdown(waiters: &Mutex<WaiterRegistries>) {
  let mut waiters = lock(waiters);
  for (_, reply) in waiters.token.drain() {
    let _ = reply.send(Err(shutdown_error()));
  }
  for (_, reply) in waiters.live.drain() {
    let _ = reply.send(Err(shutdown_error()));
  }
}

#[cfg(test)]
#[derive(Default)]
struct TestGateSnapshot {
  worker_ready: bool,
  entered: bool,
  released: bool,
  dropped: bool,
  used_spool: bool,
}

#[cfg(test)]
#[derive(Default)]
struct TestGateState {
  state: Mutex<TestGateSnapshot>,
  changed: Condvar,
}

#[cfg(test)]
impl TestGateState {
  fn mark_worker_ready_and_wait(&self) {
    let mut state = lock(&self.state);
    state.worker_ready = true;
    self.changed.notify_all();
    while !state.released {
      state = self
        .changed
        .wait(state)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    }
  }

  fn mark_entered_and_wait(&self) {
    let mut state = lock(&self.state);
    state.entered = true;
    self.changed.notify_all();
    while !state.released {
      state = self
        .changed
        .wait(state)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    }
  }

  fn mark_entered(&self) {
    lock(&self.state).entered = true;
    self.changed.notify_all();
  }

  fn wait_for_release(&self) {
    let mut state = lock(&self.state);
    while !state.released {
      state = self
        .changed
        .wait(state)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    }
  }

  fn release(&self) {
    lock(&self.state).released = true;
    self.changed.notify_all();
  }

  fn wait_for(&self, timeout: Duration, predicate: impl Fn(&TestGateSnapshot) -> bool) {
    let state = lock(&self.state);
    let (state, timed_out) = self
      .changed
      .wait_timeout_while(state, timeout, |state| !predicate(state))
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(predicate(&state), "gate condition was not reached");
    assert!(
      !timed_out.timed_out(),
      "timed out waiting for gate condition"
    );
  }

  fn mark_dropped(&self) {
    lock(&self.state).dropped = true;
    self.changed.notify_all();
  }
}

#[cfg(test)]
#[derive(Clone)]
struct PhaseGateControl {
  state: Arc<TestGateState>,
}

#[cfg(test)]
impl PhaseGateControl {
  fn wait_worker_ready(&self, timeout: Duration) {
    self.state.wait_for(timeout, |state| state.worker_ready);
  }

  fn wait_entered(&self, timeout: Duration) {
    self.state.wait_for(timeout, |state| state.entered);
  }

  fn release(&self) {
    self.state.release();
  }

  fn wait_dropped(&self, timeout: Duration) {
    self.state.wait_for(timeout, |state| state.dropped);
  }

  fn used_spool(&self) -> bool {
    lock(&self.state.state).used_spool
  }

  fn probe(&self) -> Arc<TestGateState> {
    Arc::clone(&self.state)
  }
}

#[cfg(test)]
struct TestPreparedDropProbe {
  state: Arc<TestGateState>,
}

#[cfg(test)]
impl Drop for TestPreparedDropProbe {
  fn drop(&mut self) {
    self.state.mark_dropped();
  }
}

#[cfg(test)]
impl PreparedTokenRefresh {
  fn omit_payload_for_test(&self) -> bool {
    self.omit_payload
  }
}

#[cfg(test)]
#[derive(Default)]
struct IndexedPreBodyGates {
  next_call: AtomicU64,
  gates: Mutex<HashMap<u64, Arc<TestGateState>>>,
}

#[cfg(test)]
impl IndexedPreBodyGates {
  fn arm(&self, call: u64, gate: Arc<TestGateState>) {
    lock(&self.gates).insert(call, gate);
  }

  fn before_call(&self) {
    let call = self.next_call.fetch_add(1, Ordering::AcqRel) + 1;
    if let Some(gate) = lock(&self.gates).remove(&call) {
      gate.mark_worker_ready_and_wait();
    }
  }
}

#[cfg(test)]
#[derive(Default)]
struct TestHookData {
  token_arcs: HashMap<u64, Arc<ScanResult>>,
  live_arcs: HashMap<u64, Arc<LiveRateLimitSnapshot>>,
  trace: Vec<&'static str>,
  thread_names: Vec<String>,
  token_waiting_count: u64,
  prepared_slot_empty: bool,
  completion_slots_empty: bool,
  persistence_outcomes: u64,
  maintenance_outcomes: u64,
  maintenance_exited: bool,
  maintenance_cancelled_between_install_and_send: Option<bool>,
}

#[cfg(test)]
#[derive(Default)]
struct RuntimeTestHooks {
  token_parse_pre_body: IndexedPreBodyGates,
  token_commit_pre_body: IndexedPreBodyGates,
  live_fetch_pre_body: IndexedPreBodyGates,
  live_persist_pre_body: IndexedPreBodyGates,
  maintenance_before_install: Mutex<Option<Arc<TestGateState>>>,
  shutdown_between_publish_and_cancel: Mutex<Option<Arc<TestGateState>>>,
  maintenance_between_install_and_send: Mutex<Option<Arc<TestGateState>>>,
  data: Mutex<TestHookData>,
  changed: Condvar,
}

#[cfg(test)]
impl RuntimeTestHooks {
  fn before_token_parse(&self) {
    self.token_parse_pre_body.before_call();
  }

  fn before_token_commit(&self) {
    self.token_commit_pre_body.before_call();
  }

  fn before_live_fetch(&self) {
    self.live_fetch_pre_body.before_call();
  }

  fn before_live_persist(&self) {
    self.live_persist_pre_body.before_call();
  }

  fn block_maintenance_before_install(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    *lock(&self.maintenance_before_install) = Some(Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn before_maintenance_install(&self) {
    if let Some(gate) = lock(&self.maintenance_before_install).take() {
      gate.mark_worker_ready_and_wait();
    }
  }

  fn block_shutdown_between_publish_and_cancel(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    *lock(&self.shutdown_between_publish_and_cancel) = Some(Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn between_shutdown_publish_and_cancel(&self) {
    if let Some(gate) = lock(&self.shutdown_between_publish_and_cancel).take() {
      gate.mark_worker_ready_and_wait();
    }
  }

  fn block_between_maintenance_install_and_send(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    *lock(&self.maintenance_between_install_and_send) = Some(Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn between_maintenance_install_and_send(&self, cancellation: &AtomicBool) {
    lock(&self.data).maintenance_cancelled_between_install_and_send =
      Some(cancellation.load(Ordering::Acquire));
    self.changed.notify_all();
    if let Some(gate) = lock(&self.maintenance_between_install_and_send).take() {
      gate.mark_worker_ready_and_wait();
    }
  }

  fn notify_token_waiting_to_commit(&self) {
    let mut data = lock(&self.data);
    data.token_waiting_count = data.token_waiting_count.saturating_add(1);
    drop(data);
    self.changed.notify_all();
  }

  fn record_token_arc(&self, generation: u64, result: Arc<ScanResult>) {
    lock(&self.data).token_arcs.insert(generation, result);
    self.changed.notify_all();
  }

  fn record_live_arc(&self, generation: u64, result: Arc<LiveRateLimitSnapshot>) {
    lock(&self.data).live_arcs.insert(generation, result);
    self.changed.notify_all();
  }

  fn trace(&self, value: &'static str) {
    lock(&self.data).trace.push(value);
    self.changed.notify_all();
  }

  fn record_thread_name(&self) {
    if let Some(name) = thread::current().name() {
      let mut data = lock(&self.data);
      if !data.thread_names.iter().any(|existing| existing == name) {
        data.thread_names.push(name.to_string());
      }
      drop(data);
      self.changed.notify_all();
    }
  }

  fn set_prepared_slot_empty(&self, empty: bool) {
    lock(&self.data).prepared_slot_empty = empty;
    self.changed.notify_all();
  }

  fn set_completion_slots_empty(&self, empty: bool) {
    lock(&self.data).completion_slots_empty = empty;
    self.changed.notify_all();
  }

  fn record_persistence_outcome(&self) {
    let mut data = lock(&self.data);
    data.persistence_outcomes = data.persistence_outcomes.saturating_add(1);
    drop(data);
    self.changed.notify_all();
  }

  fn record_maintenance_outcome(&self) {
    let mut data = lock(&self.data);
    data.maintenance_outcomes = data.maintenance_outcomes.saturating_add(1);
    drop(data);
    self.changed.notify_all();
  }

  fn record_maintenance_exit(&self) {
    lock(&self.data).maintenance_exited = true;
    self.changed.notify_all();
  }

  fn wait_for(&self, timeout: Duration, predicate: impl Fn(&TestHookData) -> bool) {
    let data = lock(&self.data);
    let (data, timed_out) = self
      .changed
      .wait_timeout_while(data, timeout, |data| !predicate(data))
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(predicate(&data), "runtime hook condition was not reached");
    assert!(!timed_out.timed_out(), "timed out waiting for runtime hook");
  }
}

#[cfg(test)]
fn wait_on_optional_gate(gate: &mut Option<Arc<TestGateState>>) {
  if let Some(gate) = gate.take() {
    gate.mark_worker_ready_and_wait();
  }
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum PanicPhase {
  Parse,
  Commit,
  Fetch,
  Persist,
}

#[cfg(test)]
#[derive(Default)]
struct TestTokenBehavior {
  parse_body_gates: HashMap<u64, Arc<TestGateState>>,
  commit_body_gates: HashMap<u64, Arc<TestGateState>>,
  pre_body_parse_states: HashMap<u64, Arc<TestGateState>>,
  panic_once: HashMap<PanicPhase, u64>,
  spool_calls: HashMap<u64, Arc<TestGateState>>,
  omit_prepared_once: bool,
  mismatch_prepared_once: bool,
  assert_drop_before_next: Option<(u64, Arc<TestGateState>)>,
  follow_up_observed_drop: bool,
  commit_sources: Vec<String>,
  parse_thread_ids: Vec<String>,
  commit_thread_ids: Vec<String>,
}

#[cfg(test)]
struct TestScanEnvironment {
  _root: tempfile::TempDir,
  db_path: std::path::PathBuf,
  primary: std::path::PathBuf,
  replacement: std::path::PathBuf,
}

#[cfg(test)]
impl TestScanEnvironment {
  fn new() -> Self {
    let root = tempfile::tempdir().expect("test scan root");
    let db_path = root.path().join("runtime.sqlite");
    let conn = crate::database::open_connection(&db_path).expect("open runtime test database");
    crate::database::init_db(&conn).expect("initialize runtime test database");
    drop(conn);
    let primary = root.path().join("primary");
    let replacement = root.path().join("replacement");
    write_runtime_session(&primary, "11111111-1111-1111-1111-111111111111", false);
    write_runtime_session(&replacement, "22222222-2222-2222-2222-222222222222", false);
    Self {
      _root: root,
      db_path,
      primary,
      replacement,
    }
  }

  fn prepare(&self, request: &TokenExecutionRequest, spool: bool) -> PreparedScan {
    let source = request
      .request
      .codex_home
      .as_ref()
      .map(std::path::PathBuf::from)
      .unwrap_or_else(|| self.primary.clone());
    if spool {
      write_runtime_session(&source, "33333333-3333-3333-3333-333333333333", true);
      write_runtime_session(&source, "44444444-4444-4444-4444-444444444444", true);
    }
    crate::importer::prepare_scan(
      &self.db_path,
      Some(source.to_string_lossy().to_string()),
      crate::importer::ScanKind::Full,
    )
    .expect("prepare runtime test scan")
  }
}

#[cfg(test)]
fn write_runtime_session(home: &std::path::Path, id: &str, large: bool) {
  let sessions = home.join("sessions");
  std::fs::create_dir_all(&sessions).expect("create runtime sessions directory");
  let path = sessions.join(format!("rollout-2026-07-10T00-00-00-{id}.jsonl"));
  if path.exists() {
    return;
  }
  let mut body = format!(
    concat!(
      "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",",
      "\"payload\":{{\"id\":\"{}\"}}}}\n",
      "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",",
      "\"payload\":{{\"model\":\"gpt-5.4\"}}}}\n"
    ),
    id
  );
  let line = concat!(
    "{\"timestamp\":\"2026-07-10T00:00:02Z\",\"type\":\"event_msg\",",
    "\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{",
    "\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":0,",
    "\"reasoning_output_tokens\":0,\"total_tokens\":10}},",
    "\"rate_limits\":{\"plan_type\":\"pro\"}}}\n"
  );
  body.push_str(line);
  if large {
    while body.len() < 160 * 1024 {
      body.push_str(line);
    }
  }
  std::fs::write(path, body).expect("write runtime session");
}

#[cfg(test)]
struct TestTokenExecutor {
  environment: TestScanEnvironment,
  hooks: Arc<RuntimeTestHooks>,
  behavior: Mutex<TestTokenBehavior>,
  changed: Condvar,
  parse_calls: AtomicU64,
  commit_calls: AtomicU64,
}

#[cfg(test)]
impl TestTokenExecutor {
  fn new(hooks: Arc<RuntimeTestHooks>) -> Self {
    Self {
      environment: TestScanEnvironment::new(),
      hooks,
      behavior: Mutex::new(TestTokenBehavior::default()),
      changed: Condvar::new(),
      parse_calls: AtomicU64::new(0),
      commit_calls: AtomicU64::new(0),
    }
  }

  fn primary_source(&self) -> String {
    self.environment.primary.to_string_lossy().to_string()
  }

  fn replacement_source(&self) -> String {
    self.environment.replacement.to_string_lossy().to_string()
  }

  fn next_parse_call(&self) -> u64 {
    self.parse_calls.load(Ordering::Acquire) + 1
  }

  fn next_commit_call(&self) -> u64 {
    self.commit_calls.load(Ordering::Acquire) + 1
  }

  fn block_next_parse(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    lock(&self.behavior)
      .parse_body_gates
      .insert(self.next_parse_call(), Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn block_parse_call(&self, call: u64) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    self
      .hooks
      .token_parse_pre_body
      .arm(call, Arc::clone(&state));
    lock(&self.behavior)
      .pre_body_parse_states
      .insert(call, Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn block_next_commit(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    lock(&self.behavior)
      .commit_body_gates
      .insert(self.next_commit_call(), Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn block_next_spooled_parse_with_drop_probe(&self) -> PhaseGateControl {
    let control = self.block_next_parse();
    lock(&self.behavior)
      .spool_calls
      .insert(self.next_parse_call(), control.probe());
    control
  }

  fn use_spooled_prepared_for_next_parse(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    state.release();
    lock(&self.behavior)
      .spool_calls
      .insert(self.next_parse_call(), Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn assert_probe_dropped_before_next_parse(&self, probe: Arc<TestGateState>) {
    lock(&self.behavior).assert_drop_before_next = Some((self.next_parse_call() + 1, probe));
  }

  fn follow_up_observed_probe_dropped(&self) -> bool {
    lock(&self.behavior).follow_up_observed_drop
  }

  fn panic_once(&self, phase: PanicPhase) {
    lock(&self.behavior).panic_once.insert(phase, 1);
  }

  fn omit_prepared_payload_once(&self) {
    lock(&self.behavior).omit_prepared_once = true;
  }

  fn return_mismatched_prepared_once(&self) {
    lock(&self.behavior).mismatch_prepared_once = true;
  }

  fn parse_calls(&self) -> u64 {
    self.parse_calls.load(Ordering::Acquire)
  }

  fn commit_calls(&self) -> u64 {
    self.commit_calls.load(Ordering::Acquire)
  }

  fn wait_for_parse_calls(&self, expected: u64, timeout: Duration) {
    self.wait_for_counter(&self.parse_calls, expected, timeout);
  }

  fn wait_for_commit_calls(&self, expected: u64, timeout: Duration) {
    self.wait_for_counter(&self.commit_calls, expected, timeout);
  }

  fn wait_until_waiting_to_commit(&self, timeout: Duration) {
    self
      .hooks
      .wait_for(timeout, |data| data.token_waiting_count > 0);
  }

  fn wait_for_counter(&self, counter: &AtomicU64, expected: u64, timeout: Duration) {
    let state = lock(&self.behavior);
    let (_state, timed_out) = self
      .changed
      .wait_timeout_while(state, timeout, |_| {
        counter.load(Ordering::Acquire) < expected
      })
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(counter.load(Ordering::Acquire) >= expected);
    assert!(
      !timed_out.timed_out(),
      "timed out waiting for executor calls"
    );
  }

  fn committed_arc(&self, generation: u64, timeout: Duration) -> Arc<ScanResult> {
    self
      .hooks
      .wait_for(timeout, |data| data.token_arcs.contains_key(&generation));
    Arc::clone(
      lock(&self.hooks.data)
        .token_arcs
        .get(&generation)
        .expect("recorded token arc"),
    )
  }

  fn assert_result_for_generation(&self, result: &ScanResult, generation: u64) {
    assert_eq!(result.imported_sessions, generation as usize);
    assert_eq!(result.updated_sessions, generation as usize);
  }

  fn unique_parse_worker_ids(&self) -> usize {
    let ids = &lock(&self.behavior).parse_thread_ids;
    ids.iter().collect::<std::collections::HashSet<_>>().len()
  }

  fn unique_commit_worker_ids(&self) -> usize {
    let ids = &lock(&self.behavior).commit_thread_ids;
    ids.iter().collect::<std::collections::HashSet<_>>().len()
  }

  fn worker_name(&self) -> String {
    "codex-pacer-refresh-token".to_string()
  }

  fn commit_calls_for_source(&self, label: &str) -> usize {
    lock(&self.behavior)
      .commit_sources
      .iter()
      .filter(|source| source.contains(label))
      .count()
  }

  fn make_prepared_for_test(
    &self,
    generation: u64,
    source_generation: u64,
    spool: bool,
  ) -> (PreparedTokenRefresh, PhaseGateControl) {
    let state = Arc::new(TestGateState::default());
    state.release();
    let mut request = TokenRequest::manual_full(Some(self.primary_source()));
    request.planned_due_at = None;
    let execution = TokenExecutionRequest {
      generation,
      source_generation,
      request,
    };
    let prepared_scan = self.environment.prepare(&execution, spool);
    lock(&state.state).used_spool = prepared_scan.stats().used_spool;
    (
      PreparedTokenRefresh {
        generation,
        source_generation,
        started_at: Utc::now(),
        prepared_scan,
        drop_probe: Some(TestPreparedDropProbe {
          state: Arc::clone(&state),
        }),
        omit_payload: false,
      },
      PhaseGateControl { state },
    )
  }
}

#[cfg(test)]
impl TokenRefreshExecutor for TestTokenExecutor {
  fn parse(&self, request: TokenExecutionRequest) -> Result<PreparedTokenRefresh, String> {
    let call = self.parse_calls.fetch_add(1, Ordering::AcqRel) + 1;
    let thread_id = format!("{:?}", thread::current().id());
    let (body_gate, pre_body, spool_state, panic_now, omit, mismatch, observed_drop) = {
      let mut behavior = lock(&self.behavior);
      behavior.parse_thread_ids.push(thread_id);
      let observed_drop = behavior
        .assert_drop_before_next
        .as_ref()
        .filter(|(target, _)| *target == call)
        .map(|(_, probe)| lock(&probe.state).dropped);
      if let Some(dropped) = observed_drop {
        behavior.follow_up_observed_drop = dropped;
        behavior.assert_drop_before_next = None;
      }
      let panic_now = take_panic(&mut behavior.panic_once, PanicPhase::Parse);
      (
        behavior.parse_body_gates.remove(&call),
        behavior.pre_body_parse_states.remove(&call),
        behavior.spool_calls.remove(&call),
        panic_now,
        std::mem::take(&mut behavior.omit_prepared_once),
        std::mem::take(&mut behavior.mismatch_prepared_once),
        observed_drop,
      )
    };
    self.changed.notify_all();
    if let Some(pre_body) = pre_body {
      pre_body.mark_entered();
    }
    if let Some(body_gate) = body_gate {
      body_gate.mark_entered_and_wait();
    }
    if observed_drop == Some(false) {
      panic!("follow-up parse entered before prepared spool dropped");
    }
    if panic_now {
      panic!("intentional parse panic");
    }
    let mut generation = request.generation;
    if mismatch {
      generation = generation.saturating_add(1);
    }
    let prepared_scan = self.environment.prepare(&request, spool_state.is_some());
    if let Some(state) = &spool_state {
      lock(&state.state).used_spool = prepared_scan.stats().used_spool;
    }
    Ok(PreparedTokenRefresh {
      generation,
      source_generation: request.source_generation,
      started_at: Utc::now(),
      prepared_scan,
      drop_probe: spool_state.map(|state| TestPreparedDropProbe { state }),
      omit_payload: omit,
    })
  }

  fn commit(&self, prepared: PreparedTokenRefresh) -> Result<ScanResult, String> {
    let call = self.commit_calls.fetch_add(1, Ordering::AcqRel) + 1;
    let thread_id = format!("{:?}", thread::current().id());
    let (body_gate, panic_now) = {
      let mut behavior = lock(&self.behavior);
      behavior.commit_thread_ids.push(thread_id);
      behavior.commit_sources.push(
        prepared
          .prepared_scan
          .source_key()
          .resolved_home()
          .to_string_lossy()
          .to_string(),
      );
      let panic_now = take_panic(&mut behavior.panic_once, PanicPhase::Commit);
      (behavior.commit_body_gates.remove(&call), panic_now)
    };
    self.changed.notify_all();
    if let Some(body_gate) = body_gate {
      body_gate.mark_entered_and_wait();
    }
    if panic_now {
      panic!("intentional commit panic");
    }
    let generation = prepared.generation;
    drop(prepared);
    Ok(ScanResult {
      codex_home: format!("generation-{generation}"),
      scanned_files: generation as usize,
      imported_sessions: generation as usize,
      updated_sessions: generation as usize,
      missing_sessions: 0,
      scan_kind: "incremental".to_string(),
      source_bytes_read: 0,
      tail_parsed_files: 0,
      fully_parsed_files: 0,
      last_completed_at: "2026-07-11T00:00:00Z".to_string(),
    })
  }
}

#[cfg(test)]
fn take_panic(panics: &mut HashMap<PanicPhase, u64>, phase: PanicPhase) -> bool {
  let Some(remaining) = panics.get_mut(&phase) else {
    return false;
  };
  if *remaining == 0 {
    return false;
  }
  *remaining -= 1;
  true
}

#[cfg(test)]
#[derive(Default)]
struct TestLiveBehavior {
  fetch_body_gates: HashMap<u64, Arc<TestGateState>>,
  persist_body_gates: HashMap<u64, Arc<TestGateState>>,
  pre_body_fetch_states: HashMap<u64, Arc<TestGateState>>,
  panic_once: HashMap<PanicPhase, u64>,
  fetch_thread_ids: Vec<String>,
  persist_thread_ids: Vec<String>,
  last_timeout: Option<Duration>,
  fail_next_fetch: bool,
  fallback_snapshot: Option<Arc<LiveRateLimitSnapshot>>,
  queued_snapshots: VecDeque<Arc<LiveRateLimitSnapshot>>,
  fail_next_persist: bool,
  persisted_fetched_at: Vec<String>,
}

#[cfg(test)]
struct TestLiveExecutor {
  hooks: Arc<RuntimeTestHooks>,
  behavior: Mutex<TestLiveBehavior>,
  changed: Condvar,
  fetch_calls: AtomicU64,
  persist_calls: AtomicU64,
  active: AtomicU64,
  maximum_active: AtomicU64,
  fallback_calls: AtomicU64,
}

#[cfg(test)]
impl TestLiveExecutor {
  fn new(hooks: Arc<RuntimeTestHooks>) -> Self {
    Self {
      hooks,
      behavior: Mutex::new(TestLiveBehavior::default()),
      changed: Condvar::new(),
      fetch_calls: AtomicU64::new(0),
      persist_calls: AtomicU64::new(0),
      active: AtomicU64::new(0),
      maximum_active: AtomicU64::new(0),
      fallback_calls: AtomicU64::new(0),
    }
  }

  fn block_next_fetch(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    let call = self.fetch_calls.load(Ordering::Acquire) + 1;
    lock(&self.behavior)
      .fetch_body_gates
      .insert(call, Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn block_fetch_call_before_body(&self, call: u64) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    self.hooks.live_fetch_pre_body.arm(call, Arc::clone(&state));
    lock(&self.behavior)
      .pre_body_fetch_states
      .insert(call, Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn block_next_persist(&self) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    let call = self.persist_calls.load(Ordering::Acquire) + 1;
    lock(&self.behavior)
      .persist_body_gates
      .insert(call, Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn panic_once(&self, phase: PanicPhase) {
    lock(&self.behavior).panic_once.insert(phase, 1);
  }

  fn fail_next_fetch_with_fallback(&self, fallback: Arc<LiveRateLimitSnapshot>) {
    let mut behavior = lock(&self.behavior);
    behavior.fail_next_fetch = true;
    behavior.fallback_snapshot = Some(fallback);
  }

  fn fail_next_fetch(&self) {
    let mut behavior = lock(&self.behavior);
    behavior.fail_next_fetch = true;
    behavior.fallback_snapshot = None;
  }

  fn fallback_calls(&self) -> u64 {
    self.fallback_calls.load(Ordering::Acquire)
  }

  fn fail_next_persist(&self) {
    lock(&self.behavior).fail_next_persist = true;
  }

  fn queue_snapshot(&self, snapshot: Arc<LiveRateLimitSnapshot>) {
    lock(&self.behavior).queued_snapshots.push_back(snapshot);
  }

  fn fetch_calls(&self) -> u64 {
    self.fetch_calls.load(Ordering::Acquire)
  }

  fn persist_calls(&self) -> u64 {
    self.persist_calls.load(Ordering::Acquire)
  }

  fn wait_for_fetch_calls(&self, expected: u64, timeout: Duration) {
    let behavior = lock(&self.behavior);
    let (_behavior, timed_out) = self
      .changed
      .wait_timeout_while(behavior, timeout, |_| self.fetch_calls() < expected)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(self.fetch_calls() >= expected);
    assert!(!timed_out.timed_out(), "timed out waiting for live fetch");
  }

  fn wait_for_persist_calls(&self, expected: u64, timeout: Duration) {
    let behavior = lock(&self.behavior);
    let (_behavior, timed_out) = self
      .changed
      .wait_timeout_while(behavior, timeout, |_| self.persist_calls() < expected)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(self.persist_calls() >= expected);
    assert!(
      !timed_out.timed_out(),
      "timed out waiting for live persistence"
    );
  }

  fn maximum_active_fetches(&self) -> u64 {
    self.maximum_active.load(Ordering::Acquire)
  }

  fn fetched_arc(&self, generation: u64, timeout: Duration) -> Arc<LiveRateLimitSnapshot> {
    self
      .hooks
      .wait_for(timeout, |data| data.live_arcs.contains_key(&generation));
    Arc::clone(
      lock(&self.hooks.data)
        .live_arcs
        .get(&generation)
        .expect("recorded live arc"),
    )
  }

  fn unique_fetch_worker_ids(&self) -> usize {
    lock(&self.behavior)
      .fetch_thread_ids
      .iter()
      .collect::<std::collections::HashSet<_>>()
      .len()
  }

  fn unique_persist_worker_ids(&self) -> usize {
    lock(&self.behavior)
      .persist_thread_ids
      .iter()
      .collect::<std::collections::HashSet<_>>()
      .len()
  }

  fn worker_name(&self) -> String {
    "codex-pacer-refresh-live".to_string()
  }

  fn last_timeout(&self) -> Option<Duration> {
    lock(&self.behavior).last_timeout
  }

  fn persisted_fetched_at(&self) -> Vec<String> {
    lock(&self.behavior).persisted_fetched_at.clone()
  }

  fn snapshot_at(fetched_at: &str) -> Arc<LiveRateLimitSnapshot> {
    Arc::new(LiveRateLimitSnapshot {
      fetched_at: fetched_at.to_string(),
      ..Self::snapshot()
    })
  }

  fn snapshot() -> LiveRateLimitSnapshot {
    LiveRateLimitSnapshot {
      limit_id: Some("runtime-test".to_string()),
      limit_name: Some("Runtime Test".to_string()),
      plan_type: Some("pro".to_string()),
      primary: None,
      secondary: None,
      fetched_at: "2026-07-11T00:00:00Z".to_string(),
    }
  }
}

#[cfg(test)]
impl LiveQuotaFetcher for TestLiveExecutor {
  fn fetch(&self, timeout: Duration) -> Result<LiveRateLimitSnapshot, String> {
    let call = self.fetch_calls.fetch_add(1, Ordering::AcqRel) + 1;
    let active = increment_saturating_atomic(&self.active);
    let mut maximum = self.maximum_active.load(Ordering::Acquire);
    while active > maximum {
      match self.maximum_active.compare_exchange_weak(
        maximum,
        active,
        Ordering::AcqRel,
        Ordering::Acquire,
      ) {
        Ok(_) => break,
        Err(observed) => maximum = observed,
      }
    }
    let (body_gate, pre_body, panic_now, fail_now, snapshot) = {
      let mut behavior = lock(&self.behavior);
      behavior
        .fetch_thread_ids
        .push(format!("{:?}", thread::current().id()));
      behavior.last_timeout = Some(timeout);
      let panic_now = take_panic(&mut behavior.panic_once, PanicPhase::Fetch);
      (
        behavior.fetch_body_gates.remove(&call),
        behavior.pre_body_fetch_states.remove(&call),
        panic_now,
        std::mem::take(&mut behavior.fail_next_fetch),
        behavior.queued_snapshots.pop_front(),
      )
    };
    self.changed.notify_all();
    if let Some(pre_body) = pre_body {
      pre_body.mark_entered();
    }
    if let Some(body_gate) = body_gate {
      body_gate.mark_entered_and_wait();
    }
    decrement_saturating_atomic(&self.active);
    if panic_now {
      panic!("intentional fetch panic");
    }
    if fail_now {
      return Err("intentional live fetch failure".to_string());
    }
    Ok(
      snapshot
        .map(|snapshot| snapshot.as_ref().clone())
        .unwrap_or_else(Self::snapshot),
    )
  }

  fn fallback(&self) -> Option<LiveRateLimitSnapshot> {
    self.fallback_calls.fetch_add(1, Ordering::AcqRel);
    lock(&self.behavior)
      .fallback_snapshot
      .as_ref()
      .map(|snapshot| snapshot.as_ref().clone())
  }
}

#[cfg(test)]
impl LiveQuotaPersister for TestLiveExecutor {
  fn persist(&self, snapshot: &LiveRateLimitSnapshot) -> Result<(), String> {
    let call = self.persist_calls.fetch_add(1, Ordering::AcqRel) + 1;
    let (body_gate, panic_now, fail_now) = {
      let mut behavior = lock(&self.behavior);
      behavior
        .persist_thread_ids
        .push(format!("{:?}", thread::current().id()));
      let panic_now = take_panic(&mut behavior.panic_once, PanicPhase::Persist);
      behavior
        .persisted_fetched_at
        .push(snapshot.fetched_at.clone());
      (
        behavior.persist_body_gates.remove(&call),
        panic_now,
        std::mem::take(&mut behavior.fail_next_persist),
      )
    };
    self.changed.notify_all();
    if let Some(body_gate) = body_gate {
      body_gate.mark_entered_and_wait();
    }
    if panic_now {
      panic!("intentional persist panic");
    }
    if fail_now {
      return Err("intentional persistence failure".to_string());
    }
    Ok(())
  }
}

#[cfg(test)]
#[derive(Default)]
struct TestEpochMaintenanceBehavior {
  body_gates: HashMap<u64, Arc<TestGateState>>,
  results: VecDeque<Result<EpochMaintenanceBatch, String>>,
  limits: Vec<usize>,
  cancellations: Vec<Arc<AtomicBool>>,
  worker_ids: Vec<String>,
  panic_calls: std::collections::HashSet<u64>,
}

#[cfg(test)]
struct TestEpochMaintenanceExecutor {
  behavior: Mutex<TestEpochMaintenanceBehavior>,
  changed: Condvar,
  calls: AtomicU64,
}

#[cfg(test)]
impl TestEpochMaintenanceExecutor {
  fn new() -> Self {
    Self {
      behavior: Mutex::new(TestEpochMaintenanceBehavior::default()),
      changed: Condvar::new(),
      calls: AtomicU64::new(0),
    }
  }

  fn queue_result(&self, result: Result<EpochMaintenanceBatch, String>) {
    lock(&self.behavior).results.push_back(result);
  }

  fn block_batch(&self, call: u64) -> PhaseGateControl {
    let state = Arc::new(TestGateState::default());
    lock(&self.behavior)
      .body_gates
      .insert(call, Arc::clone(&state));
    PhaseGateControl { state }
  }

  fn panic_batch(&self, call: u64) {
    lock(&self.behavior).panic_calls.insert(call);
  }

  fn wait_for_calls(&self, expected: u64, timeout: Duration) {
    let behavior = lock(&self.behavior);
    let (_behavior, timed_out) = self
      .changed
      .wait_timeout_while(behavior, timeout, |_| self.calls() < expected)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(self.calls() >= expected, "maintenance call count");
    assert!(!timed_out.timed_out(), "timed out waiting for maintenance call");
  }

  fn calls(&self) -> u64 {
    self.calls.load(Ordering::Acquire)
  }

  fn limits(&self) -> Vec<usize> {
    lock(&self.behavior).limits.clone()
  }

  fn cancellation(&self, call: usize) -> Arc<AtomicBool> {
    Arc::clone(
      lock(&self.behavior)
        .cancellations
        .get(call.saturating_sub(1))
        .expect("recorded maintenance cancellation token"),
    )
  }

  fn unique_worker_ids(&self) -> usize {
    lock(&self.behavior)
      .worker_ids
      .iter()
      .collect::<std::collections::HashSet<_>>()
      .len()
  }
}

#[cfg(test)]
impl EpochMaintenanceExecutor for TestEpochMaintenanceExecutor {
  fn run_batch(
    &self,
    limit: usize,
    cancellation: Arc<AtomicBool>,
  ) -> Result<EpochMaintenanceBatch, String> {
    let call = self.calls.fetch_add(1, Ordering::AcqRel) + 1;
    let (gate, result, panic_now) = {
      let mut behavior = lock(&self.behavior);
      behavior.limits.push(limit);
      behavior.cancellations.push(Arc::clone(&cancellation));
      behavior
        .worker_ids
        .push(format!("{:?}", thread::current().id()));
      let panic_now = behavior.panic_calls.remove(&call);
      let result = (!panic_now).then(|| {
        behavior.results.pop_front().unwrap_or(Ok(EpochMaintenanceBatch::Progress {
          processed_rows: 1_000,
          complete: false,
        }))
      });
      (behavior.body_gates.remove(&call), result, panic_now)
    };
    self.changed.notify_all();
    if let Some(gate) = gate {
      gate.mark_entered_and_wait();
    }
    if panic_now {
      panic!("intentional epoch maintenance panic");
    }
    if cancellation.load(Ordering::Acquire) {
      return Ok(EpochMaintenanceBatch::Cancelled);
    }
    result.expect("non-panicking maintenance call has a result")
  }
}

#[cfg(test)]
fn decrement_saturating_atomic(value: &AtomicU64) {
  let mut current = value.load(Ordering::Acquire);
  loop {
    match value.compare_exchange_weak(
      current,
      current.saturating_sub(1),
      Ordering::AcqRel,
      Ordering::Acquire,
    ) {
      Ok(_) => return,
      Err(observed) => current = observed,
    }
  }
}

#[cfg(test)]
struct TestClock {
  base_monotonic: Instant,
  base_wall: DateTime<Utc>,
  offset: Mutex<Duration>,
}

#[cfg(test)]
impl TestClock {
  fn new() -> Self {
    Self {
      base_monotonic: Instant::now(),
      base_wall: Utc::now(),
      offset: Mutex::new(Duration::ZERO),
    }
  }

  fn advance(&self, duration: Duration) {
    let mut offset = lock(&self.offset);
    *offset = offset.saturating_add(duration);
  }
}

#[cfg(test)]
impl RefreshClock for TestClock {
  fn monotonic_now(&self) -> Instant {
    let elapsed = self.base_monotonic.elapsed();
    self
      .base_monotonic
      .checked_add(elapsed.saturating_add(*lock(&self.offset)))
      .unwrap_or(self.base_monotonic)
  }

  fn wall_now(&self) -> DateTime<Utc> {
    let elapsed = self.base_monotonic.elapsed();
    self
      .base_wall
      .checked_add_signed(
        ChronoDuration::from_std(elapsed.saturating_add(*lock(&self.offset)))
          .unwrap_or(ChronoDuration::MAX),
      )
      .unwrap_or(DateTime::<Utc>::MAX_UTC)
  }
}

#[cfg(test)]
struct TestEvents {
  invalidations: SaturatingCounter,
  completions: SaturatingCounter,
  hooks: Arc<RuntimeTestHooks>,
  changed: Condvar,
  gate: Mutex<()>,
}

#[cfg(test)]
impl TestEvents {
  fn new(hooks: Arc<RuntimeTestHooks>) -> Self {
    Self {
      invalidations: SaturatingCounter::new(0),
      completions: SaturatingCounter::new(0),
      hooks,
      changed: Condvar::new(),
      gate: Mutex::new(()),
    }
  }

  fn completion_count(&self) -> u64 {
    self.completions.load()
  }

  fn invalidation_count(&self) -> u64 {
    self.invalidations.load()
  }

  fn trace_prefix(&self) -> Vec<&'static str> {
    lock(&self.hooks.data).trace.clone()
  }

  fn wait_for_completions(&self, expected: u64, timeout: Duration) {
    let gate = lock(&self.gate);
    let (_gate, timed_out) = self
      .changed
      .wait_timeout_while(gate, timeout, |_| self.completion_count() < expected)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(self.completion_count() >= expected);
    assert!(!timed_out.timed_out(), "timed out waiting for completions");
  }
}

#[cfg(test)]
impl RefreshEventSink for TestEvents {
  fn publish_invalidation(&self, _value: DisplayInvalidation) {
    self.invalidations.increment();
  }

  fn publish_completion(&self, _value: RefreshCompletedEvent) {
    self.completions.increment();
    self.changed.notify_all();
  }
}

#[cfg(test)]
#[derive(Clone, Copy)]
enum TestRigSchedule {
  Disabled,
  StartupDue,
  Paused,
  HugeInterval,
  ThirtySecondDeadline,
  ThirtyOneSecondDeadline,
}

#[cfg(test)]
struct RuntimeTestRig {
  runtime: Arc<RefreshRuntime>,
  handle: RefreshCoordinatorHandle,
  token: Arc<TestTokenExecutor>,
  live: Arc<TestLiveExecutor>,
  live_cache: LiveQuotaCache,
  events: Arc<TestEvents>,
  mutation: UsageMutationCoordinator,
  activities: super::power::CountingActivityFactory,
  clock: Arc<TestClock>,
  metrics_handle: Arc<MetricsState>,
}

#[cfg(test)]
impl RuntimeTestRig {
  fn disabled() -> Self {
    Self::build(TestRigSchedule::Disabled).0
  }

  fn startup_due_with_pre_body_gates() -> (Self, PhaseGateControl, PhaseGateControl) {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    let parse = token.block_parse_call(1);
    let fetch = live.block_fetch_call_before_body(1);
    (
      Self::build_with_components(TestRigSchedule::StartupDue, hooks, token, live),
      parse,
      fetch,
    )
  }

  fn startup_due_with_pre_body_gates_and_maintenance(
    maintenance: Arc<TestEpochMaintenanceExecutor>,
  ) -> (Self, PhaseGateControl, PhaseGateControl) {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    let parse = token.block_parse_call(1);
    let fetch = live.block_fetch_call_before_body(1);
    (
      Self::build_with_components_and_options(
        TestRigSchedule::StartupDue,
        hooks,
        token,
        live,
        Some(maintenance),
        None,
      ),
      parse,
      fetch,
    )
  }

  fn scheduled_overdue(overdue: Duration) -> Self {
    let rig = Self::build(TestRigSchedule::Paused).0;
    rig
      .clock
      .advance(Duration::from_secs(60).saturating_add(overdue));
    rig.handle.wake().expect("wake overdue test runtime");
    rig
  }

  fn paused_clock() -> Self {
    Self::build(TestRigSchedule::Paused).0
  }

  fn huge_interval() -> Self {
    Self::build(TestRigSchedule::HugeInterval).0
  }

  fn build(schedule: TestRigSchedule) -> (Self, Arc<RuntimeTestHooks>) {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    let rig = Self::build_with_components(schedule, Arc::clone(&hooks), token, live);
    (rig, hooks)
  }

  fn build_with_maintenance(
    schedule: TestRigSchedule,
    maintenance: Arc<TestEpochMaintenanceExecutor>,
  ) -> Self {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    Self::build_with_components_and_options(
      schedule,
      hooks,
      token,
      live,
      Some(maintenance),
      None,
    )
  }

  fn build_with_maintenance_shutdown_install_gates(
    maintenance: Arc<TestEpochMaintenanceExecutor>,
  ) -> (
    Self,
    PhaseGateControl,
    PhaseGateControl,
    PhaseGateControl,
  ) {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let before_install = hooks.block_maintenance_before_install();
    let shutdown_gap = hooks.block_shutdown_between_publish_and_cancel();
    let between_install_and_send = hooks.block_between_maintenance_install_and_send();
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    (
      Self::build_with_components_and_options(
        TestRigSchedule::Disabled,
        hooks,
        token,
        live,
        Some(maintenance),
        None,
      ),
      before_install,
      shutdown_gap,
      between_install_and_send,
    )
  }

  fn build_with_maintenance_and_mutation(
    schedule: TestRigSchedule,
    maintenance: Arc<TestEpochMaintenanceExecutor>,
    mutation: UsageMutationCoordinator,
  ) -> Self {
    let hooks = Arc::new(RuntimeTestHooks::default());
    initialize_test_hooks(&hooks);
    let token = Arc::new(TestTokenExecutor::new(Arc::clone(&hooks)));
    let live = Arc::new(TestLiveExecutor::new(Arc::clone(&hooks)));
    Self::build_with_components_and_options(
      schedule,
      hooks,
      token,
      live,
      Some(maintenance),
      Some(mutation),
    )
  }

  fn build_with_components(
    schedule: TestRigSchedule,
    hooks: Arc<RuntimeTestHooks>,
    token: Arc<TestTokenExecutor>,
    live: Arc<TestLiveExecutor>,
  ) -> Self {
    Self::build_with_components_and_options(schedule, hooks, token, live, None, None)
  }

  fn build_with_components_and_options(
    schedule: TestRigSchedule,
    hooks: Arc<RuntimeTestHooks>,
    token: Arc<TestTokenExecutor>,
    live: Arc<TestLiveExecutor>,
    maintenance: Option<Arc<TestEpochMaintenanceExecutor>>,
    mutation: Option<UsageMutationCoordinator>,
  ) -> Self {
    let clock = Arc::new(TestClock::new());
    let interval = match schedule {
      TestRigSchedule::HugeInterval => Duration::MAX,
      TestRigSchedule::ThirtySecondDeadline => Duration::from_secs(30),
      TestRigSchedule::ThirtyOneSecondDeadline => Duration::from_secs(31),
      _ => Duration::from_secs(60),
    };
    let wall_now = clock.wall_now();
    let (auto_scan_enabled, success_wall) = match schedule {
      TestRigSchedule::Disabled => (false, Some(wall_now)),
      TestRigSchedule::StartupDue => (
        true,
        Some(wall_now - ChronoDuration::from_std(interval + Duration::from_secs(1)).unwrap()),
      ),
      TestRigSchedule::Paused => (true, Some(wall_now)),
      TestRigSchedule::HugeInterval => (false, Some(wall_now)),
      TestRigSchedule::ThirtySecondDeadline | TestRigSchedule::ThirtyOneSecondDeadline => {
        (true, Some(wall_now))
      }
    };
    let config = RefreshConfig {
      auto_scan_enabled,
      interval,
      codex_home: Some(token.primary_source()),
      token_last_success_wall: success_wall,
      live_last_success_wall: success_wall,
    };
    let events = Arc::new(TestEvents::new(Arc::clone(&hooks)));
    let mutation = mutation.unwrap_or_default();
    let activities = super::power::CountingActivityFactory::default();
    let live_cache = LiveQuotaCache::new();
    let dependencies = RefreshRuntimeDependencies {
      config,
      token_executor: token.clone(),
      live_fetcher: live.clone(),
      live_persister: live.clone(),
      live_cache: live_cache.clone(),
      event_sink: events.clone(),
      mutation: mutation.clone(),
      activity_factory: Arc::new(activities.clone()),
      clock: clock.clone(),
      epoch_maintenance_executor: maintenance
        .as_ref()
        .map(|executor| executor.clone() as Arc<dyn EpochMaintenanceExecutor>),
      test_hooks: Some(Arc::clone(&hooks)),
    };
    let runtime = Arc::new(RefreshRuntime::start(dependencies).expect("start test runtime"));
    let handle = runtime.handle();
    let metrics_handle = Arc::clone(&handle.inner.metrics);
    Self {
      runtime,
      handle,
      token,
      live,
      live_cache,
      events,
      mutation,
      activities,
      clock,
      metrics_handle,
    }
  }

  fn metrics(&self) -> RefreshMetricsSnapshot {
    self.handle.metrics()
  }

  fn wait_until_idle(&self, timeout: Duration) {
    let initial = self.events.completion_count();
    if self.handle.status().token.running || self.handle.status().live.running {
      self
        .events
        .wait_for_completions(initial.saturating_add(1), timeout);
    }
    self.runtime.test_hooks.wait_for(timeout, |_| {
      let status = self.handle.status();
      !status.token.running && !status.live.running
    });
  }

  fn wait_for_persist_outcomes(&self, expected: u64, timeout: Duration) {
    self
      .runtime
      .test_hooks
      .wait_for(timeout, |data| data.persistence_outcomes >= expected);
  }

  fn wait_for_maintenance_outcomes(&self, expected: u64, timeout: Duration) {
    self
      .runtime
      .test_hooks
      .wait_for(timeout, |data| data.maintenance_outcomes >= expected);
  }

  fn wait_for_maintenance_exit(&self, timeout: Duration) {
    self
      .runtime
      .test_hooks
      .wait_for(timeout, |data| data.maintenance_exited);
  }

  fn maintenance_cancelled_between_install_and_send(&self) -> bool {
    lock(&self.runtime.test_hooks.data)
      .maintenance_cancelled_between_install_and_send
      .expect("recorded maintenance install/send cancellation state")
  }

  fn wait_for_mutation_queue(&self, expected: usize, timeout: Duration) {
    self.mutation.wait_for_queued_for_test(expected, timeout);
  }

  fn shutdown(&self) {
    self
      .runtime
      .shutdown_and_join()
      .expect("shutdown test runtime");
  }

  fn config_with_source(&self, _label: &str) -> RefreshConfig {
    RefreshConfig {
      auto_scan_enabled: false,
      interval: Duration::from_secs(60),
      codex_home: Some(self.token.replacement_source()),
      token_last_success_wall: Some(self.clock.wall_now()),
      live_last_success_wall: Some(self.clock.wall_now()),
    }
  }

  fn thread_names(&self) -> [String; 3] {
    self
      .runtime
      .test_hooks
      .wait_for(Duration::from_secs(2), |data| data.thread_names.len() == 3);
    let mut names = lock(&self.runtime.test_hooks.data).thread_names.clone();
    names.sort();
    names.try_into().expect("three runtime thread names")
  }

  fn current_completion_slots_are_empty(&self) -> bool {
    lock(&self.runtime.test_hooks.data).completion_slots_empty
  }

  fn hold_mutation_slot(&self) -> MutationHold {
    MutationHold::start(self.mutation.clone(), Arc::clone(&self.runtime.test_hooks))
  }

  fn mutation_slot_is_free(&self) -> bool {
    self.mutation.run(MutationPriority::Pricing, || true).value
  }

  fn token_schedule_waiter_count(&self) -> usize {
    lock(&self.handle.inner.waiters).token.len()
  }

  fn runtime_sender(&self) -> SyncSender<RuntimeMessage> {
    lock(&self.handle.inner.intake).sender.clone()
  }

  fn inject_duplicate_prepared_after_take(&self, generation: u64) {
    let (prepared, _) = self.token.make_prepared_for_test(generation, 0, false);
    self
      .runtime_sender()
      .send(RuntimeMessage::Worker(WorkerOutcome::Token(
        TokenWorkerOutcome::Prepared {
          expected_generation: generation,
          expected_source_generation: 0,
          prepared,
        },
      )))
      .expect("inject duplicate prepared outcome");
  }

  fn inject_duplicate_token_completion(&self, generation: u64, result: Arc<ScanResult>) {
    self
      .runtime_sender()
      .send(RuntimeMessage::Worker(WorkerOutcome::Token(
        TokenWorkerOutcome::Committed {
          generation,
          source_generation: 0,
          result,
          commit: CommitMarker {
            sequence: generation,
            committed_at: self.clock.monotonic_now(),
          },
          queue_wait: Duration::ZERO,
        },
      )))
      .expect("inject duplicate token completion");
  }

  fn inject_maintenance_outcome(
    &self,
    attempt_id: u64,
    result: Result<EpochMaintenanceBatch, String>,
  ) {
    self
      .runtime_sender()
      .send(RuntimeMessage::Worker(WorkerOutcome::Maintenance(
        EpochMaintenanceWorkerOutcome { attempt_id, result },
      )))
      .expect("inject maintenance outcome");
  }

  fn pause_coordinator(&self) -> CoordinatorPause {
    let gate = Arc::new(TestGateState::default());
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    self
      .runtime_sender()
      .send(RuntimeMessage::PauseCoordinator(
        Arc::clone(&gate),
        ready_tx,
      ))
      .expect("pause coordinator command");
    ready_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("coordinator pauses");
    CoordinatorPause { gate }
  }

  fn fill_runtime_channel_until_busy(&self) {
    loop {
      match self.handle.try_wake() {
        Ok(()) => {}
        Err(RefreshError::Busy) => return,
        Err(error) => panic!("unexpected command fill error: {error:?}"),
      }
    }
  }

  fn wait_for_reliable_in_flight(&self, expected: usize, timeout: Duration) {
    let intake = lock(&self.handle.inner.intake);
    let (intake, timed_out) = self
      .handle
      .inner
      .reliable_changed
      .wait_timeout_while(intake, timeout, |state| {
        state.reliable_in_flight < expected
      })
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert_eq!(intake.reliable_in_flight, expected);
    assert!(
      !timed_out.timed_out(),
      "timed out waiting for reliable refresh intake"
    );
  }

  fn wait_for_intake_closed(&self, timeout: Duration) {
    let intake = lock(&self.handle.inner.intake);
    let (intake, timed_out) = self
      .handle
      .inner
      .reliable_changed
      .wait_timeout_while(intake, timeout, |state| state.accepting)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(!intake.accepting);
    assert!(!timed_out.timed_out(), "timed out waiting for intake close");
  }

  fn start_intake_race_after_accept_check(&self) -> IntakeRace {
    let gate = Arc::new(TestGateState::default());
    lock(&self.handle.inner.intake).pause_after_check = Some(Arc::clone(&gate));
    let handle = self.handle.clone();
    let (result_tx, result_rx) = mpsc::sync_channel(1);
    let join = thread::spawn(move || {
      let result = handle
        .request_manual_live()
        .and_then(|ticket| ticket.wait_timeout(Duration::from_secs(2)));
      let _ = result_tx.send(result);
    });
    IntakeRace {
      gate,
      result: Mutex::new(Some(result_rx)),
      join: Mutex::new(Some(join)),
    }
  }

  fn shutdown_in_background(&self) -> BackgroundShutdown {
    BackgroundShutdown::start(Arc::clone(&self.runtime))
  }

  fn wait_for_shutdown_requested(&self, timeout: Duration) {
    let state = lock(&self.runtime.lifecycle.state);
    let (_state, timed_out) = self
      .runtime
      .lifecycle
      .changed
      .wait_timeout_while(state, timeout, |_| {
        !self
          .runtime
          .lifecycle
          .shutdown_requested
          .load(Ordering::Acquire)
      })
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(
      self
        .runtime
        .lifecycle
        .shutdown_requested
        .load(Ordering::Acquire),
      "shutdown request was not linearized"
    );
    assert!(
      !timed_out.timed_out(),
      "timed out waiting for shutdown request"
    );
  }

  fn install_spooled_prepared_slot_via_coordinator(&self) -> PhaseGateControl {
    let (prepared, control) = self.token.make_prepared_for_test(999, 0, true);
    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
    self
      .runtime_sender()
      .send(RuntimeMessage::InstallPreparedSlot(prepared, reply_tx))
      .expect("install coordinator prepared slot");
    reply_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("coordinator owns prepared slot");
    control
  }

  fn prepared_slot_is_empty_via_coordinator(&self) -> bool {
    lock(&self.runtime.test_hooks.data).prepared_slot_empty
  }
}

#[cfg(test)]
fn initialize_test_hooks(hooks: &RuntimeTestHooks) {
  let mut data = lock(&hooks.data);
  data.prepared_slot_empty = true;
  data.completion_slots_empty = true;
}

#[cfg(test)]
struct MutationHold {
  release: Mutex<Option<mpsc::Sender<()>>>,
  join: Mutex<Option<JoinHandle<()>>>,
  hooks: Arc<RuntimeTestHooks>,
  waiting_baseline: u64,
}

#[cfg(test)]
impl MutationHold {
  fn start(mutation: UsageMutationCoordinator, hooks: Arc<RuntimeTestHooks>) -> Self {
    let waiting_baseline = lock(&hooks.data).token_waiting_count;
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::channel();
    let join = thread::spawn(move || {
      mutation.run(MutationPriority::Maintenance, || {
        let _ = entered_tx.send(());
        let _ = release_rx.recv();
      });
    });
    entered_rx
      .recv_timeout(Duration::from_secs(2))
      .expect("mutation blocker enters");
    Self {
      release: Mutex::new(Some(release_tx)),
      join: Mutex::new(Some(join)),
      hooks,
      waiting_baseline,
    }
  }

  fn wait_until_refresh_queued(&self, timeout: Duration) {
    self.hooks.wait_for(timeout, |data| {
      data.token_waiting_count > self.waiting_baseline
    });
  }

  fn release(&self) {
    if let Some(release) = lock(&self.release).take() {
      let _ = release.send(());
    }
    if let Some(join) = lock(&self.join).take() {
      join.join().expect("mutation blocker exits");
    }
  }
}

#[cfg(test)]
struct CoordinatorPause {
  gate: Arc<TestGateState>,
}

#[cfg(test)]
impl CoordinatorPause {
  fn release(&self) {
    self.gate.release();
  }
}

#[cfg(test)]
struct IntakeRace {
  gate: Arc<TestGateState>,
  result: Mutex<Option<Receiver<Result<Arc<LiveRateLimitSnapshot>, RefreshError>>>>,
  join: Mutex<Option<JoinHandle<()>>>,
}

#[cfg(test)]
impl IntakeRace {
  fn wait_checked(&self, timeout: Duration) {
    self.gate.wait_for(timeout, |state| state.worker_ready);
  }

  fn release(&self) {
    self.gate.release();
  }

  fn wait_result(&self, timeout: Duration) -> Result<Arc<LiveRateLimitSnapshot>, RefreshError> {
    let result = lock(&self.result)
      .take()
      .expect("intake race result receiver")
      .recv_timeout(timeout)
      .expect("intake race reports result");
    if let Some(join) = lock(&self.join).take() {
      join.join().expect("intake race thread exits");
    }
    result
  }
}

#[cfg(test)]
#[derive(Default)]
struct BackgroundShutdownState {
  result: Option<Result<Arc<ShutdownResult>, RefreshError>>,
  finished: bool,
}

#[cfg(test)]
struct BackgroundShutdown {
  state: Arc<(Mutex<BackgroundShutdownState>, Condvar)>,
  join: Mutex<Option<JoinHandle<()>>>,
}

#[cfg(test)]
impl BackgroundShutdown {
  fn start(runtime: Arc<RefreshRuntime>) -> Self {
    let state = Arc::new((
      Mutex::new(BackgroundShutdownState::default()),
      Condvar::new(),
    ));
    let thread_state = Arc::clone(&state);
    let join = thread::spawn(move || {
      let result = runtime.shutdown_and_join();
      let (lock_state, changed) = &*thread_state;
      let mut state = lock(lock_state);
      state.result = Some(result);
      state.finished = true;
      drop(state);
      changed.notify_all();
    });
    Self {
      state,
      join: Mutex::new(Some(join)),
    }
  }

  fn is_finished(&self) -> bool {
    lock(&self.state.0).finished
  }

  fn wait(&self, timeout: Duration) -> Arc<ShutdownResult> {
    let (state, changed) = &*self.state;
    let state = lock(state);
    let (mut state, timed_out) = changed
      .wait_timeout_while(state, timeout, |state| !state.finished)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(!timed_out.timed_out(), "timed out waiting for shutdown");
    let result = state
      .result
      .take()
      .expect("shutdown result")
      .expect("shutdown succeeds");
    drop(state);
    if let Some(join) = lock(&self.join).take() {
      join.join().expect("shutdown thread exits");
    }
    result
  }
}

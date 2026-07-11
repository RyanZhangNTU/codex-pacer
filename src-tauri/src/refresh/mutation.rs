use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum MutationPriority {
  Pricing,
  Maintenance,
  Refresh,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct MutationOutcome<T> {
  pub(crate) value: T,
  pub(crate) queue_wait: Duration,
}

#[derive(Clone)]
pub(crate) struct UsageMutationCoordinator {
  inner: Arc<MutationCoordinatorInner>,
}

impl UsageMutationCoordinator {
  pub(crate) fn new() -> Self {
    Self {
      inner: Arc::new(MutationCoordinatorInner {
        state: Mutex::new(MutationState::default()),
        changed: Condvar::new(),
      }),
    }
  }

  pub(crate) fn run<T>(
    &self,
    priority: MutationPriority,
    mutation: impl FnOnce() -> T,
  ) -> MutationOutcome<T> {
    let queued_at = Instant::now();
    let ticket = self.enqueue(priority);
    let slot = self.wait_for_turn(ticket);
    let queue_wait = queued_at.elapsed();

    let value = mutation();
    drop(slot);

    MutationOutcome { value, queue_wait }
  }

  pub(crate) fn run_cancellable<T>(
    &self,
    priority: MutationPriority,
    cancelled: &AtomicBool,
    mutation: impl FnOnce() -> T,
  ) -> Option<MutationOutcome<T>> {
    let queued_at = Instant::now();
    let ticket = self.enqueue(priority);
    let slot = self.wait_for_turn_cancellable(ticket, cancelled)?;
    let queue_wait = queued_at.elapsed();

    let value = mutation();
    drop(slot);

    Some(MutationOutcome { value, queue_wait })
  }

  pub(crate) fn cancel(&self, cancelled: &AtomicBool) {
    cancelled.store(true, Ordering::Release);
    let state = lock_state(&self.inner.state);
    drop(state);
    self.inner.changed.notify_all();
  }

  #[cfg(test)]
  pub(crate) fn wait_for_queued_for_test(&self, expected: usize, timeout: Duration) {
    let state = lock_state(&self.inner.state);
    let (state, timed_out) = self
      .inner
      .changed
      .wait_timeout_while(state, timeout, |state| state.queued.len() < expected)
      .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert_eq!(state.queued.len(), expected, "mutation queue length");
    assert!(!timed_out.timed_out(), "timed out waiting for mutation queue");
  }

  fn enqueue(&self, priority: MutationPriority) -> QueuedTicket {
    let mut state = lock_state(&self.inner.state);
    let ticket = QueuedTicket {
      priority,
      sequence: state.next_sequence,
    };
    state.next_sequence = state
      .next_sequence
      .checked_add(1)
      .expect("usage mutation ticket sequence overflowed");
    state.queued.push_back(ticket);
    drop(state);
    self.inner.changed.notify_all();
    ticket
  }

  fn wait_for_turn(&self, ticket: QueuedTicket) -> ActiveMutationSlot {
    let mut state = lock_state(&self.inner.state);
    loop {
      if !state.active && state.next_ticket() == Some(ticket) {
        let position = state
          .queued
          .iter()
          .position(|queued| *queued == ticket)
          .expect("selected usage mutation ticket remains queued");
        state.queued.remove(position);
        state.active = true;
        return ActiveMutationSlot {
          inner: Arc::clone(&self.inner),
        };
      }

      state = self
        .inner
        .changed
        .wait(state)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    }
  }

  fn wait_for_turn_cancellable(
    &self,
    ticket: QueuedTicket,
    cancelled: &AtomicBool,
  ) -> Option<ActiveMutationSlot> {
    let mut state = lock_state(&self.inner.state);
    loop {
      if cancelled.load(Ordering::Acquire) {
        if let Some(position) = state.queued.iter().position(|queued| *queued == ticket) {
          state.queued.remove(position);
        }
        drop(state);
        self.inner.changed.notify_all();
        return None;
      }

      if !state.active && state.next_ticket() == Some(ticket) {
        let position = state
          .queued
          .iter()
          .position(|queued| *queued == ticket)
          .expect("selected usage mutation ticket remains queued");
        state.queued.remove(position);
        state.active = true;
        return Some(ActiveMutationSlot {
          inner: Arc::clone(&self.inner),
        });
      }

      state = self
        .inner
        .changed
        .wait(state)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    }
  }
}

impl Default for UsageMutationCoordinator {
  fn default() -> Self {
    Self::new()
  }
}

struct MutationCoordinatorInner {
  state: Mutex<MutationState>,
  changed: Condvar,
}

#[derive(Default)]
struct MutationState {
  active: bool,
  next_sequence: u64,
  queued: VecDeque<QueuedTicket>,
}

impl MutationState {
  fn next_ticket(&self) -> Option<QueuedTicket> {
    let priority = self.queued.iter().map(|ticket| ticket.priority).max()?;
    self
      .queued
      .iter()
      .find(|ticket| ticket.priority == priority)
      .copied()
  }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct QueuedTicket {
  priority: MutationPriority,
  sequence: u64,
}

struct ActiveMutationSlot {
  inner: Arc<MutationCoordinatorInner>,
}

impl Drop for ActiveMutationSlot {
  fn drop(&mut self) {
    let mut state = lock_state(&self.inner.state);
    state.active = false;
    drop(state);
    self.inner.changed.notify_all();
  }
}

fn lock_state(state: &Mutex<MutationState>) -> MutexGuard<'_, MutationState> {
  state
    .lock()
    .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
  use super::{lock_state, MutationOutcome, MutationPriority, UsageMutationCoordinator};
  use std::panic::{self, AssertUnwindSafe};
  use std::sync::atomic::{AtomicBool, Ordering};
  use std::sync::mpsc::{self, Receiver, Sender};
  use std::sync::Arc;
  use std::thread::{self, JoinHandle};
  use std::time::Duration;

  const TEST_TIMEOUT: Duration = Duration::from_secs(2);

  fn wait_for_queued(coordinator: &UsageMutationCoordinator, expected: usize) {
    let state = coordinator
      .inner
      .state
      .lock()
      .expect("mutation state locks");
    let (state, timeout) = coordinator
      .inner
      .changed
      .wait_timeout_while(state, TEST_TIMEOUT, |state| state.queued.len() < expected)
      .expect("mutation state remains lockable");

    assert_eq!(state.queued.len(), expected, "queued ticket count");
    assert!(!timeout.timed_out(), "timed out waiting for queued ticket");
  }

  fn start_blocker(
    coordinator: &UsageMutationCoordinator,
    priority: MutationPriority,
  ) -> (Sender<()>, JoinHandle<MutationOutcome<()>>) {
    let coordinator = coordinator.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let handle = thread::spawn(move || {
      coordinator.run(priority, || {
        entered_tx.send(()).expect("report blocker entry");
        release_rx.recv().expect("release blocker");
      })
    });
    entered_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("blocker enters mutation closure");
    (release_tx, handle)
  }

  fn start_ordered_mutation(
    coordinator: &UsageMutationCoordinator,
    priority: MutationPriority,
    label: &'static str,
    order_tx: Sender<&'static str>,
  ) -> JoinHandle<MutationOutcome<&'static str>> {
    let coordinator = coordinator.clone();
    thread::spawn(move || {
      coordinator.run(priority, || {
        order_tx.send(label).expect("record mutation order");
        label
      })
    })
  }

  fn recv_order(order_rx: &Receiver<&'static str>) -> &'static str {
    order_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("mutation reports execution order")
  }

  #[test]
  fn mutation_priorities_order_refresh_before_maintenance_before_pricing() {
    assert!(MutationPriority::Refresh > MutationPriority::Maintenance);
    assert!(MutationPriority::Maintenance > MutationPriority::Pricing);
  }

  #[test]
  fn mutations_are_serialized() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_blocker, blocker) = start_blocker(&coordinator, MutationPriority::Maintenance);
    let (entered_tx, entered_rx) = mpsc::channel();
    let follower_coordinator = coordinator.clone();
    let follower = thread::spawn(move || {
      follower_coordinator.run(MutationPriority::Refresh, || {
        entered_tx.send(()).expect("report follower entry");
      })
    });

    wait_for_queued(&coordinator, 1);
    assert!(
      entered_rx.try_recv().is_err(),
      "follower entered concurrently"
    );

    release_blocker.send(()).expect("release active mutation");
    blocker.join().expect("blocker exits normally");
    entered_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("follower enters after blocker");
    follower.join().expect("follower exits normally");
  }

  #[test]
  fn same_priority_is_fifo() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_blocker, blocker) = start_blocker(&coordinator, MutationPriority::Refresh);
    let (order_tx, order_rx) = mpsc::channel();

    let first = start_ordered_mutation(
      &coordinator,
      MutationPriority::Maintenance,
      "first",
      order_tx.clone(),
    );
    wait_for_queued(&coordinator, 1);
    let second = start_ordered_mutation(
      &coordinator,
      MutationPriority::Maintenance,
      "second",
      order_tx,
    );
    wait_for_queued(&coordinator, 2);

    release_blocker.send(()).expect("release active mutation");

    assert_eq!(recv_order(&order_rx), "first");
    assert_eq!(recv_order(&order_rx), "second");
    blocker.join().expect("blocker exits normally");
    first.join().expect("first mutation exits normally");
    second.join().expect("second mutation exits normally");
  }

  #[test]
  fn pricing_waits_behind_refresh_mutation() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_refresh, refresh) = start_blocker(&coordinator, MutationPriority::Refresh);
    let (entered_tx, entered_rx) = mpsc::channel();
    let pricing_coordinator = coordinator.clone();
    let pricing = thread::spawn(move || {
      pricing_coordinator.run(MutationPriority::Pricing, || {
        entered_tx.send(()).expect("report pricing entry");
        "priced"
      })
    });

    wait_for_queued(&coordinator, 1);
    assert!(
      entered_rx.try_recv().is_err(),
      "pricing entered during refresh"
    );
    thread::sleep(Duration::from_millis(25));
    release_refresh.send(()).expect("release refresh mutation");

    refresh.join().expect("refresh exits normally");
    entered_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("pricing enters after refresh");
    let outcome = pricing.join().expect("pricing exits normally");
    assert_eq!(outcome.value, "priced");
    assert!(outcome.queue_wait >= Duration::from_millis(20));
  }

  #[test]
  fn higher_priority_is_selected_after_active_blocker() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_blocker, blocker) = start_blocker(&coordinator, MutationPriority::Maintenance);
    let (order_tx, order_rx) = mpsc::channel();

    let pricing = start_ordered_mutation(
      &coordinator,
      MutationPriority::Pricing,
      "pricing",
      order_tx.clone(),
    );
    wait_for_queued(&coordinator, 1);
    let refresh = start_ordered_mutation(
      &coordinator,
      MutationPriority::Refresh,
      "refresh",
      order_tx.clone(),
    );
    wait_for_queued(&coordinator, 2);
    let maintenance = start_ordered_mutation(
      &coordinator,
      MutationPriority::Maintenance,
      "maintenance",
      order_tx,
    );
    wait_for_queued(&coordinator, 3);

    release_blocker.send(()).expect("release active mutation");

    assert_eq!(recv_order(&order_rx), "refresh");
    assert_eq!(recv_order(&order_rx), "maintenance");
    assert_eq!(recv_order(&order_rx), "pricing");
    blocker.join().expect("blocker exits normally");
    pricing.join().expect("pricing exits normally");
    refresh.join().expect("refresh exits normally");
    maintenance.join().expect("maintenance exits normally");
  }

  #[test]
  fn panic_releases_mutation_slot() {
    let coordinator = UsageMutationCoordinator::new();

    let panic_result = panic::catch_unwind(AssertUnwindSafe(|| {
      coordinator.run(MutationPriority::Refresh, || {
        panic!("intentional mutation panic");
      });
    }));

    assert!(panic_result.is_err());
    let outcome = coordinator.run(MutationPriority::Pricing, || 42);
    assert_eq!(outcome.value, 42);
  }

  #[test]
  fn queued_cancellation_removes_maintenance_ticket_promptly() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_blocker, blocker) = start_blocker(&coordinator, MutationPriority::Pricing);
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker_coordinator = coordinator.clone();
    let worker_cancelled = Arc::clone(&cancelled);
    let (finished_tx, finished_rx) = mpsc::sync_channel(1);
    let maintenance = thread::spawn(move || {
      let outcome = worker_coordinator.run_cancellable(
        MutationPriority::Maintenance,
        &worker_cancelled,
        || "unexpected",
      );
      finished_tx.send(outcome).expect("report cancellation");
    });
    wait_for_queued(&coordinator, 1);

    coordinator.cancel(&cancelled);

    assert!(finished_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("queued waiter wakes")
      .is_none());
    assert!(lock_state(&coordinator.inner.state).queued.is_empty());
    release_blocker.send(()).expect("release blocker");
    blocker.join().expect("blocker exits");
    maintenance.join().expect("maintenance exits");
  }

  #[test]
  fn queued_cancellation_preserves_other_priority_and_fifo_order() {
    let coordinator = UsageMutationCoordinator::new();
    let (release_blocker, blocker) = start_blocker(&coordinator, MutationPriority::Pricing);
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancelled_coordinator = coordinator.clone();
    let cancelled_token = Arc::clone(&cancelled);
    let cancelled_handle = thread::spawn(move || {
      cancelled_coordinator.run_cancellable(
        MutationPriority::Maintenance,
        &cancelled_token,
        || "cancelled",
      )
    });
    wait_for_queued(&coordinator, 1);
    let (order_tx, order_rx) = mpsc::channel();
    let first_maintenance = start_ordered_mutation(
      &coordinator,
      MutationPriority::Maintenance,
      "maintenance-first",
      order_tx.clone(),
    );
    wait_for_queued(&coordinator, 2);
    let second_maintenance = start_ordered_mutation(
      &coordinator,
      MutationPriority::Maintenance,
      "maintenance-second",
      order_tx.clone(),
    );
    wait_for_queued(&coordinator, 3);
    let refresh = start_ordered_mutation(
      &coordinator,
      MutationPriority::Refresh,
      "refresh",
      order_tx,
    );
    wait_for_queued(&coordinator, 4);

    coordinator.cancel(&cancelled);
    assert!(cancelled.load(Ordering::Acquire));
    release_blocker.send(()).expect("release blocker");

    assert_eq!(recv_order(&order_rx), "refresh");
    assert_eq!(recv_order(&order_rx), "maintenance-first");
    assert_eq!(recv_order(&order_rx), "maintenance-second");
    assert!(cancelled_handle
      .join()
      .expect("cancelled waiter exits")
      .is_none());
    blocker.join().expect("blocker exits");
    first_maintenance.join().expect("first maintenance exits");
    second_maintenance.join().expect("second maintenance exits");
    refresh.join().expect("refresh exits");
  }

  #[test]
  fn active_cancellation_releases_slot_only_after_closure_returns() {
    let coordinator = UsageMutationCoordinator::new();
    let cancelled = Arc::new(AtomicBool::new(false));
    let active_coordinator = coordinator.clone();
    let active_cancelled = Arc::clone(&cancelled);
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let active = thread::spawn(move || {
      active_coordinator.run_cancellable(
        MutationPriority::Maintenance,
        &active_cancelled,
        || {
          entered_tx.send(()).expect("report active entry");
          release_rx.recv().expect("release active mutation");
          "finished"
        },
      )
    });
    entered_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("maintenance owns slot");
    coordinator.cancel(&cancelled);

    let (follower_tx, follower_rx) = mpsc::sync_channel(1);
    let follower_coordinator = coordinator.clone();
    let follower = thread::spawn(move || {
      follower_coordinator.run(MutationPriority::Refresh, || {
        follower_tx.send(()).expect("report follower entry");
      })
    });
    wait_for_queued(&coordinator, 1);
    assert!(follower_rx.try_recv().is_err(), "active closure still owns slot");

    release_tx.send(()).expect("release active closure");
    follower_rx
      .recv_timeout(TEST_TIMEOUT)
      .expect("follower enters after active closure returns");
    assert_eq!(
      active
        .join()
        .expect("active thread exits")
        .expect("active mutation had acquired slot")
        .value,
      "finished"
    );
    follower.join().expect("follower exits");
  }
}

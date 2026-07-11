#[cfg(test)]
use std::sync::Arc;

#[cfg(target_os = "macos")]
use objc2::{
  rc::Retained,
  runtime::{NSObjectProtocol, ProtocolObject},
};
#[cfg(target_os = "macos")]
use objc2_foundation::{NSActivityOptions, NSProcessInfo, NSString};

pub(crate) trait ActivityGuard {}

pub(crate) trait ActivityFactory: Send + Sync {
  fn begin(&self) -> Box<dyn ActivityGuard>;
}

#[derive(Default)]
pub(crate) struct SystemActivityFactory;

impl ActivityFactory for SystemActivityFactory {
  fn begin(&self) -> Box<dyn ActivityGuard> {
    Box::new(SchedulerActivity::begin())
  }
}

#[cfg(target_os = "macos")]
struct SchedulerActivity {
  activity: Retained<ProtocolObject<dyn NSObjectProtocol>>,
}

#[cfg(target_os = "macos")]
impl SchedulerActivity {
  fn begin() -> Self {
    let reason = NSString::from_str("Codex Pacer background refresh");
    let activity = NSProcessInfo::processInfo()
      .beginActivityWithOptions_reason(NSActivityOptions::Background, &reason);
    Self { activity }
  }
}

#[cfg(target_os = "macos")]
impl ActivityGuard for SchedulerActivity {}

#[cfg(target_os = "macos")]
impl Drop for SchedulerActivity {
  fn drop(&mut self) {
    unsafe {
      NSProcessInfo::processInfo().endActivity(&self.activity);
    }
  }
}

#[cfg(not(target_os = "macos"))]
struct SchedulerActivity;

#[cfg(not(target_os = "macos"))]
impl SchedulerActivity {
  fn begin() -> Self {
    Self
  }
}

#[cfg(not(target_os = "macos"))]
impl ActivityGuard for SchedulerActivity {}

#[cfg(test)]
#[derive(Clone, Default)]
pub(crate) struct CountingActivityFactory {
  state: Arc<CountingActivityState>,
}

#[cfg(test)]
#[derive(Default)]
struct CountingActivityState {
  active: std::sync::atomic::AtomicU64,
  started: std::sync::atomic::AtomicU64,
}

#[cfg(test)]
impl CountingActivityFactory {
  pub(crate) fn begin(&self) -> Box<dyn ActivityGuard> {
    <Self as ActivityFactory>::begin(self)
  }

  pub(crate) fn active(&self) -> u64 {
    self.active_count()
  }

  pub(crate) fn started(&self) -> u64 {
    self
      .state
      .started
      .load(std::sync::atomic::Ordering::Acquire)
  }

  pub(crate) fn active_count(&self) -> u64 {
    self.state.active.load(std::sync::atomic::Ordering::Acquire)
  }
}

#[cfg(test)]
impl ActivityFactory for CountingActivityFactory {
  fn begin(&self) -> Box<dyn ActivityGuard> {
    saturating_increment(&self.state.started);
    saturating_increment(&self.state.active);
    Box::new(CountingActivityGuard {
      state: Arc::clone(&self.state),
    })
  }
}

#[cfg(test)]
struct CountingActivityGuard {
  state: Arc<CountingActivityState>,
}

#[cfg(test)]
impl ActivityGuard for CountingActivityGuard {}

#[cfg(test)]
impl Drop for CountingActivityGuard {
  fn drop(&mut self) {
    let _ = self.state.active.fetch_update(
      std::sync::atomic::Ordering::AcqRel,
      std::sync::atomic::Ordering::Acquire,
      |value| Some(value.saturating_sub(1)),
    );
  }
}

#[cfg(test)]
fn saturating_increment(value: &std::sync::atomic::AtomicU64) {
  let mut current = value.load(std::sync::atomic::Ordering::Acquire);
  loop {
    let next = current.saturating_add(1);
    match value.compare_exchange_weak(
      current,
      next,
      std::sync::atomic::Ordering::AcqRel,
      std::sync::atomic::Ordering::Acquire,
    ) {
      Ok(_) => return,
      Err(observed) => current = observed,
    }
  }
}

#[cfg(test)]
mod tests {
  use super::CountingActivityFactory;

  #[test]
  fn injected_activity_factory_counts_only_live_guards() {
    let factory = CountingActivityFactory::default();
    assert_eq!(factory.active(), 0);

    let first = factory.begin();
    assert_eq!(factory.active(), 1);
    {
      let second = factory.begin();
      assert_eq!(factory.active(), 2);
      drop(second);
    }
    assert_eq!(factory.active(), 1);
    drop(first);

    assert_eq!(factory.active(), 0);
    assert_eq!(factory.started(), 2);
  }

  #[test]
  fn lib_removes_legacy_scheduler_activity_paths() {
    let source = include_str!("../lib.rs");
    assert!(
      !source.contains("spawn_scheduler"),
      "the legacy scheduler entry point must stay removed"
    );
    assert!(
      !source.contains("run_due_background_refresh"),
      "commands and popup reads must not run legacy refresh work"
    );
    assert!(
      !source.contains("begin_scheduler_activity"),
      "runtime executors own the only refresh activity scopes"
    );
  }
}

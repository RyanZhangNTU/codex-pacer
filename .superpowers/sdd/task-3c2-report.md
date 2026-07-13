# Refresh Task 3C2 report

## Result

Refresh work now runs on three persistent named threads: one coordinator, one token worker, and one live worker. Token parsing and commit no longer delay live fetching, and the coordinator remains available while either lane executes or waits for the usage mutation lock.

Manual token and live requests return blocking tickets with typed `Result<Arc<T>, RefreshError>` outcomes. Callers that join the same generation receive the same `Arc`, including the exact `ScanResult` or live snapshot produced by that generation. Intake channels, worker channels, and waiter registries have fixed capacities. A full registry returns `Busy` instead of growing without limit.

## Runtime behavior

- The coordinator processes Task 3C1 action vectors in order and owns the only `PreparedSlot`. A parsed token payload moves from the worker to that slot, then moves once into commit or is dropped synchronously on discard. Missing, duplicate, or mismatched payload events become typed failures and cannot strand a waiter.
- Worker outcomes carry the exact completion payload. The coordinator keeps that `Arc` only while it resolves the corresponding action vector, so the runtime has no generation history or unbounded result cache.
- Token parsing happens before the refresh mutation ticket is requested. Only commit uses `UsageMutationCoordinator` at refresh priority. The worker records queue wait and rechecks shutdown plus source generation after acquiring the mutation slot.
- The live worker never takes the usage mutation lock. It calls the fetcher with the existing ten-second timeout and keeps the single fetch and persist path bounded.
- Parse, commit, fetch, and persist calls are wrapped with panic recovery. A panic resolves the affected waiters as a typed failure, clears the lane state, and leaves the persistent worker available for later requests.
- Shared status changes to running before work is dispatched. Status and metrics use atomics and fixed histogram buckets. They cover planned due time, actual worker start, start lag, duration, success age, failure streak, retry time, coalescing, missed deadlines, waiter counts, live timeouts, token work statistics, mutation wait, and database busy results. Saturating counters use compare-and-exchange loops.
- Start lag above five seconds and more than one active live executor increment fixed warning counters. Error detail is length bounded, and append-fast-path count remains zero because importer append work belongs to a later task.

## Shutdown and source changes

Shutdown is explicit and idempotent. The first call closes intake, rejects queued manual waiters with `Shutdown`, drops any prepared payload, marks the workers for shutdown, closes their command senders, drains bounded outcome channels, and joins all three threads. A repeated call returns the same completed teardown result without sending more commands.

An executor call that has already entered its body may finish during teardown, but shutdown prevents a later publish. A token worker waiting for the mutation lock checks shutdown again after it acquires the permit and skips commit when teardown has begun. Source generation is checked at the same boundary. Token commit and live persist also check for a source change before reporting success, so stale results do not resolve tickets or publish events.

## Power activity scope

The macOS activity guard now lives in `refresh/power.rs` and uses `NSActivityOptions::Background`. Guards cover only token parse, token commit, live fetch, and live persist. Mutation queue waits, coordinator waits, scheduler sleeps, cache fallback, and rendering hold no activity.

The remaining legacy paths use the same narrow guard around the combined scan body, live query, and database snapshot insert. The previous scheduler-loop guard was removed. An injectable activity factory lets the concurrency tests verify guard entry and release without depending on macOS.

## TDD record

The first focused RED run failed to compile with exit code 101 because the runtime types, activity counter, and panic hooks did not exist. The complete set of 30 required tests was then added before the implementation; that run also exited 101 on the missing runtime contracts.

The first compiling runtime suite exposed two useful ordering defects. Duplicate gate entry did not match the intended generation, and the startup-lag test was measuring coordinator setup instead of the actual worker start boundary. Later concurrency runs also exercised source changes during token commit and live persist, persisted success age after short monotonic uptime, and extreme interval timestamp conversion. Those four regressions remain as extra coverage, bringing the focused runtime suite to 34 tests.

All required cases now pass, including independent lane starts, exact shared results, one pending follow-up, bounded duplicate storms, panic recovery, disabled scheduling with manual work, start-lag warnings, mutation lock ordering, prepared-payload discard, source invalidation, bounded capacities, saturating counters, and every specified shutdown point. The activity tests also prove that queue and wait time are outside the guard.

## Verification

The final implementation passed:

```text
cargo check --manifest-path src-tauri/Cargo.toml --locked --lib
finished successfully with no warnings

cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::runtime::tests
34 passed; 0 failed

cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::power::tests
2 passed; 0 failed

cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::
114 passed; 0 failed

cargo test --manifest-path src-tauri/Cargo.toml --locked
296 library tests passed; 0 failed
main tests: 0 failed
doc tests: 0 failed
```

Scoped `rustfmt --check` passed for `runtime.rs`, `power.rs`, and `refresh/mod.rs`. `git diff --check` also passed.

An independent contract review found no unresolved Critical or Important issue in the runtime, shutdown/channel cycles, prepared ownership, result pairing, action order, source checks, panic recovery, fixed metrics, power scope, or legacy guard changes. It also repeated the refresh and full Rust suites. A separate race scan ran the saturated shutdown case 25 times without a failure.

## Deferred work and caveats

Task 3C3 still owns concrete child-process reap coverage. Task 4 owns publish-before-persist and persistence retry behavior. Task 5 owns Tauri command routing and removal of the remaining legacy refresh paths. Append parsing and frontend work also remain out of scope.

Two low-priority review notes remain. The rare partial thread-spawn failure path does not explicitly join every thread that started before the failure, although normal runtime shutdown joins all three. Event sink callbacks are trusted not to panic or re-enter the runtime. Neither affects the required Task 3C2 paths or the verified teardown behavior.

## Self-review

- Exactly three long-lived runtime threads are created, with no thread per trigger or generation.
- The coordinator never runs executor work or waits for the mutation lock.
- Prepared token data has one owner at every point and is dropped on discard, stale work, failure, or shutdown.
- Successful tickets are paired with their generation's exact immutable result.
- Public intake and waiter registration are linearized with shutdown and remain bounded.
- Live execution stays independent of token parsing and commit.
- Activity guards exclude coordinator wait, mutation wait, scheduler sleep, rendering, and cache fallback.
- No importer, frontend, Task 4 persistence semantics, or Task 5 command routing was added early.

No unresolved Task 3C2 defect is known.

# 2.3.0 performance evaluation

Measured on 7 October 2026, macOS 27.0.1, arm64. This is development validation, not a release or installed-app upgrade.

## Measurement and interpretation

The default Balanced mode did not show a large increase in main-process cost in this bounded workload. More Responsive roughly doubled interrupt wakeups compared with Balanced. Energy Saving reduced wakeups, but its short-window CPU/energy differences were small and noisy; it should not be described as a measured battery-life improvement. Retain Balanced by default and expose all three modes for the user's tradeoff.

The table uses read-only Darwin `proc_pid_rusage` counters over approximately 31 seconds per run. CPU is a percentage of one core; joules come from the system's `ri_energy_nj` estimate. They are not wall-meter readings or battery discharge measurements. Daily figures assume 8 hours with 10% active work and 90% idle, using the measured process power in each state:

`daily Wh = 8 × (0.1 × active W + 0.9 × idle W)`

| Build/mode | Active CPU | Interrupt wakeups/s | Estimated active process power | Estimated 8-hour mixed use |
| --- | ---: | ---: | ---: | ---: |
| 2.2.2 baseline | 0.044% | 6.64 | 0.0243 W | 0.023 Wh |
| 2.3.0 Energy Saving | 0.037% | 3.73 | 0.0192 W | 0.017 Wh |
| 2.3.0 Balanced | 0.028% | 4.58 | 0.0199 W | 0.018 Wh |
| 2.3.0 More Responsive | 0.077% | 9.41 | 0.0376 W | 0.032 Wh |

The measured idle process power was approximately 0.00046 W for the baseline and 0.00027 W for the candidate, with about 0.3 interrupt wakeups/s. These very small short-window estimates have substantial relative uncertainty. Continuous active use for 8 hours extrapolates to about 0.16 Wh in Balanced and 0.30 Wh in More Responsive. Neither extrapolation includes the cost of the rest of the machine.

Each isolated app received the same synthetic Desktop IPC input: one request per 10 seconds, nonempty text patches at about 20/s from seconds 2–8, 600 output tokens including 200 reasoning tokens, followed by atomic final usage/completion and matching JSONL accounting. Each active measurement settled three requests. Idle measurements had no request traffic. Request logs, sockets, bundle ID, executable, singleton lock, preferences and cache paths were separate from production. Quota was a fixed synthetic snapshot and Sparkle/SSH were disabled in the QA copy. The original installed 2.2.2 build 34 process remained running.

The `--expanded` argument initially pins active runs; mouse actions outside the island can still collapse it. Presentation state, background load and thermal state were not continuously fixed or recorded. Treat the comparison as an order-of-magnitude check of the supplied input, not a calibrated expanded/collapsed battery benchmark. Startup, real quota RPC/history/chart work, WindowServer/GPU display energy, other local processes, network and all SSH-host energy are outside this estimate. Multiple simultaneous tasks and large tool logs can cost more. An early baseline was repeated after background compilation ended; UI-interactive samples are excluded from the energy table.

## Accuracy and functional acceptance

- A request can produce settled TPS from its first usage report; it does not require a second cumulative count. Reasoning is already part of output and is not added again.
- Actual native IPC plus matching request logs produced **74.9 t/s and 2.04 s first-output latency** in the final app for the known 600-token, approximately eight-second response with its first text sent at approximately two seconds. This checks the complete transport/model/presentation path, with sender scheduling and client delivery included.
- Native patches containing final output, usage and completion together settle accounting before task release. Empty text, cached hydration, unknown starts, retired turns, duplicate response IDs, partial windows and large numeric sums have regression coverage.
- Per-task values remain on retained completion cards. Numeric-only late accounting cannot create activity, change unread state, extend retention, revive a dismissed card or cross host/turn identity. Same-turn reconnect preserves already observed metrics while rejecting new partial timing; a new turn clears them.
- On the actual 6000 Linux host, a Pacer-owned temporary synthetic rollout produced inotify notifications, incremental sanitized accounting and watch release; the fixture was automatically deleted. A separate authorized read-only metadata query found one currently loaded real conversation and one valid rollout path on that host; only aggregate counts were returned. Local mock app-server/socket tests exercise discovery, batching, EOF and helper ownership. No user chat messages were sent.
- English and Chinese Settings, Adaptive Floating/Notch rows, completed-card metrics, Save and a normal-quit/relaunch preference roundtrip were observed in the isolated macOS app. This does not establish Intel hardware, older macOS, other displays or an installed production upgrade.

The complete test run covered the application suites. Its one obsolete terminal-batching assertion was updated to check immediate completion separately while retaining the 512/513 ordinary-event boundary; that suite then passed. Final accounting/reconnect/aggregate edits received affected regression checks. There are 252 covered tests across the full run and affected reruns, with no compiler warnings observed. Repeating unchanged passing suites, full updater QA or DMG installation was outside this feature's validation scope.

## Reproduction and receipts

The preserved baseline is `develop` commit `8b70709e20b27ac99154cc5865eabf7bd9f3b109` (2.2.2 build 34). The final candidate is 2.3.0 build 35. Production native-source SHA-256, excluding tests and generated artifacts:

`c58c543b8b83a19e1c10b2d78c553333400bf14b67bcca446953791c802a7498`

The QA copy differs only in its independent identity/cache/lock, disabled preference migration/updater, and synthetic quota hook. Those changes were checked against the production source. No QA-only code is shipped.

```sh
xcrun clang -Wall -Wextra scripts/performance/process-energy.c -o /private/tmp/pacer-process-energy
python3 scripts/performance/profile-island.py \
  --app '/path/to/isolated/QA.app' --sampler /private/tmp/pacer-process-energy \
  --mode balanced --workload active --expanded --seconds 30 \
  --output output/performance/2.3.0/replay.json
```

Use only a QA app with a separate bundle identifier/executable/cache/lock, no production preference migration, disabled live quota/updater/SSH, and the temporary `--energy-fixture` quota hook. The profiler refuses the production identity. The ordinary 10-second request cycle is used for energy runs; `--turn-seconds 30` holds a completed card longer for UI acceptance. The profiler launches and stops only its own child app and deletes its own synthetic home. Raw counters and receipts remain ignored under `output/performance/2.3.0/`.

The existing compatibility-Python event replay also retained projected-state/event equivalence for body and body/count patches. Its timings were effectively unchanged; that component check is separate from the native-app measurements above.

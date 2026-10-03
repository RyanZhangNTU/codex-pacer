# Performance measurements

## 2026-10-03: chart invalidation and Desktop IPC projection

Two hot paths were reduced without changing the refresh cadence or presentation:

- The chart compares its rendered points, cycle boundaries, expiry markers, detail completeness and accent. Task events and clock ticks no longer rebuild it when those values are unchanged. New samples, resets and expiry boundaries still invalidate it; hover/tap state remains local to the chart.
- Desktop IPC validates and projects the entire patch batch before copying history. Body-only batches advance the revision and emit the same activity events without copying the projected history. Batches that change tracked fields still copy and apply atomically; malformed batches leave state untouched.

SSH collection, quota polling, persistence, notifications and task destinations are unchanged. These measurements do not establish a reduction in SSH or disk I/O cost.

### Native UI replay

Baseline: `8cb9211b5189ede776dcd8a18d0c587a81d09ee1`. Both builds used the actual SwiftUI views in an isolated replay app, with the same two tasks, 187 initial chart points, four update batches per second, 440 × 466 point panel, Liquid Glass settings and fixed backdrop. One reset credit expired at 20 seconds; quota changed at 30 seconds.

On Apple Silicon with macOS 27.0.1, each app warmed up for 10 seconds, then measured for 45 seconds. This is one sequential A/B pair, not a distribution across machines or production workloads.

| Metric | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Average process CPU, 100% = one core | 7.63% | 2.08% | 72.8% |
| Physical footprint, sampled median | 297.94 MiB | 34.72 MiB | 88.4% |
| Physical footprint, sampled maximum | 298.08 MiB | 296.50 MiB | 0.5% |
| Chart body evaluations | 180 | 2 | 98.9% |

The memory peak remains. Avoiding continuous chart reconstruction lets the footprint fall between relevant updates; it does not eliminate the transient allocation when the chart changes. Physical footprint includes memory charged to the process, including graphics allocations, and differs from RSS. CPU excludes other processes such as WindowServer. Memory was sampled once per second, so the maximum is not an exact transient peak.

The replay recorded zero physical reads in both runs and 0 / 622,592 physical write bytes before/after. It does not run business persistence; incidental framework/cache writes are not evidence of a production I/O improvement.

The final 880 × 934 content captures were pixel-identical (821,920 pixels). `NSHostingView` content capture does not fully capture WindowServer glass/backdrop effects and is not an interactive hover or deep-link test.

### Desktop IPC event replay

The script loads the actual embedded Python probe code from both source trees and alternates their execution order. Each synthetic turn contains 32 projected items. Values below are median CPU milliseconds per batch, using Python 3.9.6.

| History | Batches per workload | Body only, before → after | Body + token counter, before → after |
| --- | ---: | ---: | ---: |
| 8 turns | 150 | 0.432 → 0.013 ms | 0.423 → 0.425 ms |
| 64 turns | 100 | 3.271 → 0.021 ms | 3.301 → 3.319 ms |
| 256 turns | 60 | 13.528 → 0.064 ms | 14.428 → 14.250 ms |

Body-only batches became 97.0–99.5% cheaper in these fixtures. Mixed batches were effectively unchanged. This is a component result, not an equivalent whole-app speedup. All 620 batches produced identical projected state and normalized events; only wall-clock event timestamps were excluded from comparison.

### Verification and limits

All 128 native tests passed, including new coverage for body-only activity/revision behavior, malformed-batch rollback, expiry boundaries and chart invalidation. The production app built successfully and passed strict ad hoc signature verification. The installed 2.0.0 app was not replaced for these measurements.

Long-running production sessions, energy/GPU time, other macOS versions, and real SSH workloads were not re-benchmarked. The remaining memory spikes and the mixed-patch history copy are candidates for subsequent profiling.

## Reproduce

From the repository root, create a baseline source tree and compare event processing:

```sh
baseline_dir="$(mktemp -d /private/tmp/pacer-baseline.XXXXXX)"
git archive 8cb9211b5189ede776dcd8a18d0c587a81d09ee1 native | tar -x -C "$baseline_dir"
python3 scripts/performance/benchmark-events.py \
  --baseline "$baseline_dir" --candidate . \
  --output output/performance/events.json
```

Build both replay apps with the same harness and compiler:

```sh
bash scripts/performance/build-ui-replay.sh "$baseline_dir" before output/performance/ui 45
bash scripts/performance/build-ui-replay.sh . after output/performance/ui 45
```

Launch the printed app paths in Finder **one at a time**, keeping the display awake and visible with comparable background activity. Each exits after warmup and measurement, writing JSON and a PNG to the output directory. Use fresh labels or clear only the corresponding replay app preferences when changing fixtures. Repeat in alternating order for stronger estimates.

The harness builds in `/private/tmp`, uses synthetic data and separate bundle IDs, and does not connect to Codex, read credentials or replace the installed app. The chart counter is injected only into the temporary source copy. CPU uses `proc_pid_rusage` with Mach timebase conversion; JSON/PNG export starts after measurement. Raw results belong in the ignored `output/` directory.

# 2.3.1 energy check

Measured on 8 October 2026, macOS 27.0.1, arm64. The baseline is published 2.3.0 build 37 (`e4ab14f`); the candidate is locally installed 2.3.1 build 42 (`0464620`). This checks the subagent, retained TPS, freshness and first-output fixes against the shipped automatic five-second collapsed / one-second expanded policy.

## Result and limits

The sampled app stayed at low CPU and wakeup rates. Idle cost did not increase. Single-task activity has a small reproducible CPU increase, approximately 0.12 percentage points collapsed and 0.15 points expanded, or 18% and 8% relative to the baseline respectively. Four-agent CPU was lower in the initial paired runs. These are percentages of one CPU core, not percentages of the whole machine.

The measurements do not establish identical energy consumption. Single-task system-estimated process power rose by roughly 0.9 mW. Four-agent and idle energy readings varied substantially across short windows, and all samples are retained. No battery-life percentage or whole-machine wattage is inferred. The observed local cost does not justify restoring an energy-mode setting, but this is a bounded workload check rather than a long-term battery or memory-leak test.

## CPU-accounting calibration

The previous sampler used raw Darwin CPU times as nanoseconds. On this host they are Mach time units with a `125/3` timebase. An independent process burned one CPU-second, measured with `CLOCK_PROCESS_CPUTIME_ID`, while remaining alive for both counter reads. The old interpretation returned 0.024000455 seconds; the converted sampler returned 1.000021625 seconds. `process-energy.c` now converts with `mach_timebase_info`, records that scale, and retains unscaled nJ energy counters.

The historical [build 35 report](https://github.com/RyanZhangNTU/codex-pacer/blob/v2.3.1/docs/performance-2.3.0.md), retained in tagged source, has its CPU column corrected from the preserved raw samples. Its energy figures are unchanged. It is not the baseline for this comparison.

Apple's [XNU recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md) describes per-task CPU and energy accounting, including energy estimates in nanojoules on ARM64. `ri_energy_nj` is a process CPU-energy estimate; it does not include all display, GPU, network, remote-host or battery costs. Per-process energy can vary with core scheduling even when measured CPU seconds are similar. New raw samples also retain P-core CPU and energy counters for attribution.

## Matched workload

Each variant used a separately built QA app with an independent bundle, executable, cache and singleton lock. Preference migration and Sparkle were disabled. Quota was synthetic, SSH and notifications were off, and `CODEX_HOME` contained only disposable synthetic logs and an IPC socket. The production app remained running and its saved settings were preserved.

The initial matrix contains two runs of each variant for each of four conditions: idle collapsed, one active task collapsed, one active task expanded, and one parent plus three active children expanded. Each requested 30-second window lasted approximately 32 seconds. Both variant order and condition order were reversed in the second pass. Builds and interactive UI checks occurred outside the paired measurement windows.

Active requests start every ten seconds. Each agent receives about 20 nonempty text patches per second during seconds 2–8, then final usage/completion and matching JSONL accounting for 600 output tokens, including 200 reasoning tokens. Four agents therefore produce about 80 patches per second in total. Both versions receive the same parent metadata and traffic; the baseline presents separate task roots while the candidate groups the children. Each initial active window settled three requests per agent. Packet counts differed by less than 1% due to sender scheduling.

A QA-only `QA_PRESENTATION true/false` hook records initialization and every expansion transition. Every accepted matrix sample recorded its intended state throughout; errors were empty and settlement counts matched. This removes the presentation ambiguity in the older build 35 measurements. No QA hook is shipped.

### Initial paired samples

CPU, wakeups and footprint below are arithmetic means of the two runs. Footprint is `ri_phys_footprint`, not RSS, although the sampler's legacy JSON field is named `rss`.

| Condition | 2.3.0 CPU | 2.3.1 CPU | 2.3.0 wakeups/s | 2.3.1 wakeups/s | 2.3.1 footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Idle, collapsed | 0.068% | 0.047% | 0.34 | 0.31 | 20.0 MiB |
| One task, collapsed | 0.662% | 0.781% | 0.65 | 0.97 | 21.4 MiB |
| One task, expanded | 1.830% | 1.976% | 1.93 | 1.95 | 27.3 MiB |
| Parent + three children, expanded | 3.062% | 2.504% | 2.18 | 2.09 | 28.0 MiB |

| Condition | 2.3.0 process power range | 2.3.1 process power range |
| --- | ---: | ---: |
| Idle, collapsed | 0.063–2.527 mW | 0.086–0.100 mW |
| One task, collapsed | 1.710–2.149 mW | 2.692–2.915 mW |
| One task, expanded | 7.410–7.646 mW | 8.302–8.585 mW |
| Parent + three children, expanded | 18.454–19.688 mW | 17.445–33.242 mW |

The baseline's second idle window and the candidate's second four-agent window have higher energy despite low/lower CPU. They are retained, not discarded or used to claim a precise energy regression. Every initial window recorded zero storage-layer read/write bytes for the QA main process; cached logical reads are outside those disk counters.

### Longer four-agent check

The energy variation justified one additional pair with a requested 60-second window, candidate first and baseline second. Each actually lasted about 62 seconds, settled 24 requests and verified expanded presentation without errors.

| Variant | CPU | Wakeups/s | Estimated process power | P-core share of CPU time | P-core share of estimated energy |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2.3.1 build 42 | 2.879% | 2.74 | 18.219 mW | 42.8% | 81.3% |
| 2.3.0 build 37 | 2.913% | 3.04 | 21.000 mW | 46.5% | 85.1% |

This pair did not reproduce the candidate's higher short-window energy. It supports the absence of a persistent large increase for this fixture; it is still only one longer pair. P-core accounting shows why CPU seconds and energy are separate measurements, but cannot retroactively attribute the earlier outlier because those initial samples did not record P-core counters. The initial range table and daily estimate remain intact.

## Installed app and SSH collectors

Two additional 30-second samples observed the actual installed app during ordinary live activity. They are a sanity check with real quota, history and SSH enabled, not a matched old/new energy comparison. The actual macOS UI confirmed collapsed and pinned expanded states before and after sampling. Settings were opened only after measurement; cancellation restored the original collapsed state without saving preferences.

| State | Pacer CPU | Pacer + owned local collectors CPU | Combined process power estimate | Pacer footprint |
| --- | ---: | ---: | ---: | ---: |
| Collapsed | 0.516% | 0.632% | 1.555 mW | 65.1 MiB |
| Expanded | 1.481% | 1.566% | 4.912 mW | 66.7 MiB |

The observed process IDs were stable within each window. Each contained one Pacer and one owned Codex collector, plus two SSH processes collapsed and three expanded. The third SSH source was reconnecting between windows. No QA process remained afterwards. Pacer itself recorded no storage writes during these samples; the owned Codex collector wrote roughly 68–76 KiB per window. Normal application startup, persisted history and live source state explain why production footprint exceeds the small synthetic QA fixture.

Read-only 30-second Linux `/proc` sampling of existing Pacer-owned `ssh-lifetime` helpers found:

| Host | Stable helper count | CPU, one core | End RSS | Logical read bytes | Storage reads/writes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4090 | 1 | below one 10 ms CPU tick in the window | 23.0 MiB | 0 | 0 / 0 |
| 6000 | 1 | 0.033% | 25.4 MiB | 331,876 | 0 / 0 |

A100 changed from zero to one helper in both attempted windows, preventing comparable CPU deltas. The production Settings page reported A100 SSH disconnected and automatic retry. Those transient samples are excluded from steady-state energy conclusions. Linux CPU/RSS are not measurements of remote-host watts. No real conversation text was read or messages sent for this energy check.

## Daily estimate and reproduction

For an illustrative eight-hour day with 90% idle and 10% active work:

`process Wh = 8 × (0.9 × idle W + 0.1 × active W)`

The candidate's initial sample ranges project to approximately 0.0028–0.0031 Wh with one collapsed task, 0.0073–0.0076 Wh with one expanded task, or 0.0146–0.0273 Wh with the four-agent expanded workload. These are extrapolations of process CPU-energy counters, not predicted battery discharge. The noisy baseline idle result prevents a credible precise day-to-day energy delta.

Production native-source SHA-256 values, excluding tests/generated outputs:

- Baseline: `683d4c75d584fc499eb79df8d46bed444e35b21c12351e95674b62f7c41cba22`
- Candidate: `e8869d1796891dde88d3e41244d638e0e60bfe6807093f4a359b5f24f642e871`

```sh
xcrun clang -Wall -Wextra -Werror scripts/performance/process-energy.c \
  -o /private/tmp/pacer-process-energy
python3 scripts/performance/profile-island.py \
  --app '/path/to/isolated/QA.app' --sampler /private/tmp/pacer-process-energy \
  --workload active --agents 4 --expanded --seconds 30 \
  --output output/performance/2.3.1/replay.json
```

The isolated app must include the synthetic quota and presentation hooks described above. The profiler refuses the production identity. Check `presentationVerified`, an empty `errors` array and the expected `fixture.settledRequests` before accepting a sample. It launches/stops only its own QA child and deletes its own synthetic home. Raw counters, the A/B plan, calibration receipts and installed/remote observations are retained under ignored `output/performance/2.3.1-energy-20261008/`. Compiler warnings were treated as errors; Python syntax and live one/four-agent fixture runs were checked. This tooling/documentation work changes no shipped app code or version and does not require a release.

# Harness validation

## Antigravity on macOS · 2026-11-26

The reviewer observed Antigravity 2.35.2 on this Mac. A new conversation appeared while its first reply was running. The observed first-output latency was 3.43 s. The task showed tool and thinking stages, a child labeled with its role, and a background wait while the child ran. Questions and approvals each produced a single request. Canceling cleared the request and showed interruption. A completed long reply kept its final rate of about 200 t/s. The measured long call had 10,468 output tokens over 3.42 s to first token and 47.27 s of streaming, about 207 t/s.

Both quota pools had a private account scope. Plugin installation and removal preserved the global config. The progress tool itself appeared as an approval. The first conversation opened after installation had no MCP tool available, and the next new conversation had it.

The isolated Mac checks used a synthetic home and excluded the reviewer's live scratch suite. All 37 Antigravity checks and all 263 WorkBuddy, progress and quota checks passed. The full suite listed 1,445 tests, with one Windows-only skip and three failing sandbox-dependent cases (process-start lookup, Darwin notification delivery and lost mouse-up). The full test build and packaged app produced zero warnings, and the packaged stdio reporter smoke test passed. The shared platform contract, its 37 tests, both Windows resource checks and the 12 web identity checks passed on Mac.

Offscreen demo renders in English and Simplified Chinese, in light and dark, covered the module library, onboarding, Settings, Help, History, both island layouts, the layout editors and the unused quota pool. The synthetic ended task showed 200 t/s. Switching to the unused pool showed full quota without a reset countdown.

**Pending live acceptance.** Choose **Yes, always allow** in Antigravity and verify that the next completed report fills the requesting task’s ring and marks the guide ready. Check the newly added cache cleanup with the installed app’s schema. Windows host integration and end-to-end verification are still pending.

## WorkBuddy, WorkBuddy AI and credits by kind (November 2026)

Both WorkBuddy builds were installed on one Windows PC, each signed in to a different account. They keep separate data folders, sign-ins, sites and link schemes, and their app icons are identical, so WorkBuddy AI reuses WorkBuddy's artwork.

| Check | Result |
| --- | --- |
| Windows engine and Core suite | 1,260 tests, 2 opt-in tests skipped, no failures. Includes the credits presentation tests: the month and the extra credits, the user's center and bar figures, lapse windows, fractional credits and hosts without groups. |
| Windows desktop integration | 38 checks passed, with five modules in the saved-settings projection. |
| Windows presentation | The settings group (Codex, Claude and DeepSeek pages, reminders and persistence) passed in both languages and themes. The quota, panel and pages checks passed. The WorkBuddy account check confirmed the credits from the synthetic bill on the settings page, in its breakdown and in Overview, the island section's reading, and that each module keeps its own account. Window-settle, capture and shared-section layout checks could not run: the PC was in use with the island hidden behind a full-screen app. CI runs them. |

Not yet checked live: a real sign-in on either site, the Mac UI, and the island layout on an unobstructed screen.

## Native WorkBuddy and the module library (November 2026)

| Check | Result |
| --- | --- |
| Windows engine and Core suite | 1,250 tests, 2 opt-in tests skipped, no failures. Includes the multi-record directory-change parser test, which fails on the earlier pointer arithmetic. |
| Windows desktop integration | 38 checks passed: preferences round trips with the new module keys, tolerant module IDs and rings, engine acknowledgement, signed app handlers from module data. |
| Windows presentation | The Harness, settings, pages, collapsed bar, panel, quota and DeepSeek groups passed, except the hover-animation check, which needs an unlocked display: Pacer stops animations while the screen is locked. |
| macOS | `make test` (1,283 tests) and `make build` passed with no warnings. Offscreen renders in English and Chinese of the module library (found and not-found tiles), the WorkBuddy page with a demo bill, Help and History (DeepSeek's and WorkBuddy's weeks) showed no clipping. With only WorkBuddy on, History shows its week instead of asking to turn a module on. |
| Live WorkBuddy 5.9.4 on Windows, read-only engine | Detected, on automatically, ready, listed as found, with its brand, website and launch data; one day of credits in the last week. |

A final independent review found that waking from sleep could repeat a low-credits notice. Sleep now keeps the last reading and its alert state on both platforms; only signing out, switching account or site, or turning the module off starts over. The same review also fixed four smaller issues:

- An unchanged week was published again on every read.
- Long sessions could drop out of the week.
- The Windows Notifications page missed credit rows that arrived after it opened.
- On the Mac, an expired sign-in kept its connected state, and detection ignored a custom data folder.

The table above includes the rerun after these fixes.

Not yet checked live: a WorkBuddy task from start to finish on the new build (it spends account credits), a real WorkBuddy sign-in, and the Mac UI on screen (the Mac stayed locked; WorkBuddy is not installed there).

## Earlier Windows runs

The shared framework was tested with four registered modules on Windows. Mac and Windows use the same Core code; Mac desktop behavior needs a Mac run.

| Source | Windows evidence |
| --- | --- |
| Codex | Real CLI with a local model fixture. Pacer received 63%, then 41%, and showed the end of the request. The fixture also checked setup and cleanup. The read-only engine connected to the installed Desktop app and observed live work. |
| Claude | Claude Code CLI 2.1.323 ran with the packaged Pacer hook and a local model fixture. Pacer showed 47% after a real MCP call and marked the task complete. Pacer also read the installed Desktop app's local history. The packaged hook and status line ran in cmd, Git Bash and PowerShell. Cloud quota, SSH, WSL and ownership use their existing regression fixtures. A new signed-in Desktop turn still needs a live test. |
| DeepSeek | An installed Desktop task went through running, waiting for input and completion. In a separate run, the installed CLI used a local model fixture and Pacer's reporter; Pacer showed 29% and sent the completion notice. |
| WorkBuddy AI 5.9.4 | The Windows settings switch installed the tool. After first-use trust, an explicitly prompted task sent 37% and 73% to Pacer while running. A normal home-screen task reached completion but skipped the tool. Pacer also recovered a pending question after restart without a second alert, recognized a manual stop, showed session credits and reopened the original chat. A separate fixture covers local automation runs. |
| Capacity | 100 test modules sent 800 tasks through the Windows engine. The bounded frame included every module; disabling one left the other 99 in place. Settings saved and loaded 100 additional module choices. This does not measure 100 installed apps reading their own data at the same time. |

The earlier Windows engine run had 1,230 tests, with two opt-in tests skipped and no failures. After the watcher changes, the full run had one failure in the notification registry's repeated-write test. The same case passed on rerun with 23 other targeted checks. After the progress changes, 37 targeted engine and Core tests passed. The shared-platform contract and 38 desktop checks passed. Windows settings and progress checks also passed. The longer island test missed the completion animation peak with both the candidate and installed 4.4.3.

A WorkBuddy task set to Deepseek-V4.1-Flash at High recorded output token counts for three responses. The final task row rendered the full model name, High and 6.8 t/s. The rate calculation excluded the tool waits. The engine also reported Automatic and a rate for a separate task set to Auto. All 44 targeted tests passed.

Two WorkBuddy test turns recorded 0.57 and 1.69 credits. The Windows task row rendered 0.57 credits alongside the model, effort and rate. Tests also covered a charge arriving after the turn ended, two sessions with the same request ID, a new turn in the same session and a recorded zero. All 50 targeted tests passed.

For the resource comparison, use the installed Windows x64 4.4.3 release (build 85) and a local Release candidate with the pinned toolchains. Alternate runs on the same machine. Let the processes settle and sample for at least 120 seconds. Compare the original three modules with WorkBuddy off first. Then enable WorkBuddy, use a disposable SQLite database and transcript, and confirm the engine sees both running and completed test sessions without a manual refresh. For the WPF shell, use one immutable reference snapshot and reject samples if the window is obscured. Record the median private commit, peak commit, working set, CPU as a share of one logical core and read/write byte counts.

Windows process I/O counts include cached reads and pipes. Compare the pipe bytes separately and verify the WorkBuddy database and WAL stay unchanged in the idle run. Use an elevated Windows Performance Recorder disk I/O trace to measure actual disk traffic. The Windows account on this test machine could not start the trace. [WPR profiles](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/built-in-recording-profiles) · [Kernel tracing permissions](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-starttracea)

For the physical disk comparison, record one isolated workload at a time with the WPR Disk I/O profile. In Windows Performance Analyzer, filter the Disk Usage table to the test process IDs and sample interval. Compare read and write bytes separately and keep the trace out of release assets. [WPA Disk Usage](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/optimizing-performance-and-responsiveness-exercise-2#step-5-analyze-process-disk-usage)

The Windows x64 candidate engine executable was 36.49 MiB; the installed 4.4.3 engine was 34.79 MiB. This is the size of one executable, separate from runtime disk traffic and the size of the full installer.

With the original three modules in the collapsed workload, the first comparison found 0.29 MiB more median private commit on average. The candidate now keeps the previous snapshot as bytes and uses smaller Windows buffers for single-file watches. In two new 120-second runs per build, CPU was 1.30–1.32% of one core on 4.4.3 and 0.86–0.94% on the candidate. The mean of the two private-commit medians fell from 10.29 to 10.18 MiB, with overlapping ranges. The average working set fell from 37.11 to 35.10 MiB and the highest peak commit from 14.94 to 13.44 MiB. Process reads were about 31.5 KiB per run. In all four runs, every counted write byte was a snapshot sent to the host over the pipe.

With the expanded workload, engine CPU was 2.12% of one core on 4.4.3 and 1.32% on the earlier candidate with the original three modules. Those runs measured 10.87 and 10.59 MiB of median private commit. The latest candidate with WorkBuddy enabled used 1.30% of one core and 10.50 MiB. The engine saw all four synthetic WorkBuddy sessions running and completing without a manual refresh. The WorkBuddy run counted 226.7 KiB of process reads in two minutes, compared with 14.4 KiB in the earlier three-module candidate run. Every counted write byte in the latest run was a snapshot sent over the pipe.

In the 120-second idle comparison, CPU was 0.18% of one core on 4.4.3, 0.23% with the original three modules on the latest candidate, and 0.13% with WorkBuddy added. Median private commit was 6.41, 6.33 and 7.27 MiB, respectively. All three recorded zero process read bytes. The WorkBuddy database and WAL matched their pre-sample hashes.

The first WPF shell comparison showed a memory increase. In the repeat, both runs used the same 4.4.3 engine, .NET runtime, native graphics binaries and fixed snapshot. Swapping only the WPF assembly changed collapsed private commit from 106.83 to 105.61 MiB and expanded private commit from 120.43 to 120.12 MiB. The shell used at most 0.21% of one core and logged no read or write operations in any of these fixed-data samples. This isolates the shell assembly; it does not replace a full application resource trace.

After the home-screen task and progress receipt fixes, we repeated the collapsed Windows engine comparison. Each row is a 120-second sample after a 15-second warm-up. CPU is a share of one logical core. Memory is median private commit.

| Time between fixture updates | Engine | CPU | Memory | Process reads |
| --- | --- | ---: | ---: | ---: |
| 3 seconds | Installed 4.4.3 | 1.24% | 11.08 MiB | 31.5 KiB |
| 3 seconds | Candidate, WorkBuddy off | 0.78% | 9.25 MiB | 31.5 KiB |
| 3 seconds | Candidate, WorkBuddy on | 0.99% | 10.99 MiB | 294.4 KiB |
| 7 seconds | Installed 4.4.3 | 0.90% | 9.48 MiB | 13.4 KiB |
| 7 seconds | Candidate, WorkBuddy on | 0.78% | 9.78 MiB | 236.5 KiB |

The first four-module run with three-second updates missed Codex's running state and failed the fixture check. The repeat saw all four WorkBuddy sessions complete and two running. With seven-second updates, all four WorkBuddy sessions were observed running and completing. In those completed samples, all counted writes were snapshots sent over the pipe. The comparison used read-only engine diagnostics. Physical disk traffic and the WorkBuddy MCP process still need measurement. The memory and read counts with WorkBuddy on do not establish resource parity with 4.4.3.

After adding per-turn credits, a Windows x64 Release smoke test used 45-second samples of the collapsed engine with synthetic Claude and DeepSeek tasks. The WorkBuddy sample added four local tasks with credits.

| Engine | CPU, one core | Median private commit | Median working set | Process reads |
| --- | ---: | ---: | ---: | ---: |
| 4.4.3 | 0.87% | 8.69 MiB | 32.92 MiB | 5.1 KiB |
| Candidate, WorkBuddy off | 0.80% | 8.19 MiB | 32.61 MiB | 5.1 KiB |
| Candidate, WorkBuddy on | 0.80% | 8.53 MiB | 33.75 MiB | 148.9 KiB |

All counted writes in these samples went to the host pipe. A separate 40-second Debug comparison with WorkBuddy on in both builds read 164.8 KiB per run before and after the credits change. The candidate had a larger working set. In a follow-up sample, about 6.8 MiB of the difference came from pages backed by the engine executable. These samples cover the Windows engine. They do not measure physical disk traffic or the entire app.

## Unified activity entry points

The Windows engine fixtures exercised the installed 4.4.3 build and the candidate. Codex, Claude and DeepSeek kept the same task IDs through completion. In the candidate, switching each one off and on left the other modules visible, and finished tasks survived sleep and wake. The full engine run before the account credits changes ran 1,236 tests with no failures and two opt-in checks skipped.

Two 120-second samples per build used the same three active modules. CPU used 0.70 to 0.81% of one core on 4.4.3 and 0.68 to 0.91% on the candidate. Median private commit ranged from 9.13 to 9.99 MiB on 4.4.3 and 8.67 to 9.04 MiB on the candidate. Process reads were 13.4 to 16.7 KiB and about 13.4 KiB, respectively. One sample with WorkBuddy enabled read 238.7 KiB. These are process counters, which can include cached reads. No further storage samples were taken after shifting the work back to features.

## Account credits and app icons

The Windows UI test signed in to an intercepted WebView2 page and used a synthetic bill. Settings, Overview and the expanded island showed the same available balance. The test checked the plan allowance and reset, a separate add-on expiry, and whether a transient outage left the last balance marked as stale. It also checked hiding and restoring the WorkBuddy dial, clearing it on sign-out, and isolating the two login sites. With all four services enabled, both quota styles put the dials in two columns under Quota & Balance and showed the official app icons. The task row test checked per-turn credits, model, effort, throughput and progress.

The Windows shared-engine run passed 43 tests. The Windows presentation run passed the Harness, expanded panel, quota and settings groups. WorkBuddy account balances were verified against the fixture. A real WorkBuddy sign-in and macOS UI acceptance remain to be checked.

For Mac acceptance, run `make test` and `make build`. Check each module in the native UI, including WorkBuddy progress, returning to a chat, restoring a pending question after restart and showing account credits after a real sign-in.

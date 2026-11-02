# Windows shell development

The WPF shell renders the shared engine's presentations over protocol version 1. Build it on Windows x64 with the tools pinned in `windows/toolchain-lock.json`; engine setup is described in [windows-engine.md](windows-engine.md).

```powershell
./scripts/windows/build-desktop.ps1 -Configuration Release
./scripts/windows/test-desktop.ps1 -Configuration Release
./scripts/windows/test-presentation.ps1 -Configuration Release
./scripts/windows/package-preview.ps1 -SkipBuild
```

The unsigned ZIP and SHA-256 file are written under `output/windows`. The `windows-app-x64-unsigned` CI artifact contains both. Packaging validates the extracted application with a restricted runtime environment, Unicode paths, demo capture, and single-instance activation. It does not create a tag or release. The shipping Mac package and release workflow are unchanged.

For local toolchains outside the worktree, set `PACER_SWIFT_ROOT`, `PACER_WINDOWS_SDK_ROOT` and `PACER_DOTNET_ROOT` before running the scripts. They identify existing installations; build outputs, NuGet packages and source snapshots stay under the worktree or its configured temporary directory. Generated UI strings and DeepSeek scripts come from Core resources; `python scripts/windows/build-shell-resources.py --check` checks them.

## Presentation and request handling

Snapshots supply task labels, counts, rates, quota and wallet projections. The additive read-only methods `projectCompactBar` and `layoutQuotaChart` call `CompactBarPresentation` and `QuotaCycleChartPresentation` in Core. WPF handles drawing and input. `PacerWindowsBridge` supplies UI geometry, finite motion and native application activation; it does not calculate quotas, billing or compact component rules.

All engine requests are asynchronous. Ordinary commands have a 15-second deadline; presentation queries have a 3-second deadline. The deadline includes waiting for the write gate, writing the command and receiving its result. The hello handshake has a 10-second deadline. An engine exit fails pending requests. Rendering reads a bounded cache and returns immediately; identical requests share one pending operation. Failed inputs are not retried by repainting. A missing or failed projection shows a loading/error placeholder, and settings edits report failure without saving an incomplete layout.

`SlowEngineChecks` tests silent, slow and exiting engines. It checks dispatcher heartbeats, immediate rendering, visible errors, bounded request counts and rejection of late responses. Pipe readers await input; animation subscriptions end when motion settles. There is no request polling loop.

The island retains a transparent HWND canvas across transitions, so its native rectangle can remain large after the visible panel closes. Its root UIA `ExpandCollapse` pattern reports the logical state and supports reveal/close actions. Input tests should read that state alongside the bounds, rather than infer expansion from the HWND size alone. Hover exit keeps the existing 0.4-second grace period used by the Mac model.

Opaque WPF windows use per-window `HwndTarget.RenderMode = SoftwareOnly`. This covers Settings, login windows and their dialogs, including browser host windows. On the development machine, the default hardware path produced an empty client area in ordinary WPF windows; software rendering restored content and input. The machine has multiple physical and virtual display adapters, but the fault has not been isolated to a driver. The layered Black island keeps its existing rendering mode. This changes WPF client drawing only; it does not change system graphics settings, window materials or WebView2's browser rendering. Settings captures record the actual mode, and presentation tests assert both policies. Software rendering uses CPU for these mostly static windows; measure it with Settings open before extending this policy to animated surfaces.

## Local acceptance

Use demo data for screenshots and interaction checks:

```powershell
./windows/Desktop/bin/Release/net10.0-windows/CodexPacer.exe --demo --language en --theme light --collapsed
```

`--theme light|dark` is a demo-only override. Repeat with `--language zh-Hans` and dark appearance. Check hover expansion, click to pin, Esc and opening Settings. Use `--demo --reference-fixture --activation-qa <unique-guid>` to isolate activation tests from an existing user instance. Close only the instance started for the check.

The engine can be sampled without opening the shell:

```powershell
python scripts/windows/check-engine-idle.py --engine <engine-path> --seconds 300 --real-data --output output/windows/engine-real-idle.json
```

This option reads real sources for at least five minutes, does not change source configuration or record protocol bodies, and reports engine CPU and shutdown time. The default mode uses empty provider homes. CPU results cover the engine process; they do not establish complete feature acceptance. Record manual evidence in `windows/platform-coverage.json` without promoting features whose remaining requirements are untested.

# Getting Started

## What Codex Pacer is for

**Codex Pacer** is a local-first desktop app for understanding Codex usage as pace, value, and session-level activity.

It is built to help you answer practical questions such as:

1. Am I pacing this quota window well before reset?
2. How much API-equivalent value have I already extracted from my subscription?
3. Which sessions, models, or subagents are consuming the most usage?

## Requirements

- Apple Silicon macOS for the stable packaged app, or Windows for the test-stage installer
- Local Codex data under `~/.codex` or a custom `CODEX_HOME`

For development from source, you will also need:

- Node.js 20+
- Rust toolchain
- Tauri build prerequisites for your platform

## Install the stable app

Official public downloads are published through GitHub Releases:

- signed and notarized **macOS Apple Silicon DMG**
- unsigned **Windows NSIS setup EXE** as a test-stage asset

Start here:

- [Installing on macOS](./installing-on-macos.md)
- [Installing on Windows](./installing-on-windows.md)

## Clone the repository for local development

Once the public GitHub repository exists, copy the HTTPS or SSH clone URL directly from the repository page, then clone it locally and install dependencies.

## Run in development

### Full desktop app

```bash
npm run tauri dev
```

Use this path when you want the real Tauri application behavior, including local database access and the macOS menu bar experience.

### Browser preview

```bash
npm run dev
```

Use this for UI work only. Tauri-only features are limited or mocked in browser preview.

## First-time setup inside the app

1. Launch **Codex Pacer** from `Applications` on macOS or the Start menu on Windows.
2. Open **Settings**.
3. Confirm the Codex home path (`~/.codex` by default) or point it to a custom `CODEX_HOME`.
4. Run the first scan/import.
5. Wait for the local indexing step to complete.
6. Review the overview, pacing indicators, and session drill-downs.

## Core concepts

### API-equivalent value

Codex Pacer estimates what your token usage would have cost under API pricing mappings. It is a comparative signal, not a billing invoice.

### Subscription payoff

`API-equivalent value / subscription cost`

This helps you judge whether your subscription is underused, roughly matched, or clearly paying for itself.

### Rolling quota windows

When live quota data is available, Codex Pacer tracks rolling windows such as `5-hour` and `7-day` usage so you can compare remaining quota against remaining time.

### Suggested pace

Codex Pacer compares remaining quota with remaining time to help you judge whether you are spending too quickly, staying on track, or leaving too much capacity unused before reset.

## What you can inspect

- Overview analytics across the active time window
- Quota pacing when live window data is available
- Conversation, root-session, and subagent breakdowns
- Model mix and token composition
- Menu bar snapshot UI for quick checks on macOS

## Build and sanity-check from source

```bash
npm run lint
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

## Next docs

- [Installing on macOS](./installing-on-macos.md)
- [Installing on Windows](./installing-on-windows.md)
- [Packaging and release](./packaging-and-release.md)
- [Release notes for v1.1.1](./release-notes-v1.1.1.md)

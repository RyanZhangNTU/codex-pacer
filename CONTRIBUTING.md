# Contributing

Thanks for helping improve Codex Pacer, a native macOS app written in SwiftUI and AppKit, with a Windows port that runs a WPF/.NET host over the same Swift Core engine.

## Before you start

- Read the [user guide](docs/guide.md) to see how the app behaves today, and [development notes](docs/development.md) for architecture, data semantics and regression coverage.
- AI coding agents should start with [AGENTS.md](AGENTS.md).
- For larger changes, open an issue first so we can agree on the approach.

## Workflow

1. Branch from `develop` and keep each branch focused on one change.
2. On the Mac, build and test with Xcode 26 or later:

   ```sh
   make test TEST_FILTER='CompletionInboxTests|SessionNameTests'  # suites your change affects
   make build                                                     # an app for checking the UI
   ```

   On Windows, use the scripts in [Windows shell development](docs/windows-shell.md) and [Windows engine development](docs/windows-engine.md).

3. Check compiler warnings and try the changed behavior in the real app. `--demo` launches it with sample data.
4. Update the docs when behavior or setup changes: the README and [user guide](docs/guide.md) describe features in plain language, while [development notes](docs/development.md) and the Windows docs hold the technical details.
5. Open a pull request into `develop`, describing what changed and how you tested it, including the OS version and architecture. `main` only receives release promotions; packaging follows [releasing](docs/releasing.md).

## Privacy

Never include credentials, account identifiers or private task content in issues, logs, screenshots or tests. Use synthetic data.

## Reporting problems

Report bugs with the app and OS versions, the task source (this Mac or PC, SSH, WSL, Remote Control or Claude cloud Projects), reproduction steps and redacted screenshots. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

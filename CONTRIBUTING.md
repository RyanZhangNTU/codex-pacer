# Contributing

Thanks for helping improve Codex Pacer, a native macOS app written in SwiftUI and AppKit.

## Before you start

- Read the [user guide](docs/guide.md) to see how the app behaves today, and [development notes](docs/development.md) for architecture, data semantics and regression coverage.
- AI coding agents should start with [AGENTS.md](AGENTS.md).
- For larger changes, open an issue first so we can agree on the approach.

## Workflow

1. Branch from `develop` and keep each branch focused on one change.
2. Build and test with Xcode 26 or later:

   ```sh
   make test TEST_FILTER='CompletionInboxTests|SessionNameTests'  # suites your change affects
   make build                                                     # an app for checking the UI
   ```

3. Check compiler warnings and try the changed behavior in the real app. `--demo` launches it with sample data.
4. Update the README, user guide or development notes when behavior or setup changes.
5. Open a pull request into `develop`, describing what changed and how you tested it, including the macOS version and architecture. `main` only receives release promotions; packaging follows [releasing](docs/releasing.md).

## Privacy

Never include credentials, account identifiers or private task content in issues, logs, screenshots or tests. Use synthetic data.

## Reporting problems

Report bugs with the app and macOS versions, the task source (this Mac, SSH or Remote Control), reproduction steps and redacted screenshots. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

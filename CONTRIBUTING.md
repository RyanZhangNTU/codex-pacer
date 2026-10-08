# Contributing

Codex Pacer is a native macOS app written in SwiftUI/AppKit. Create focused branches from `develop` and open PRs back into `develop`; `main` accepts release promotions.

Agents should start with [AGENTS.md](AGENTS.md). Packaging and publication follow the [release workflow](docs/releasing.md).

Use Xcode 26 or newer. During development, run the affected suites:

```sh
make test TEST_FILTER='CompletionInboxTests|SessionNameTests'
```

Run one full `make test` for a release candidate. Use `make build` when you need an app for UI checks; the release build supplies the final app. Follow the [validation scope](docs/releasing.md#validation-scope) instead of repeating unrelated manual checks.

Read [development and data semantics](docs/development.md) for architecture and regression coverage. Document what was tested and which OS/architecture was used. Never include account credentials or private task content in issues, logs or screenshots.

Keep user-facing behavior and relevant docs aligned. Report bugs with the app/macOS versions, source type, reproduction steps and redacted screenshots. Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

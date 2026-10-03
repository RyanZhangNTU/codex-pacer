# Contributing

Codex Pacer 2.0 maintains a native macOS app written in SwiftUI/AppKit. Create focused branches from `develop` and open PRs back into `develop`; `main` accepts release promotions.

Use Xcode 26 or newer and run:

```sh
make test
make build
```

Read [development and data semantics](docs/development.md) before changing lifecycle, rate or transport logic. Preserve meaningful regression tests and verify the actual app for visual/interaction changes. Document what was tested and which OS/architecture was used. Never include account credentials or private task content in issues, logs or screenshots.

Keep user-facing behavior and relevant docs aligned. Report bugs with the app/macOS versions, source type, reproduction steps and redacted screenshots. Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

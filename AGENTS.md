# Instructions for agents

Codex Pacer is a native macOS app built with SwiftUI/AppKit, plus a Windows port: a WPF/.NET host over the shared Swift Core engine. Follow the user's current instructions and preserve unrelated work.

## Read before working

- For runtime, data, UI or lifecycle changes, read [development and data semantics](docs/development.md).
- For any version bump, packaging, update verification, tag or GitHub Release, follow [the release workflow](docs/releasing.md) in order. It is the canonical operational procedure.
- For Sparkle, signing keys, feed changes or updater UI, also read [automatic updates](docs/automatic-updates.md).
- For Windows work, read [Windows shell development](docs/windows-shell.md) for building and testing, [Windows engine development](docs/windows-engine.md) for the shared engine, and [Windows installation](docs/windows-installation.md) for the installer and lifecycle checks.
- Use [CONTRIBUTING.md](CONTRIBUTING.md) for branch and PR conventions.

## Working rules

- Branch from the current `develop`, normally using a `codex/` prefix; implementation PRs target `develop`, release promotions target `main`.
- On the Mac, use `make test TEST_FILTER='SuiteName'` during development and one full `make test` for the release candidate. Use `make build` when an app is needed for UI checks; the final release build already covers compilation and packaging. Sources/build outputs stay isolated under `/private/tmp`, with reusable pinned dependency caches. On Windows, run the affected scripts described in the Windows docs above.
- Preserve meaningful regression coverage. Consolidate overlapping cases by behavior and keep their distinct boundary assertions; do not delete tests merely because they are old.
- Check compiler warnings and verify changed interactions in the actual macOS or Windows UI. Run only the applicable checks in the [release workflow](docs/releasing.md#validation-scope); do not repeat passed checks without relevant changes.
- Do not include credentials, account identity or private task content in logs, screenshots, PRs or release assets.
- Follow authorization already provided for the current work; do not ask again for an already approved merge or release. Without that authorization, finish the reviewable changes and verification before requesting the missing approval. This file is a procedure, not blanket permission to publish future releases.
- Keep operational release rules in `docs/releasing.md`; link to them instead of maintaining another checklist. Documentation, test and tooling maintenance that does not change the shipped app needs no version bump or binary release.

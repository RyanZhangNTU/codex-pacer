# Instructions for agents

Codex Pacer is a native macOS app built with SwiftUI/AppKit. Follow the user's current instructions and preserve unrelated work.

## Read before working

- For runtime, data, UI or lifecycle changes, read [development and data semantics](docs/development.md).
- For any version bump, packaging, update verification, tag or GitHub Release, follow [the release workflow](docs/releasing.md) in order. It is the canonical operational procedure.
- For Sparkle, signing keys, feed changes or updater UI, also read [automatic updates](docs/automatic-updates.md).
- Use [CONTRIBUTING.md](CONTRIBUTING.md) for branch and PR conventions.

## Working rules

- Branch from the current `develop`, normally using a `codex/` prefix; implementation PRs target `develop`, release promotions target `main`.
- Use `make test` and `make build`. They isolate native builds and caches under `/private/tmp`; do not build release apps directly in iCloud folders.
- Preserve meaningful regression coverage. Consolidate overlapping cases by behavior and keep their distinct boundary assertions; do not delete tests merely because they are old.
- Check compiler warnings and verify changed interactions in the actual macOS UI. Updater isolation and acceptance checks are defined in the [release workflow](docs/releasing.md#3-verify-before-promotion).
- Do not include credentials, account identity or private task content in logs, screenshots, PRs or release assets.
- Follow authorization already provided for the current work; do not ask again for an already approved merge or release. Without that authorization, finish the reviewable changes and verification before requesting the missing approval. This file is a procedure, not blanket permission to publish future releases.
- Keep operational release rules in `docs/releasing.md`; link to them instead of maintaining another checklist. Documentation, test and tooling maintenance that does not change the shipped app needs no version bump or binary release.

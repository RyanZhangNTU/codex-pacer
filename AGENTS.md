# Instructions for agents

Codex Pacer is a native macOS app built with SwiftUI/AppKit. Follow the user's current instructions and preserve unrelated work.

## Read before working

- For runtime, data, UI or lifecycle changes, read [development and data semantics](docs/development.md).
- For any version bump, packaging, update verification, tag or GitHub Release, follow [the release workflow](docs/releasing.md) in order. It is the canonical operational procedure.
- For Sparkle, signing keys, feed changes or updater UI, also read [automatic updates](docs/automatic-updates.md).
- Use [CONTRIBUTING.md](CONTRIBUTING.md) for branch and PR conventions.

## Implementation and verification

- Branch from the current `develop`, normally using a `codex/` prefix; implementation PRs target `develop`, release promotions target `main`.
- Use `make test` and `make build`. They isolate native builds and caches under `/private/tmp`; do not build release apps directly in iCloud folders.
- Check compiler warnings for changed code, especially nearly matching optional Sparkle delegate methods. A successful build alone does not verify UI behavior.
- Test changed interactions on the actual macOS UI. For updater work, include an expanded and pinned island, dialog dismissal, cancellation, normal interaction afterwards, and the exact restored top-edge position.
- Keep update QA separate from production: distinct app identity, executable, lock, preferences and data/cache paths; demo task data; SSH disabled; loopback-only test feeds. `--demo` alone does not isolate the production lock or preferences.
- Do not include credentials, account identity or private task content in logs, screenshots, PRs or release assets.

## Release rules

- Follow authorization already provided for the current work; do not ask again for an already approved merge or release. Without that authorization, finish the reviewable changes and verification before requesting the missing approval. This file is a procedure, not blanket permission to publish future releases.
- A release uses a clean, final commit shared by `main` and `develop`, a matching tag, a higher integer `CFBundleVersion`, English and Chinese notes, and a verified universal build.
- Use the repository build/publish scripts. Keep the existing update feed and signing identity compatible; never regenerate the Sparkle key merely to get a release working.
- Publish exactly the universal DMG and signed `appcast.xml` as uploaded assets. Both are required for the current updater. Keep checksums, build receipts and test fixtures local.
- When validating an installed-app upgrade, retain the old installation and update through Sparkle after publication. Do not replace it manually and call that an updater test. Bootstrap/manual installation is a separate user-authorized path.
- Verify the new process and installed build before using UI tools that might launch the app. Then check the real installed UI, preferences, single-instance behavior and latest-version result.
- Fix problems discovered after publication with a new patch version and higher build number. Do not rewrite public tags or swap a DMG beneath an existing signed feed.
- Treat asset counts as download requests: release verification and local update tests contribute traffic, and XML reads are not user or installation counts.
- For documentation-only changes, validate the documents and links; do not bump the app version, rebuild installers or publish a binary release solely for those changes.

# Release workflow

This is the canonical release procedure. Follow the four phases below, using only the applicable validation. [AGENTS.md](../AGENTS.md) points here; [automatic updates](automatic-updates.md) covers Sparkle, its signatures and signing-key handling.

Use authorization already given for the current work. Implementation alone does not authorize a merge or public release; finish the reviewable work before asking for missing authorization. Documentation, test and tooling changes that do not change the shipped app need only affected checks, with no version bump, installer or binary release.

## Validation scope

During development, run affected suites with `make test TEST_FILTER='SuiteName|OtherSuite'`. Run one full `make test` for the final application release candidate. Reuse that pass after documentation-only changes or a merge that leaves application sources, tests, dependencies and build settings unchanged; otherwise rerun affected checks. Record the tested source and relevant warnings. Test counts are not acceptance criteria.

Use `make build` only when an app is needed for UI verification and no matching candidate exists. The final release build covers compilation, resource packaging and signatures, so do not add a separate same-source preview build just for publication. Native sources and build outputs stay isolated in `/private/tmp`; pinned dependencies and compiler modules reuse a per-user cache there.

| Change | Required manual verification |
| --- | --- |
| Task discovery, names, lifecycle, quota or rate | Reproduce the changed behavior on the affected source/host. Keep real subprocess regression tests for transport/shutdown changes. |
| Width, layout or animation | Check changed configurations and the original reproduction in the real app. Geometry changes need top/center anchoring and reversal; do not repeat every display/language combination. |
| Window levels, pin/focus or updater presentation | Check an expanded/pinned island with the affected alert, mouse dismissal, blocked hover/focus while open and restored anchors afterwards. Run cancel, error and background-prompt cases only when their paths change. |
| Sparkle, installation/relaunch, shutdown or signing/feed compatibility | Use isolated updater QA for signed download, extraction, installation and automatic relaunch. After publication, verify a real installed-app upgrade. |
| Language | Check changed text/layout in English and Chinese. Default/override persistence and language relaunch are required only when language selection changes. |
| DMG layout, packaging or first-open guidance | Inspect Finder layout and the affected manual-install/first-open path. Unchanged layout needs no repeat screenshot or Gatekeeper walkthrough. |
| Documentation, tests or tooling only | Validate affected tests/scripts/links. No product UI or updater matrix unless the tooling changes the resulting package. |

Isolated updater QA uses a different bundle identifier, executable, singleton lock, preferences and data/cache paths, demo data, disabled SSH and a loopback feed. `--demo` alone does not isolate production locking and normally disables Sparkle. Enable the real updater only in the QA copy. Do not replace a failed required interaction with a source-code inspection; report the exact unverified check. Record actual OS/architecture/display coverage without claiming Intel hardware testing from a universal build.

## 1. Prepare and validate

Inspect the clean worktree, current branch, fresh `origin/main`/`origin/develop`, committed version/build and latest public release once. Preserve unrelated work and resolve unexpected remote changes without force-pushing. Create a focused branch from current `develop`.

For an application release, update:

- `native/Info.plist`: marketing version matching `vVERSION`, and an integer build above every build in the latest public appcast.
- `native/Sources/PacerCore/RealtimeProbe.swift`: matching event-client version.
- `CHANGELOG.md` and `docs/release-notes-VERSION.en.md` / `.zh-CN.md`: shipped changes and installation guidance. Keep both current note files; do not add a deferred-issue appendix unless requested.
- README/usage/development docs only when their behavior or instructions change. Older notes may be removed after publication; tags, Releases and the changelog retain history.

Run the applicable validation above. Do not repeat a passing suite, live reproduction or packaging check without a relevant source/configuration/artifact change.

## 2. Promote the final source

When authorized, merge the implementation PR into `develop`, then promote `develop` to `main` with a merge commit. Match the reviewed PR head and attach created PRs to the chat. Synchronize without force-pushing:

```sh
git fetch origin
git switch main
git merge --ff-only origin/main
git switch develop
git merge --ff-only origin/main
git push origin develop
git switch main
git status --porcelain
git rev-parse HEAD origin/main origin/develop
```

The worktree must be clean and the three commit IDs must match before building. Build from this exact final commit. Later application changes require integration, affected checks and a new final build; never label an earlier binary with a later source receipt.

## 3. Build and publish once

Reuse `/private/tmp/codex-pacer-dmg-tools` when its installed versions match `scripts/release/dmg-requirements.txt`. Only create/install it when missing or out of date:

```sh
python3 -m venv /private/tmp/codex-pacer-dmg-tools
/private/tmp/codex-pacer-dmg-tools/bin/python -m pip install -r scripts/release/dmg-requirements.txt
```

Set `PACER_DMG_PYTHON=/private/tmp/codex-pacer-dmg-tools/bin/python`. Choose `make release-unsigned` for the existing ad-hoc channel, or `make release` only for an explicitly selected Developer ID workflow. Never switch distribution modes as a fallback for signing failure.

The build script checks both executable architectures, bundled languages and code signatures, packages/verifies the DMG once, checks its mounted app and Applications link, and generates/verifies signed archive and bilingual feed data. Keep `build.json`, `update.json` and `SHA256SUMS.txt` under local ignored `output/releases/VERSION/` (`unsigned/` for that mode). Read the successful script result/receipts; do not manually rerun its identical checks.

Once authorized, confirm `vVERSION` is new, tag the exact committed version, push it, then publish:

```sh
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
git ls-remote origin "refs/tags/v$task_version"
# Continue only for a new tag.
git tag -a "v$task_version" -m "Codex Pacer $task_version"
git push origin "v$task_version"
make publish-unsigned
```

Use `make publish` for Developer ID artifacts. The publisher checks source/tag identity, distribution, checksums, feed/archive signatures and monotonically increasing build numbers. It uploads exactly the universal DMG and signed `appcast.xml` to a draft, downloads each once for byte comparison, then makes it public/latest. Source archives generated by GitHub are separate. Keep the bundle ID, `SUFeedURL` and `SUPublicEDKey` compatible with installed clients; the stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`.

After publication, confirm public/latest status, expected tag/assets and that the stable latest-feed URL serves the intended signed feed. Do not download the DMG again after the publisher's successful comparison. If publication fails or its outcome is unknown, inspect remote state before retrying; incomplete candidates remain unpublished. Do not edit signed XML/archives or replace published tags/assets: fix problems in a new patch version/build.

## 4. Conditional installed-app acceptance

Perform this phase when the validation table requires it or the user requests a local upgrade/install test. An ordinary feature release does not require repeating the complete update/install flow.

For an in-app upgrade, retain a rollback copy and record the old installed version/build, PID/path and preferences. Use **Check for Updates → Install Update → Install and Relaunch** in the old `/Applications/Codex Pacer.app`; copying over or killing the process does not validate Sparkle. Confirm the intended installed version/build, old PID exit, one automatically relaunched process from Applications, executable identity/signature, preserved preferences and connected sources. Check once more for the up-to-date result. Repeat only the affected UI reproduction. An isolated QA installation does not prove this production upgrade.

An explicitly requested overwrite installation is a separate local test: normal-quit, preserve rollback/settings, replace and verify installed identity and one running instance. Report build, public release and actual installation separately; never infer completion from launching a candidate.

## Distribution and reporting

Unsigned output has an ad-hoc app signature, an unsigned DMG and no notarization/stapling. No Apple credentials are used. Keep the brief first-open guidance in README/Release: double-click the DMG; if blocked, use System Settings → Privacy & Security → Security → Open Anyway, reopen it, then drag the app into Applications. Repeat for the app if blocked. Link [Apple's instructions](https://support.apple.com/102445) and embed the tagged help screenshot in the Release body; do not upload it as an asset.

Developer ID mode requires `APPLE_SIGNING_IDENTITY` and a configured notarization profile/credentials. It signs, notarizes/staples and checks the app and DMG with Gatekeeper. Private keys/passwords remain in Keychain or secure environment input, never Git, assets, logs or command arguments. Sparkle update signatures are required in both modes and do not establish Apple notarization.

Give a concise completion report with release/PR links, version/build/source, checks actually passed and material limitations. Keep detailed logs/receipts local. Record known validation downloads; GitHub counts are downloads, not unique users. Promotion/marketing assets are optional work, regenerated only when requested or affected, not a release gate.

# Release workflow

This is the canonical procedure for agents and maintainers. [AGENTS.md](../AGENTS.md) points here; [automatic updates](automatic-updates.md) explains Sparkle's implementation and keys. Follow the phases in order and record the evidence for each completed phase.

Changes land in `develop`; release promotion targets `main`. Both branches must contain the final source before a release is built. A release includes a matching Git tag and a published GitHub Release with exactly two uploaded assets: the universal DMG for installation and signed `appcast.xml` for the updater. Source receipts, SHA-256 checksums and QA fixtures stay local. GitHub's automatically generated source archives are separate from these uploaded assets.

## Authorization and scope

Use authorization already given for the current work. If the user has requested implementation, merge, publication and an in-app upgrade test, continue through those stages without asking for the same approval again. A request to inspect or edit code alone does not authorize a public release: prepare the reviewable result and finish applicable validation before asking for the missing authorization. This document does not grant blanket permission for future releases.

Documentation-only work does not require a version bump, installer build or binary release. When merging such work is authorized, land it in `develop` and promote the documentation to `main`, then synchronize the branches without creating a release tag.

## 1. Inspect the live state

Read the worktree and remote state before changing version numbers or selecting a source commit:

```sh
git status --short
git branch --show-current
git fetch origin
git rev-parse origin/main origin/develop
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' native/Info.plist
gh release view --repo RyanZhangNTU/codex-pacer --json tagName,isDraft,isPrerelease,assets
```

Preserve unrelated local changes. Resolve unexpected remote changes before promotion; never force-push to make the branches match. Do not reuse an old build directory, tag or signing-tool path from a previous chat without checking it.

For an installed-app update test, record the installed version/build, running PID and executable path, and the user-facing preferences to compare later. Retain the old installation until the release is public. The production app is `/Applications/Codex Pacer.app`, with bundle identifier `com.codexpacer.app` and executable `CodexPacerIsland`.

## 2. Prepare the release source

Use a focused branch from the current `develop`. Update all relevant version and release files:

| File or field | Required change |
| --- | --- |
| `native/Info.plist` → `CFBundleShortVersionString` | New public version, matching `vVERSION` |
| `native/Info.plist` → `CFBundleVersion` | Integer higher than every build in the latest public appcast |
| `native/Sources/PacerCore/RealtimeProbe.swift` | Keep the event client's reported version aligned |
| `CHANGELOG.md` | Describe the resulting behavior and fixes |
| `docs/release-notes-VERSION.en.md` | English release notes |
| `docs/release-notes-VERSION.zh-CN.md` | Simplified Chinese release notes |
| README and usage/development docs | Update when behavior, setup or installation instructions change |

Keep the bundle identifier, `SUFeedURL` and `SUPublicEDKey` compatible with installed clients. The stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`; its presence in Release assets is part of the current update service. Moving it or rotating the key requires a planned compatibility migration.

## 3. Verify before promotion

Run `make test` and `make build` for application changes. The scripts copy native sources to `/private/tmp`, isolate caches, package resources and helpers, and verify the app's code signature. Check relevant warnings as well as the exit code; a nearly matching optional Sparkle delegate method can compile without handling its callback.

Verify changed UI in the real macOS app. An isolated QA build should use a different bundle identifier, executable, singleton-lock location, preferences and data/cache paths, demo task data, and disabled SSH. Use a loopback-only feed for update fixtures. `--demo` alone still shares production identity/locking and normally disables Sparkle; enable the real updater only in the isolated QA copy. Exercise the production panel, model, updater and shutdown path together.

For updater, panel, focus or lifecycle changes, cover these cases before publishing:

- An expanded and pinned island followed by a latest-version or error alert; close the alert with the mouse.
- Cancel a check while it is in progress, and dismiss a found-update prompt.
- A silent background check leaves the island undisturbed; a scheduled update prompt does not become trapped beneath it.
- Download, verification, installation and automatic relaunch through Sparkle in the isolated app when the installation path changes.
- While update UI is open, hover, pin, reopen and focus requests cannot bring the island back over it. Afterwards, normal expansion/collapse works and the exact top edge and horizontal center are restored. Cover affected Notch/Floating configurations.

When language behavior changes, verify both English and Simplified Chinese, the macOS default, saved overrides and language relaunch. Inspect relevant layout and native update controls.

Record the OS, architecture and displays actually exercised. Compiled Intel support does not establish testing on Intel hardware. If a required UI check cannot be completed, report that limitation and finish the check before claiming validation.

## 4. Merge and select the final commit

Merge the implementation PR into `develop`, then promote `develop` to `main` with a merge commit so `develop` can fast-forward to it. Review the current diff and checks; match the reviewed PR head when merging. Attach created PRs to the working chat when the client supports attachments.

After the approved PR merges, synchronize locally and remotely without force-pushing:

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

The worktree must be clean and all three commit IDs must match before building. If code changes after validation or promotion, commit and integrate them, rerun affected checks, and build from the new final commit; do not reuse an earlier app while recording a later source commit.

## 5. Build and inspect the package

Install the pinned packaging dependencies in an isolated Python environment (Python 3.9+):

```sh
python3 -m venv /private/tmp/codex-pacer-dmg-tools
/private/tmp/codex-pacer-dmg-tools/bin/python -m pip install -r scripts/release/dmg-requirements.txt
export PACER_DMG_PYTHON=/private/tmp/codex-pacer-dmg-tools/bin/python
```

Choose one distribution mode: `make release-unsigned` for the existing ad-hoc/unsigned channel, or `make release` for an explicitly selected Developer ID signing/notarization workflow. The exact commands and distinctions are below; do not silently switch modes when signing fails.

Both modes build arm64 and x86_64 in `/private/tmp`, embed Sparkle and localization resources, sign nested helpers before the app, verify the DMG, mount it read-only, compare the inner executable and check the `/Applications` link. `prepare-update.py` checks the app identity and key, embeds both release-note languages, signs the completed feed, and verifies the feed and archive signatures.

Inspect the resulting `output/releases/VERSION/` directory (`unsigned/` for that mode):

- `build.json` identifies the exact source commit, app path, architectures and distribution mode.
- `update.json` identifies the build number, archive, release-specific download URL, signature, feed digest and the signing-tool path from this build.
- `SHA256SUMS.txt` covers the DMG and appcast. Verify both executable architectures for `CodexPacerIsland` and `PacerRelaunch`, plus the bundled language resources and deep app signature.
- The mounted DMG should show only the app and Applications shortcut in its fixed icon-view layout. Check Finder layout when packaging/layout changed or this is the first installer; report any unverified visual requirement separately from structural checks.

Do not modify the archive or XML after signing. Regenerate the signatures, metadata and checksums if an unpublished candidate changes. Do not manually rewrite a checksum or bypass verification to make publication proceed.

## 6. Tag and publish the verified artifacts

Once the final commit and artifacts are verified and publication is authorized, derive the tag from the committed app version:

```sh
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
git ls-remote origin "refs/tags/v$task_version"
# Continue only if this is a new tag for the verified release.
git tag -a "v$task_version" -m "Codex Pacer $task_version"
git push origin "v$task_version"
make publish-unsigned
```

Use `make publish` instead for a verified Developer ID build. The publisher requires a clean checkout, matching local/remote tag and source receipt, correct distribution metadata, matching checksums, valid feed/archive signatures, and a build number above the latest public feed. It creates a draft with the DMG and appcast, downloads both for byte comparison, then marks it public and latest. This keeps the previous feed available until the new assets are ready.

Verify the release is public, not a draft/prerelease, and has the expected assets and tag. Check that the stable latest-feed URL serves the intended signed feed. A tag or uploaded draft alone is not a completed release.

If publication fails or its outcome is unknown, inspect the remote tag, draft/release and assets before retrying. Keep an incomplete candidate unpublished; do not skip a failed signature or byte-comparison step. The publisher is not a blind retry mechanism for an existing draft.

## 7. Verify the installed-app upgrade

When an older installed version already includes Sparkle, use its **Check for Updates → Install Update → Install and Relaunch** flow. Do not copy the new app over it, launch the build-directory candidate as a substitute, or kill the old production process to simulate updater shutdown. Manual bootstrap for versions without an updater is a distinct installation path.

After Sparkle finishes, verify these facts before claiming completion:

1. The installed bundle has the intended marketing version and integer build number.
2. The old PID exited and one new `CodexPacerIsland` process is running from `/Applications/Codex Pacer.app`. Establish automatic relaunch before calling a UI tool that might launch a missing app itself.
3. The installed executable matches the verified release artifact and the deep code signature passes.
4. Existing user-facing preferences remain intact, and task/quota sources reconnect normally.
5. Checking again reports the current version as up to date. For UI changes, repeat the original reproduction on the installed app, including closing the alert, restoring the exact island anchor, and expanding/collapsing afterwards.

An isolated updater test proves that fixture; it does not replace this production-upgrade acceptance. Keep the original installed version available until publication so this test remains meaningful. Report build, publication and actual upgrade as separate verified outcomes.

## Published release corrections

Leave public tags and their binary/feed assets intact. Fix application or packaging problems in a new patch version with a higher build number and repeat the workflow. Replacing only a public DMG leaves its signed appcast referring to different bytes; replacing or removing only `appcast.xml` can break installed clients. Do not reuse the old packaging-only asset-swap procedure for signed updates.

## Download counts and completion report

The publisher deliberately downloads each uploaded asset once for byte comparison. An installed-app update also downloads its installer, while manual/background checks and feed verification may add XML downloads. Retries and additional verification can add more traffic. Record the self-generated downloads; do not repeat the publisher's identical round-trip download without a verification need.

GitHub asset counts are aggregate download counts, not unique people. A DMG count includes maintainer validation and local upgrades, and an XML count reflects update-feed traffic rather than installations. Reading release metadata through `gh api` does not itself download those assets. Report raw counts separately from known test traffic; do not claim an exact external-user count from subtraction.

In the completion report, include the release/PR links, version/build and source commit, automated and live checks actually passed, installed-upgrade result if requested, preserved settings, and material unverified OS/architecture coverage. Keep build receipts and detailed logs local; never publish credentials or private task content.

## Unsigned distribution

```sh
make release-unsigned
# After verification and pushing vVERSION:
make publish-unsigned
```

Outputs are in `output/releases/VERSION/unsigned/`. The DMG filename includes `-unsigned`. The app has a local **ad hoc** signature required for execution compatibility, but no Developer ID identity; the DMG is unsigned and neither artifact is notarized or stapled. No Apple credentials are used. The receipt records this distinction explicitly.

Include the first-open steps in the Release and README: double-click the downloaded DMG first; after a blocking alert, scroll to Security at the bottom of System Settings → Privacy & Security and allow that installer. Open the DMG again and drag the app into Applications. If the app is also blocked, repeat for the app. Link [Apple's instructions](https://support.apple.com/102445) and embed the annotated Settings screenshot in the Release body, not as a download. Do not describe this distribution as Developer ID signed, notarized, or Gatekeeper-approved. Installation notes stay outside the DMG.

## Developer ID signed distribution

Configure `APPLE_SIGNING_IDENTITY` with a valid Developer ID Application identity. Use `APPLE_NOTARY_PROFILE` for an existing Keychain profile, or `APPLE_ID` and `APPLE_TEAM_ID`; the helper prompts for an app-specific password without echo. `APPLE_PASSWORD` is accepted from an existing secure environment. Never commit credentials or print them in logs.

```sh
make release
make publish
```

This mode signs with hardened runtime, notarizes/staples the app and DMG, and verifies both with Gatekeeper. It requires a receipt marking all of those steps complete. A failure must not be bypassed by publishing the candidate as notarized. The explicit unsigned mode is a separately labelled distribution.

## Promotional assets

Regenerate the approved portrait and matching landscape with `python3 marketing/render.py --stills-only`. Inspect both, commit the README image and source assets, and deliver the full-size images separately. Keep the Release attachments limited to the DMG and signed appcast; do not upload images, checksums or build receipts there. Generated outputs remain ignored by Git.

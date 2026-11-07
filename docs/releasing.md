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
| Window levels, pin/focus or updater presentation | Check an expanded/pinned island with the affected alert, mouse dismissal, blocked hover/focus while open and restored anchors afterwards. For Pacer's own update UI, check the found version in the sidebar, Overview and Help & Updates, then Update and Restart; run cancel, error and background-check cases only when their paths change. |
| Sparkle, installation/relaunch, shutdown or signing/feed compatibility | Use isolated updater QA for signed download, extraction, installation and automatic relaunch. After publication, verify a real installed-app upgrade. |
| Language | Check changed text/layout in English and Chinese. Default/override persistence and language relaunch are required only when language selection changes. |
| DMG layout, packaging or first-open guidance | Inspect Finder layout and the affected manual-install/first-open path. Unchanged layout needs no repeat screenshot or Gatekeeper walkthrough. |
| Windows updater, feed or installer identity | Use the isolated Windows update QA (`Pacer.DesktopTests --serve-update-feed` with a QA installation). After publication, verify a real installed Windows upgrade. |
| Documentation, tests or tooling only | Validate affected tests/scripts/links. No product UI or updater matrix unless the tooling changes the resulting package. |

Isolated updater QA uses a different bundle identifier, executable, singleton lock, preferences and data/cache paths, demo data, disabled SSH and a loopback feed. `--demo` alone does not isolate production locking and normally disables Sparkle. Enable the real updater only in the QA copy. Do not replace a failed required interaction with a source-code inspection; report the exact unverified check. Record actual OS/architecture/display coverage without claiming Intel hardware testing from a universal build.

## 1. Prepare and validate

Inspect the clean worktree, current branch, fresh `origin/main`/`origin/develop`, committed version/build and latest public release once. Preserve unrelated work and resolve unexpected remote changes without force-pushing. Create a focused branch from current `develop`.

For an application release, update:

- `native/Info.plist`: marketing version matching `vVERSION`, and an integer build above every build in the latest public appcast.
- `native/Sources/PacerCore/RealtimeProbe.swift`: matching event-client version.
- `native/Sources/PacerCore/WhatsNew.swift`: the version's highlights for the in-app update note, with strings in both catalogs. A version without an entry updates quietly.
- `CHANGELOG.md` and `docs/release-notes-VERSION.en.md` / `.zh-CN.md`: shipped changes. The notes also appear in the in-app update windows, so leave out install or update steps; the publisher puts a download table at the top of the Release body. Keep both current note files; do not add a deferred-issue appendix unless requested.
- README, user guide and development docs only when their behavior or instructions change. Older notes may be removed after publication; tags, Releases and the changelog retain history.

Windows has shipped in the same GitHub Release since 4.2.2, the first Windows release: `scripts/release/windows-release.json` sets `publish` to `true`, so every release carries the Windows installers and `appcast-windows.xml`, and its notes cover both platforms. The publisher refuses a release that would drop the Windows feed.

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

The Release workflow (`.github/workflows/release.yml`) builds, signs and publishes the release from its tag. Once authorized, confirm `vVERSION` is new, then tag the exact promoted commit and push the tag:

```sh
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
git ls-remote origin "refs/tags/v$task_version"
# Continue only for a new tag.
git tag -a "v$task_version" -m "Codex Pacer $task_version"
git push origin "v$task_version"
gh run watch "$(gh run list --workflow release.yml --branch "v$task_version" --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The workflow first checks that the tag names `CFBundleShortVersionString`, that both release notes exist and that `main` contains the tagged commit. Then, in parallel:

- **Windows x64 and ARM64** build the installers. x64 keeps the package smoke test; ARM64 packages without installing. The tests already ran on the pull requests ([continuous integration](development.md#continuous-integration)). These jobs hold no secrets: the installers are not Authenticode signed.
- **macOS** runs `build-macos-release.sh --dmg-only`. It builds the universal app, signs the app, its helper and Sparkle's components with Developer ID, hardened runtime and secure timestamps, notarizes and staples the app and DMG, checks both with Gatekeeper, and checks the mounted DMG's app and Applications link.

The publish job then runs `sign-updates.sh`, which generates and signs the bilingual Mac appcast for the DMG. It also checks each Windows installer's name, CI checksum and version resource, renames it `Codex-Pacer-VERSION-windows-ARCH-setup.exe`, and signs the installers and `appcast-windows.xml` with the same Sparkle key ([details](windows-automatic-updates.md#network-and-verification)). Finally it runs `publish-github-release.sh`.

Each architecture also publishes `Codex-Pacer-VERSION-windows-ARCH-manifest.json`, the file list a later release builds its patch from, with its SHA-256 in the feed. When CI built a patch from the latest published build, the build checks that base against the signed public feed. A matching patch is signed and published as `Codex-Pacer-VERSION-windows-ARCH-update-from-BASE.exe` inside the feed's `<sparkle:deltas>`; a patch from any other base is dropped and only the full installer ships ([details](windows-automatic-updates.md#patch-updates)).

The publisher checks source/tag identity, distribution, checksums, feed/archive signatures and monotonically increasing build numbers. It uploads exactly the universal DMG and signed `appcast.xml`, plus the Windows installers, manifests, any patches and `appcast-windows.xml`, to a draft. It downloads each file once for byte comparison, then makes the release public/latest, so the previous feed stays live until every new file is in place. Source archives generated by GitHub are separate. Keep the bundle ID, `SUFeedURL` and `SUPublicEDKey` compatible with installed clients; the stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`.

A manual run (`gh workflow run release.yml --ref develop`) does everything except publish. It checks what the publisher checks before uploading, without the tag and newer-build requirements, and keeps the signed DMG, feeds and receipts as the `release-dry-run` artifact for three days. Use it after changing the release machinery; it is not a release gate.

After publication, confirm public/latest status, the expected tag and assets, and that both stable latest-feed URLs serve the intended signed feeds. If the workflow fails or its outcome is unknown, inspect the run and remote state before retrying; incomplete candidates remain drafts. Do not edit signed XML/archives or replace published tags/assets: fix problems in a new patch version/build.

### Release secrets

The workflow's signing jobs run in the GitHub environment `release`, which only `v*` tags and `develop` can use; pull requests cannot read it. It holds:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` | The `Developer ID Application` certificate and private key, exported from Keychain Access as base64 `.p12`, and its export password |
| `APPLE_NOTARY_KEY_P8`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` | An App Store Connect team API key with Developer access, for `notarytool` |
| `SPARKLE_PRIVATE_KEY` | The Sparkle update key, from `generate_keys --account com.codexpacer.app -x FILE` |

The release owner sets or rotates them in their own terminal with `gh secret set NAME --env release`, piping a file or typing the value at the hidden prompt, and deletes exported files afterwards. The macOS job imports the certificate into a temporary keychain and writes the API key to a temporary file, removing both when it ends. The publish job passes the Sparkle key to Sparkle's tools on standard input (`--ed-key-file -`), never as a file or argument, and refuses to sign unless its public half equals `SUPublicEDKey`.

### Local fallback

If GitHub Actions cannot sign or publish, the release Mac produces the identical release. Reuse `/private/tmp/codex-pacer-dmg-tools` when its installed versions match `scripts/release/dmg-requirements.txt`. Only create/install it when missing or out of date:

```sh
python3 -m venv /private/tmp/codex-pacer-dmg-tools
/private/tmp/codex-pacer-dmg-tools/bin/python -m pip install -r scripts/release/dmg-requirements.txt
```

Set `PACER_DMG_PYTHON=/private/tmp/codex-pacer-dmg-tools/bin/python`, `APPLE_SIGNING_IDENTITY` and `APPLE_NOTARY_PROFILE` (see [distribution](#distribution-and-reporting)), then run `make release`. It runs the same build, notarization and `sign-updates.sh` with the Keychain key. It downloads the Windows installers from the newest Release workflow run on the commit; a manual run builds them without publishing. Keep `build.json`, `update.json`, `windows-update.json` and `SHA256SUMS.txt` under local ignored `output/releases/VERSION/` (`unsigned/` for that mode). Read the successful script result/receipts; do not manually rerun its identical checks. Then tag as above and run `make publish`.

Releases are Developer ID signed and notarized from 3.0.1; `make release-unsigned` and `make publish-unsigned` build the former ad-hoc channel only when explicitly requested. Never switch distribution modes as a fallback for signing or notarization failure.

## 4. Conditional installed-app acceptance

Perform this phase when the validation table requires it or the user requests a local upgrade/install test. An ordinary feature release does not require repeating the complete update/install flow.

For an in-app upgrade, retain a rollback copy and record the old installed version/build, PID/path and preferences. Use **Check for Updates**, then the old `/Applications/Codex Pacer.app`'s install action (**Install Update → Install and Relaunch** in Sparkle's window, or **Update and Restart** once the installed version has Pacer's own update UI); copying over or killing the process does not validate Sparkle. Confirm the intended installed version/build, old PID exit, one automatically relaunched process from Applications, executable identity/signature, preserved preferences and connected sources. Check once more for the up-to-date result. Repeat only the affected UI reproduction. An isolated QA installation does not prove this production upgrade.

An explicitly requested overwrite installation is a separate local test: normal-quit, preserve rollback/settings, replace and verify installed identity and one running instance. Report build, public release and actual installation separately; never infer completion from launching a candidate.

## Distribution and reporting

Developer ID mode is the release channel. CI signs with the [release secrets](#release-secrets). The local fallback requires `APPLE_SIGNING_IDENTITY` (the `Developer ID Application` identity in the login Keychain) and `APPLE_NOTARY_PROFILE`, a `notarytool` Keychain profile that the release owner creates once in their own terminal with `xcrun notarytool store-credentials PROFILE --apple-id APPLE_ID --team-id TEAM_ID`, typing the app-specific password at its hidden prompt. The build signs the app, its helper and Sparkle's components with hardened runtime and secure timestamps, notarizes and staples the app and DMG, and checks both with Gatekeeper. README and Release guidance is the normal drag-to-Applications install with the one-time macOS confirmation; the Release body carries no Open Anyway help.

The Release body opens with a download table naming one file per platform (the DMG, plus the x64 and ARM64 Windows installers when included) and says the other files serve in-app updates. Windows installers are not Authenticode signed, so the body also tells users how to get past SmartScreen ("More info → Run anyway") in both languages.

Unsigned output has an ad-hoc app signature, an unsigned DMG and no notarization/stapling, and uses no Apple credentials. Its Release body appends Apple's first-launch help link and the tagged Open Anyway screenshot.

Locally, passwords stay in Keychain, never in Git, assets, logs, environment files or command arguments; in CI they stay in the `release` environment and the job's temporary keychain. Sparkle update signatures are required in both modes and do not establish Apple notarization. Installed ad-hoc versions accept the first Developer ID update because its archive still validates with the unchanged EdDSA key; keep that key, `SUPublicEDKey`, the bundle ID and `SUFeedURL` unchanged.

Give a concise completion report with release/PR links, version/build/source, checks actually passed and material limitations. Keep detailed logs/receipts local. Record known validation downloads; GitHub counts are downloads, not unique users. Promotion/marketing assets are optional work, regenerated only when requested or affected, not a release gate.

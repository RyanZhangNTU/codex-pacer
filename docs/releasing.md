# Release workflow

Changes land in `develop`; release promotion targets `main`. Both branches must contain the final source before a release is built. A release includes a matching Git tag and a published GitHub Release with exactly two uploaded assets: the universal DMG and its signed `appcast.xml`. Source receipts and SHA-256 checksums stay local for maintainer verification. Previous tags/releases remain intact. See [automatic updates](automatic-updates.md) for signing keys and bilingual feed generation.

## Prepare and verify

Install the pinned packaging dependencies in an isolated Python environment (Python 3.9+):

```sh
python3 -m venv /private/tmp/codex-pacer-dmg-tools
/private/tmp/codex-pacer-dmg-tools/bin/python -m pip install -r scripts/release/dmg-requirements.txt
export PACER_DMG_PYTHON=/private/tmp/codex-pacer-dmg-tools/bin/python
```

1. Update `native/Info.plist`, README installation instructions and release notes. Run `make test`; inspect the native UI, shutdown and single-instance behavior when application code changes.
2. Merge the preparation PR into `develop`, promote it to `main`, then fast-forward `develop` to the final `main` commit. Stop if either remote branch gained unrelated changes; integrate those without force-pushing.
3. Build from that clean final commit using exactly one distribution mode below. Both modes build arm64 + x86_64 in `/private/tmp`, verify the app signature and DMG structure, mount the DMG read-only, compare the inner executable, check the Applications link, and write a source receipt and `SHA256SUMS.txt`. The DMG opens in a fixed icon-view window with only the app and Applications shortcut visible; its Retina background shows the drag direction and one installation sentence. Check this layout in Finder before publishing.
4. Check the packaged application on the available Mac. When validating an upgrade from an installed version, retain that installation until the release is published, then use its updater for the replacement and relaunch. Report any platform/architecture that was compiled but not tested on hardware.
5. Tag the verified commit `vVERSION`, push the tag, and publish using the matching mode. The publisher checks the local/remote tag, source commit, version, distribution mode, checksums and update signatures. It uploads both assets to a draft, downloads them for byte comparison, then publishes the release. Verify the latest release and complete any installed-app update test.

## Unsigned distribution

```sh
make release-unsigned
# After verification and pushing vVERSION:
make publish-unsigned
```

Outputs are in `output/releases/VERSION/unsigned/`. The DMG filename includes `-unsigned`. The app has a local **ad hoc** signature required for execution compatibility, but no Developer ID identity; the DMG is unsigned and neither artifact is notarized or stapled. No Apple credentials are used. The receipt records this distinction explicitly.

Include the first-open steps in the Release and README: double-click the downloaded DMG first; after a blocking alert, scroll to Security at the bottom of System Settings → Privacy & Security and allow that installer. Open the DMG again and drag the app into Applications. If the app is also blocked, repeat for the app. Link [Apple's instructions](https://support.apple.com/102445) and embed the annotated Settings screenshot in the Release body, not as a download. Do not describe this distribution as Developer ID signed, notarized, or Gatekeeper-approved. Installation notes stay outside the DMG.

For an explicitly approved packaging-only correction to an existing release, preserve the original DMG and receipts locally. Reuse its verified app with `"$PACER_DMG_PYTHON" scripts/release/package-dmg.py /path/to/Codex\ Pacer.app /path/to/new.dmg`, confirm every app file is unchanged, and repeat the mounted-image and Finder checks. Keep the published tag at the original application source; record the packaging commit separately in the local receipt. Replace only the DMG asset and release notes, then download the public asset and verify it again.

## Developer ID signed distribution

Configure `APPLE_SIGNING_IDENTITY` with a valid Developer ID Application identity. Use `APPLE_NOTARY_PROFILE` for an existing Keychain profile, or `APPLE_ID` and `APPLE_TEAM_ID`; the helper prompts for an app-specific password without echo. `APPLE_PASSWORD` is accepted from an existing secure environment. Never commit credentials or print them in logs.

```sh
make release
make publish
```

This mode signs with hardened runtime, notarizes/staples the app and DMG, and verifies both with Gatekeeper. It requires a receipt marking all of those steps complete. A failure must not be bypassed by publishing the candidate as notarized. The explicit unsigned mode is a separately labelled distribution.

## Promotional assets

Regenerate the approved portrait and matching landscape with `python3 marketing/render.py --stills-only`. Inspect both, commit the README image and source assets, and deliver the full-size images separately. Keep the Release attachments limited to the DMG and signed appcast; do not upload images, checksums or build receipts there. Generated outputs remain ignored by Git.

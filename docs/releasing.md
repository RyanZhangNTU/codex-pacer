# Release workflow

Changes land in `develop`; release promotion targets `main`. Both branches must contain the final source before a release is built. A release includes a matching Git tag, a universal DMG, SHA-256 checksum and published GitHub Release. Previous tags/releases remain intact.

## Prepare and verify

1. Update `native/Info.plist`, README installation instructions and release notes. Run `make test`; inspect the native UI, shutdown and single-instance behavior when application code changes.
2. Merge the preparation PR into `develop`, promote it to `main`, then fast-forward `develop` to the final `main` commit. Stop if either remote branch gained unrelated changes; integrate those without force-pushing.
3. Build from that clean final commit using exactly one distribution mode below. Both modes build arm64 + x86_64 in `/private/tmp`, verify the app signature and DMG structure, mount the DMG read-only, compare the inner executable, check the Applications link, and write a source receipt and `SHA256SUMS.txt`.
4. Launch the actual packaged application on the available Mac. Report any platform/architecture that was compiled but not tested on hardware.
5. Tag the verified commit `vVERSION`, push the tag, and publish using the matching mode. The publisher checks the local/remote tag, source commit, version, distribution mode and checksum. Verify uploaded asset names and download the published package to compare its checksum.

## 2.0.0 unsigned distribution

```sh
make release-unsigned
# After verification and pushing v2.0.0:
make publish-unsigned
```

Outputs are in `output/releases/VERSION/unsigned/`. The DMG filename includes `-unsigned`. The app has a local **ad hoc** signature required for execution compatibility, but no Developer ID identity; the DMG is unsigned and neither artifact is notarized or stapled. No Apple credentials are used. The receipt records this distinction explicitly.

Include the Apple-documented first-launch steps in the Release and README: attempt to launch once, then use System Settings → Privacy & Security → Security to grant an exception for this app. Do not describe this distribution as Developer ID signed, notarized, or Gatekeeper-approved. The DMG includes the release/installation notes.

## Developer ID signed distribution

Configure `APPLE_SIGNING_IDENTITY` with a valid Developer ID Application identity. Use `APPLE_NOTARY_PROFILE` for an existing Keychain profile, or `APPLE_ID` and `APPLE_TEAM_ID`; the helper prompts for an app-specific password without echo. `APPLE_PASSWORD` is accepted from an existing secure environment. Never commit credentials or print them in logs.

```sh
make release
make publish
```

This mode signs with hardened runtime, notarizes/staples the app and DMG, and verifies both with Gatekeeper. It requires a receipt marking all of those steps complete. A failure must not be bypassed by publishing the candidate as notarized. The explicit unsigned mode is a separately labelled distribution.

## Promotional assets

Regenerate the approved portrait and matching landscape with `python3 marketing/render.py --stills-only`. Inspect both, commit the README image and source assets, and attach `Codex-Pacer-2.0-zh-CN-poster.png` and `Codex-Pacer-2.0-zh-CN-banner.png` to the Release. Generated outputs remain ignored by Git.

# Release workflow

Changes land in `develop`; release promotion targets `main`. A release consists of the matching Git tag, signed/notarized universal DMG, SHA-256 checksum and published GitHub Release. Previous 1.x tags/releases remain intact.

1. Update `native/Info.plist` and release notes. Keep a clean checkout, run `make test`, build and inspect the native app with demo and live data. Verify settings, shutdown and a single instance.
2. Merge release preparation into `develop`, then promote to `main` through a release PR. Build from that final commit.
3. Configure `APPLE_SIGNING_IDENTITY` with a valid Developer ID Application identity. Use `APPLE_NOTARY_PROFILE` for an existing Keychain profile, or `APPLE_ID` and `APPLE_TEAM_ID`; the notarization helper prompts for the app-specific password without echo. Do not commit credentials or include them in logs. `APPLE_PASSWORD` is accepted for an existing secure environment.
4. Run `make release`. It builds arm64 + x86_64 in `/private/tmp`, signs with hardened runtime, notarizes/staples the app and DMG, checks signatures/Gatekeeper/DMG integrity and writes `output/releases/VERSION` with a build receipt and `SHA256SUMS.txt`.
5. Read-only mount the DMG and verify its inner app and Applications link. Install/launch the actual signed build, check preferences migration, UI and quit. Unregister obsolete temporary preview copies if needed; never delete user backups.
6. Tag the verified commit `vVERSION`, push the tag, then run `make publish`. The script checks the tag and remote, source receipt, checksum and ticket before upload. Verify the published asset names and downloaded checksum. Upload Chinese promotional exports if part of this release.

The local build helper prints an ad hoc signed `.app` path; it does not create a notarized release. Never describe a signed-only DMG as notarized. Both native architectures compile in the release pipeline; on-device checks performed on only one architecture/OS must be reported accurately.

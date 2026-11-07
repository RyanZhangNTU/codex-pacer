# Automatic updates

Pacer uses Sparkle 2.10.0, pinned in `native/Package.swift` and `native/Package.resolved`. The framework is embedded in `Contents/Frameworks`, with its helper tools signed before the application. The minimum OS remains macOS 14.

The default is one background check per day, followed by user-confirmed download and installation. Settings can disable automatic checks without disabling the manual action. Sparkle owns scheduling and the installation/relaunch flow. Pacer retains its normal shutdown path so activity collectors stop and the single-instance lock is released before relaunch.

## Update source and keys

The stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`. Each release supplies an `appcast.xml` asset whose enclosure points to that release's own DMG. The checked-in `SUFeedURL` and `SUPublicEDKey` are embedded in installed versions; changing either requires a compatibility migration.

The application requires Ed25519 signatures for both the feed and the downloaded archive, with archive verification before extraction. The public key is in `native/Info.plist`. The private key stays in the macOS login Keychain under Sparkle's account `com.codexpacer.app`, with a copy in the `release` environment's `SPARKLE_PRIVATE_KEY` secret for the Release workflow ([release secrets](releasing.md#release-secrets)); it must never enter Git, release assets, logs, or command-line arguments. `scripts/release/sparkle_key.py` hands the tools whichever source is present. Apple Developer ID signing/notarization and Sparkle update signatures serve different purposes; the update signature does not make an ad-hoc build notarized.

Keep a secure backup of the release signing key using Sparkle's documented key export workflow when transferring release ownership or moving machines. Do not regenerate the key for a release. Losing it can prevent installed ad-hoc builds from accepting future updates.

## Packaging and UI integration

Follow [the release workflow](releasing.md) for authorization, versioning, signing commands, publication, isolated QA and installed-app acceptance.

`build-macos-release.sh` embeds Sparkle; `sign-updates.sh` invokes `prepare-update.py`. It generates the archive signature, embeds English and Chinese Markdown with `xml:lang`, signs the completed feed, and verifies both signatures. Editing the XML after signing invalidates it. See Sparkle's [localized release notes](https://sparkle-project.org/documentation/publishing/#localization).

Pacer drives Sparkle with its own user driver (`AppUpdater`) instead of Sparkle's windows, so no update dialog covers the island or other apps. Every check, scheduled or manual, only records the version it finds and ends the session. The version is kept in `pendingUpdate` until the installed build reaches it or a check no longer offers it. It shows in the sidebar under Help & Updates, as a banner at the top of Overview and on the Help & Updates version card; closing the banner hides that version there. **Update and Restart** checks again, then downloads, verifies, installs and relaunches without another question. Progress, Cancel and failures appear in place, and a failure links to the GitHub Release. A manual check shows its result in the card; the app menu's Check for Updates opens Help & Updates first. An installed version without this driver still updates through Sparkle's own window once. `UpdateFlow` holds these rules apart from Sparkle so tests cover them.

## Windows

The Windows app checks, downloads and verifies updates itself and shows them in Pacer's own update window ([details](windows-automatic-updates.md)); 4.2.2 and earlier used WinSparkle behind a loopback proxy. Its feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast-windows.xml`, an asset of the same GitHub Release as the Mac DMG. The Mac `appcast.xml` is unchanged. `WindowsUpdateChannel.Production` in `windows/UpdateSupport/UpdateCatalog.cs` embeds this URL and the Mac `SUPublicEDKey`. A contract test keeps both in step with `native/Info.plist`, and installed Windows versions need the same compatibility migration to change either.

The Release workflow signs both Windows installers and `appcast-windows.xml` with the same key. The feed format, signatures, redirect rules and patch updates are described in [Windows automatic updates](windows-automatic-updates.md#network-and-verification); the release steps are in [the release workflow](releasing.md#3-build-and-publish-once).

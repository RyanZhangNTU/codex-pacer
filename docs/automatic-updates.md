# Automatic updates

Pacer uses Sparkle 2.10.0, pinned in `native/Package.swift` and `native/Package.resolved`. The framework is embedded in `Contents/Frameworks`, with its helper tools signed before the application. The minimum OS remains macOS 14.

The default is one background check per day, followed by user-confirmed download and installation. Settings can disable automatic checks without disabling the manual action. Sparkle owns scheduling and the installation/relaunch flow. Pacer retains its normal shutdown path so activity collectors stop and the single-instance lock is released before relaunch.

## Update source and keys

The stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`. Each release supplies an `appcast.xml` asset whose enclosure points to that release's own DMG. Publishing a draft only after both assets are uploaded and downloaded for comparison keeps the old feed available until the next release is ready.

The application requires Ed25519 signatures for both the feed and the downloaded archive, with archive verification before extraction. The public key is in `native/Info.plist`. The private key stays in the macOS login Keychain under Sparkle's account `com.codexpacer.app`; it must never enter Git, release assets, logs, or command-line arguments. Apple Developer ID signing/notarization and Sparkle update signatures serve different purposes; the update signature does not make an ad-hoc build notarized.

Keep a secure backup of the release signing key using Sparkle's documented key export workflow when transferring release ownership or moving machines. Do not regenerate the key for a release. Losing it can prevent installed ad-hoc builds from accepting future updates.

## Release workflow

Follow [the canonical release workflow](releasing.md) for authorization, versioning, branch promotion, commands, publication, installed-app acceptance and download-count reporting. Do not substitute a separate release procedure here.

`build-macos-release.sh` embeds Sparkle and invokes `prepare-update.py`. It generates the archive signature, embeds English and Chinese Markdown with `xml:lang`, signs the completed feed, and verifies both signatures. Editing the XML after signing invalidates it. See Sparkle's [localized release notes](https://sparkle-project.org/documentation/publishing/#localization).

The publisher validates the feed's release-specific download URL, archive length and signatures, and requires its integer build number to exceed the latest published feed. It uploads both assets to a draft and compares their downloaded bytes before publishing as latest. The checked-in `SUPublicEDKey` and stable `SUFeedURL` are already embedded in installed versions: changing either requires a compatibility migration, not simply removing the old asset or generating another key.

The first public release with Sparkle must still be installed manually by users of older versions. Local integration tests use a separate app identity, test archives and a loopback-only server. Test feeds and fixtures are not published or embedded in production builds.

For updater UI regressions, start with the island expanded and pinned. Check modal latest-version and error alerts, cancellation while checking, a scheduled update prompt, and installation/relaunch. Verify the panel collapses before the updater takes focus, rejects hover/pin/reopen while update UI is active, and restores interaction afterwards. Compare its top-edge position before and after dismissal as well as its size and level: AppKit constrains normal-level windows below the menu bar, so the status-bar level must be restored before the frame in Notch mode.

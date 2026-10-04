# Automatic updates

Pacer uses Sparkle 2.10.0, pinned in `native/Package.swift` and `native/Package.resolved`. The framework is embedded in `Contents/Frameworks`, with its helper tools signed before the application. The minimum OS remains macOS 14.

The default is one background check per day, followed by user-confirmed download and installation. Settings can disable automatic checks without disabling the manual action. Sparkle owns scheduling and the installation/relaunch flow. Pacer retains its normal shutdown path so activity collectors stop and the single-instance lock is released before relaunch.

## Update source and keys

The stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`. Each release supplies an `appcast.xml` asset whose enclosure points to that release's own DMG. The checked-in `SUFeedURL` and `SUPublicEDKey` are embedded in installed versions; changing either requires a compatibility migration.

The application requires Ed25519 signatures for both the feed and the downloaded archive, with archive verification before extraction. The public key is in `native/Info.plist`. The private key stays in the macOS login Keychain under Sparkle's account `com.codexpacer.app`; it must never enter Git, release assets, logs, or command-line arguments. Apple Developer ID signing/notarization and Sparkle update signatures serve different purposes; the update signature does not make an ad-hoc build notarized.

Keep a secure backup of the release signing key using Sparkle's documented key export workflow when transferring release ownership or moving machines. Do not regenerate the key for a release. Losing it can prevent installed ad-hoc builds from accepting future updates.

## Packaging and UI integration

Follow [the release workflow](releasing.md) for authorization, versioning, signing commands, publication, isolated QA and installed-app acceptance.

`build-macos-release.sh` embeds Sparkle and invokes `prepare-update.py`. It generates the archive signature, embeds English and Chinese Markdown with `xml:lang`, signs the completed feed, and verifies both signatures. Editing the XML after signing invalidates it. See Sparkle's [localized release notes](https://sparkle-project.org/documentation/publishing/#localization).

The panel collapses and suspends hover, pin and focus requests while update UI is active. On dismissal, restore its status-bar level before its frame: AppKit constrains normal-level windows below the menu bar, which would displace a Notch-mode island. Background checks without update UI leave the panel unchanged.

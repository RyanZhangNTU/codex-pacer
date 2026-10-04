# Automatic updates

Pacer uses Sparkle 2.10.0, pinned in `native/Package.swift` and `native/Package.resolved`. The framework is embedded in `Contents/Frameworks`, with its helper tools signed before the application. The minimum OS remains macOS 14.

The default is one background check per day, followed by user-confirmed download and installation. Settings can disable automatic checks without disabling the manual action. Sparkle owns scheduling and the installation/relaunch flow. Pacer retains its normal shutdown path so activity collectors stop and the single-instance lock is released before relaunch.

## Update source and keys

The stable feed is `https://github.com/RyanZhangNTU/codex-pacer/releases/latest/download/appcast.xml`. Each release supplies an `appcast.xml` asset whose enclosure points to that release's own DMG. Publishing a draft only after both assets are uploaded and downloaded for comparison keeps the old feed available until the next release is ready.

The application requires Ed25519 signatures for both the feed and the downloaded archive, with archive verification before extraction. The public key is in `native/Info.plist`. The private key stays in the macOS login Keychain under Sparkle's account `com.codexpacer.app`; it must never enter Git, release assets, logs, or command-line arguments. Apple Developer ID signing/notarization and Sparkle update signatures serve different purposes; the update signature does not make an ad-hoc build notarized.

Keep a secure backup of the release signing key using Sparkle's documented key export workflow when transferring release ownership or moving machines. Do not regenerate the key for a release. Losing it can prevent installed ad-hoc builds from accepting future updates.

## Release workflow

1. Increase `CFBundleVersion` for every update. The marketing version alone is not used for update ordering.
2. Add `docs/release-notes-<version>.en.md` and `docs/release-notes-<version>.zh-CN.md`, commit the source, and use the existing release build script. `--unsigned` builds an ad-hoc app while still requiring Sparkle update signatures.
3. `build-macos-release.sh` embeds Sparkle, builds the universal app/DMG, and invokes `prepare-update.py`. The latter checks the configured feed and key, embeds both release notes with `xml:lang`, signs the completed feed, and verifies both feed and archive signatures. Local metadata includes the build number and signing-tool location. See Sparkle's [localized release notes](https://sparkle-project.org/documentation/publishing/#localization).
4. After reviewing the artifacts and obtaining publication approval, use `publish-github-release.sh`. It verifies signatures, source/tag identity, archive size and URL, and increasing build numbers. It creates a draft, uploads and downloads both assets for byte comparison, and then publishes it as the latest release.

The first public release with Sparkle must still be installed manually by users of older versions. Local integration tests use a separate app identity, test archives and a loopback-only server. Test feeds and fixtures are not published or embedded in production builds.

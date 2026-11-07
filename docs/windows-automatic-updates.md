# Windows automatic updates

Pacer for Windows checks, downloads and verifies updates itself and shows them in its own update window, in the Settings style. Since 4.2.3 there is no WinSparkle and no local listener. The feed is `appcast-windows.xml` in the same GitHub Release as the Mac DMG, signed with the Mac appcast's Ed25519 key; see [automatic updates](automatic-updates.md#windows). Releases up to 4.2.2 used WinSparkle behind a loopback proxy, so an update from 4.2.2 still shows that older window once.

## Scheduling and the update window

The automatic preference defaults to enabled and persists under `SUEnableAutomaticChecks`, with the same meaning as the Mac setting. Turning it off leaves manual checks available. The host checks at most once per day from its saved check time, using a sleeping task rather than a polling loop. A failed setting change or preference save restores the previous value and shows an error.

**Check for Updates** on Help & Updates reports in that card instead of a window, as on the Mac: checking, up to date, a found version, or a failure in amber. **Update and Restart** there (or on Overview's update banner) downloads with real progress and Cancel, verifies, and hands off to the installer, which restarts Pacer. A check started anywhere else opens the update window at once with the check's progress. An automatic check opens no window, as on the Mac: a found version shows on Overview's update banner and as a dot by Help & Updates in the sidebar, and the check stays quiet when nothing is found, when it fails, or when the offer is a build the person chose to skip. A manual check still offers a skipped build. The window's stages are:

- **Offer:** the new and installed versions and the signed notes for this language. Buttons: **Skip This Version**, **Remind Me Later** and **Install Update** (the default).
- **Download:** a progress bar with megabytes and percentage, and **Cancel**.
- **Verification**, then **Install and Relaunch**.
- **Up to date**, or a failure with **Try Again**.

Escape closes the window. Later, Cancel and closing all discard an unfinished download.

Inline checks release the island as soon as the result is available. A background offer leaves the island interactive. The offered version stays available if a check fails or the user cancels a download. A successful check that finds no update clears the offer. Update and Restart during a background check waits for that check, and fails like a changed offer if the check replaced the version. Closing Settings during an inline download cancels it.

The notes are the signed Markdown from the feed, rendered from a small subset: headings, paragraphs, lists, bold, code and links. Their colors come only from the Settings palette, so they stay readable in light, dark and high contrast. HTML and other markup stay literal text. Links stay active only for HTTPS GitHub URLs; external release-note URLs and active HTML are never followed.

While the window is open, the island ignores hover, pin and focus requests, and opening Settings or a second instance brings the window forward instead. After a successful upgrade, automatic launch pages use the built-in Welcome / What's New rules, with Welcome taking priority and at most one window per launch. Signed feed notes do not open automatically; **View release notes** in Settings fetches and verifies the signed feed again and shows only this installed build's notes. The version comparison uses the packaged **file version**, including the build revision.

## Network and verification

Requests use HTTPS only. The feed URL is fixed in the channel configuration, and package URLs come only from signed feed metadata. Production follows at most four redirects, and only to `github.com`, `objects.githubusercontent.com` and `release-assets.githubusercontent.com`; QA channels refuse every redirect. The HTTP client forwards no cookies, credentials or caller headers.

Limits:

- **Feed:** 1 MiB and 20 seconds. Its signature is checked before XML parsing; DTDs and external entities are disabled. Compatible architecture, numeric build and minimum Windows version are required.
- **Package:** at most 256 MiB, and exactly the signed length. A `Content-Length` that differs fails before any byte is written, and the download stops as soon as more bytes than signed arrive. A connection idle for 60 seconds fails, as does a download still running after 60 minutes.

The package streams into `setup.exe.download` in a new owned session directory and reports progress. Only after its length and Ed25519 signature pass is it renamed to `setup.exe`. Any failure or cancellation deletes the partial file. An offer older than 30 minutes is verified again when the download starts; if the feed now selects a different build, that build replaces the offer.

The release Mac signs both installers and the feed with the Mac appcast's Keychain key (`prepare-windows-update.py`, run by the [release build](releasing.md#3-build-and-publish-once)), with one feed entry per architecture and English and Simplified Chinese notes. The feed starts with a `<!-- pacer-feed-ed25519:SIGNATURE -->` line covering the XML bytes that follow, and each `enclosure` carries the installer's `sparkle:edSignature`; the signatures, not the redirect hosts, establish trust. The script signs the feed body under a non-`.xml` name because `sign_update` rewrites files it recognizes as appcasts. A missing Windows feed means there is no Windows update yet.

Diagnostics retain only the exception type and error code. Pacer never logs complete URLs, query parameters, remote response text or keys.

## Patch updates

From 4.2.3 each release publishes its file manifest (`build-info.json`) for each architecture. When the next release is built, the Release workflow makes a patch installer from the latest published manifest; the new release is still a draft then, so the latest is the previous one. Until the version is bumped, the latest release is the build being made, so CI builds only the full installer. It is an ordinary Inno Setup installer with the same product identity and build, but it carries only the files whose content changed, the new manifest and the maintenance host. Builds are reproducible, so a patch is usually a small fraction of the full installer.

The release Mac signs a patch and lists it only when its base is still the latest build in the signed public feed. It sits inside `<sparkle:deltas>` with `sparkle:deltaFrom` (the base build) and `pacer:baseManifestSHA256`. The full installer stays the item's only direct enclosure and gains `pacer:manifestSHA256`. Windows 4.2.2 and earlier read only that direct enclosure, so they keep installing in full; a test runs the 4.2.2 parser, frozen, on the new feed shape.

The app takes the patch only when all of the following hold:

- the patch is from exactly the running build;
- the SHA-256 of the installed `build-info.json` equals the patch's base;
- this build's patch has not already failed here.

Otherwise it downloads the full installer. The offer shows the download size and says when only changed files are downloaded. Download, Ed25519 and length verification, and the handoff are the same as for a full installer.

Before changing anything, the patch installer checks that the installation is exactly its base, and that every file the patch does not carry already holds the new content. A modified or different installation is refused and left untouched. The relaunched app then records the failed patch and offers the same update again as the full installer. After copying, the patch verifies every file against the new manifest. Files the new build no longer lists are removed by the usual stale-file pass.

`test-patch.ps1` covers this with a synthetic next build in an isolated QA scope. It changes, adds and drops one file each, then checks:

- a modified installation refuses the patch;
- the patch turns the base into the next build;
- the same patch is refused a second time;
- uninstall leaves nothing behind.

## Installation and recovery

Update state uses a checked, bounded, versioned file at `%LOCALAPPDATA%\CodexPacer\Updates\state-v1.json`, never HKCU. It holds the schedule, the skipped build and the presented notes; the keys keep the names WinSparkle used, so existing choices carry over. Update files reject reparse points and hard links. Their owner must be the current user, or Administrators when the current token is elevated with that group enabled. Future state versions are preserved.

Each update uses `Updates\<session>`. When the channel configures `SignerSHA256`, both sides of the handoff additionally require cached Windows Authenticode trust and that exact signer-certificate SHA-256. An absent pin permits an unsigned installer; production pins no signer because the installers are not Authenticode signed yet, and adding one later makes Authenticode mandatory for every subsequent update. Empty or malformed pins are rejected; they cannot select unsigned mode. Ed25519 and SHA-256 remain mandatory at both handoff boundaries in either mode. The installer product name, QA identity and file build must still match the signed offer.

The handoff to the helper:

1. The host adds the self-contained maintenance executable and a plan to the session that holds the verified installer.
2. The helper waits for the original process to exit. Normal app shutdown stops collectors, browsers and owned processes and releases the instance lock first.
3. It verifies the installer again and runs it with `/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART /LANG=<app language> /LOG=<session>\install.log /DIR=<installation>`. The installer shows only its progress, because the person already chose to install. Each value is a separate argument, so spaces and Chinese paths are preserved.
4. Afterwards it keeps the log as `Updates\last-install.log`, deletes the installer, and records in `result.json` whether installation succeeded, with the offered build and its notes.

Cancellation, failed verification or installer failure relaunches the existing application and reports failure. Failure to save the result cannot prevent relaunch. A still-running installer is never killed or overlapped with a relaunch. If damaged application files prevent relaunch, repair is required.

The relaunched app reads the result once, then deletes finished sessions in the background. It retries for a minute while the helper exits, and anything still locked goes at the next start. Cleanup removes only folders named as a session that hold only the files above. Uninstall removes them too; the state file and `last-install.log` stay with the retained preferences.

## Development and QA checks

`WindowsUpdateChecks` covers:

- signed and tampered feeds and packages, and both optional-signer modes;
- architecture, OS and build selection;
- TLS certificate pins and production and QA redirect rules;
- streamed downloads with growing progress, size mismatches, oversized bodies, stalls, cancellation and upstream failures, none of which leave a file behind;
- the service's offer, skip, later, stale-offer, up-to-date and failure paths;
- daily and manual scheduling and preference rollback;
- session cleanup, shutdown and install ordering, cancellation recovery and once-only notes;
- patch selection: the exact base build and manifest, fallback to the full installer for a modified installation or after a failed patch, and the frozen 4.2.2 parser on a feed with patches;
- the release-notes Markdown subset.

Its HTTPS fixture creates only a temporary test key; no certificate is installed in a trust store. `UpdateWindowChecks` (presentation group `updates`) renders every window stage in both languages and themes, checks note contrast, progress text and default actions, and saves captures.

```powershell
dotnet run --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --updates-only
./scripts/windows/test-presentation.ps1 -Group updates
```

For UI and install acceptance, build an installer with an isolated `QaScope` using the existing installer workflow; its product metadata includes that scope. The fixture serves that installer over loopback HTTPS and signs its feed and package with an in-memory test key. It writes only public channel configuration. An optional argument paces the package in bytes per second so download progress can be watched. A QA patch built with `package-installer.ps1 -BaseManifest` can follow it (with a pace, 0 for none); the fixture then publishes it from the QA build override, for the base its metadata names:

```powershell
dotnet run --no-build --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --serve-update-feed <isolated-output-directory> <scope-in-N-format> <QA-installer> x64 [bytes-per-second [QA-patch]]
```

Start the matching QA installation with `--demo --reference-fixture --activation-qa <scope> --update-qa <isolated-output-directory>/channel.json`. The fixture supplies a test-only current-build override, so the same packaged version can exercise the update path without changing `Info.plist` or project versions; production rejects the override. Press Enter or close the fixture's stdin to stop it; its maximum lifetime is 30 minutes.

After publication, verify a real installed upgrade from a normal desktop session (see [the release workflow](releasing.md)).

## Dependency

BouncyCastle.Cryptography 2.7.0 is pinned for managed Ed25519 verification; its license is included with the app. To take a security update, review upstream changes, update the package pin, refresh the NuGet lock files and notices, then rerun the targeted signature and lifecycle checks. This does not rotate application trust keys or change the Mac updater.

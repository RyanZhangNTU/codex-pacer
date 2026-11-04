# Windows automatic updates

Pacer for Windows checks, downloads and verifies updates itself and shows them in its own update window, in the Settings style. Since 4.2.3 there is no WinSparkle and no local listener. The feed is `appcast-windows.xml` in the same GitHub Release as the Mac DMG, signed with the Mac appcast's Ed25519 key; see [automatic updates](automatic-updates.md#windows). Releases up to 4.2.2 used WinSparkle behind a loopback proxy, so an update from 4.2.2 still shows that older window once.

## Scheduling and the update window

The automatic preference defaults to enabled and persists under `SUEnableAutomaticChecks`, with the same meaning as the Mac setting. Turning it off leaves manual checks available. The host checks at most once per day from its saved check time, using a sleeping task rather than a polling loop. A failed setting change or preference save restores the previous value and shows an error.

**Check for Updates** in Settings opens the window at once with the check's progress. An automatic check opens it only for an offer, without taking focus, and stays quiet when nothing is found, when the check fails, or when the offer is a build the person chose to skip. A manual check still offers a skipped build. The window's stages are:

- **Offer:** the new and installed versions and the signed notes for this language. Buttons: **Skip This Version**, **Remind Me Later** and **Install Update** (the default).
- **Download:** a progress bar with megabytes and percentage, and **Cancel**.
- **Verification**, then **Install and Relaunch**.
- **Up to date**, or a failure with **Try Again**.

Escape closes the window. Later, Cancel and closing all discard an unfinished download.

The notes are the signed Markdown from the feed, rendered from a small subset: headings, paragraphs, lists, bold, code and links. Their colors come only from the Settings palette, so they stay readable in light, dark and high contrast. HTML and other markup stay literal text. Links stay active only for HTTPS GitHub URLs; external release-note URLs and active HTML are never followed.

While the window is open, the island ignores hover, pin and focus requests, and opening Settings or a second instance brings the window forward instead. After a successful upgrade, automatic launch pages use the built-in Welcome / What's New rules, with Welcome taking priority and at most one window per launch. Signed feed notes do not open automatically; **View release notes** in Settings fetches and verifies the signed feed again and shows only this installed build's notes. The version comparison uses the packaged **file version**, including the build revision.

## Network and verification

Requests use HTTPS only. The feed URL is fixed in the channel configuration, and package URLs come only from signed feed metadata. Production follows at most four redirects, and only to `github.com`, `objects.githubusercontent.com` and `release-assets.githubusercontent.com`; QA channels refuse every redirect. The HTTP client forwards no cookies, credentials or caller headers.

Limits:

- **Feed:** 1 MiB and 20 seconds. Its signature is checked before XML parsing; DTDs and external entities are disabled. Compatible architecture, numeric build and minimum Windows version are required.
- **Package:** at most 256 MiB, and exactly the signed length. A `Content-Length` that differs fails before any byte is written, and the download stops as soon as more bytes than signed arrive. A connection idle for 60 seconds fails, as does a download still running after 60 minutes.

The package streams into `setup.exe.download` in a new owned session directory and reports progress. Only after its length and Ed25519 signature pass is it renamed to `setup.exe`. Any failure or cancellation deletes the partial file. An offer older than 30 minutes is verified again when the download starts; if the feed now selects a different build, that build replaces the offer.

Diagnostics retain only the exception type and error code. Pacer never logs complete URLs, query parameters, remote response text or keys.

## Installation and recovery

Update state uses a checked, bounded, versioned file at `%LOCALAPPDATA%\CodexPacer\Updates\state-v1.json`, never HKCU. It holds the schedule, the skipped build and the presented notes; the keys keep the names WinSparkle used, so existing choices carry over. Update files reject reparse points and hard links. Their owner must be the current user, or Administrators when the current token is elevated with that group enabled. Future state versions are preserved.

Each update uses `Updates\<session>`. **签名者校验随签名方案开启。** When the channel configures `SignerSHA256`, both sides of the handoff additionally require cached Windows Authenticode trust and that exact signer-certificate SHA-256. An absent pin permits an unsigned installer. Empty or malformed pins are rejected; they cannot select unsigned mode. Ed25519 and SHA-256 remain mandatory at both handoff boundaries in either mode. The installer product name, QA identity and file build must still match the signed offer.

The handoff to the helper:

1. The host adds the self-contained maintenance executable and a plan to the session that holds the verified installer.
2. The helper waits for the original process to exit. Normal app shutdown stops collectors, browsers and owned processes and releases the instance lock first.
3. It verifies the installer again and runs it with `/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART /LANG=<app language> /LOG=<session>\install.log /DIR=<installation>`. The installer shows only its progress, because the person already chose to install. Each value is a separate argument, so spaces and Chinese paths are preserved.
4. Afterwards it keeps the log as `Updates\last-install.log`, deletes the installer, and records in `result.json` the version Windows now lists under Installed apps.

Cancellation, failed verification or installer failure relaunches the existing application and reports failure. Failure to save the result cannot prevent relaunch. A still-running installer is never killed or overlapped with a relaunch. If damaged application files prevent relaunch, repair is required.

The relaunched app reads the result once, then deletes finished sessions in the background. It retries for a minute while the helper exits, and anything still locked goes at the next start. Cleanup removes only folders named as a session that hold only the files above. Uninstall removes them too; the state file and `last-install.log` stay with the retained preferences.

## Development checks and integration acceptance

`WindowsUpdateChecks` covers:

- signed and tampered feeds and packages, and both optional-signer modes;
- architecture, OS and build selection;
- TLS certificate pins and production and QA redirect rules;
- streamed downloads with growing progress, size mismatches, oversized bodies, stalls, cancellation and upstream failures, none of which leave a file behind;
- the service's offer, skip, later, stale-offer, up-to-date and failure paths;
- daily and manual scheduling and preference rollback;
- session cleanup, shutdown and install ordering, cancellation recovery and once-only notes;
- the release-notes Markdown subset.

Its HTTPS fixture creates only a temporary test key; no certificate is installed in a trust store. `UpdateWindowChecks` (presentation group `updates`) renders every window stage in both languages and themes, checks note contrast, progress text and default actions, and saves captures.

```powershell
dotnet run --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --updates-only
./scripts/windows/test-presentation.ps1 -Group updates
```

For UI and install acceptance, build an installer with an isolated `QaScope` using the existing installer workflow; its product metadata includes that scope. The fixture serves that installer over loopback HTTPS and signs its feed and package with an in-memory test key. It writes only public channel configuration. An optional last argument paces the package in bytes per second so download progress can be watched:

```powershell
dotnet run --no-build --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --serve-update-feed <isolated-output-directory> <scope-in-N-format> <QA-installer> x64 [bytes-per-second]
```

Start the matching QA installation with `--demo --reference-fixture --activation-qa <scope> --update-qa <isolated-output-directory>/channel.json`. The fixture supplies a test-only current-build override, so the same packaged version can exercise the update path without changing `Info.plist` or project versions; production rejects the override. Press Enter or close the fixture's stdin to stop it; its maximum lifetime is 30 minutes.

After publication, verify a real installed upgrade from a normal desktop session (see [the release workflow](releasing.md)).

## Dependency

BouncyCastle.Cryptography 2.7.0 is pinned for managed Ed25519 verification; its license is included with the app. To take a security update, review upstream changes, update the package pin, refresh the NuGet lock files and notices, then rerun the targeted signature and lifecycle checks. This does not rotate application trust keys or change the Mac updater.

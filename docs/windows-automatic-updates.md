# Windows automatic updates

Windows uses WinSparkle 0.9.4 for its update window, download confirmation and package-signature check. The host verifies the feed before WinSparkle receives it and owns scheduling, proxy lifetime and installation handoff. The [WinSparkle C API](https://winsparkle.org/c-api/setup-lifecycle/) provides callbacks and a file-backed configuration interface; its [installer callback](https://winsparkle.org/c-api/callbacks/) lets Pacer finish normal shutdown before an installer starts.

Production Windows hosting and the Ed25519 public key are unconfigured. The preview shows that status and makes no production request. Provisioning them needs a separate authorized change. The optional Authenticode signer pin depends on the signing scheme selected later. Mac's feed, trust keys, Sparkle parameters, version source and update implementation are untouched.

## Scheduling and UI

The automatic preference defaults to enabled and persists under `SUEnableAutomaticChecks`, with the same meaning as the Mac setting. Turning it off leaves manual checks available. The Windows host schedules a check at most once per day from its saved check time. It uses a sleeping task, not a polling loop. WinSparkle's own automatic scheduler stays off so it cannot contact an inactive proxy.

Calls into the native updater run on workers. Initialization has a 10-second deadline and check/configuration calls have a 3-second deadline. A stalled native call disables further requests until restart; late callbacks cannot revive that operation. A failed setting change or preference save restores the previous value and shows an error. WinSparkle callbacks carry an operation generation so an old completion cannot close a newer connection.

While update UI is active, the island collapses and ignores hover, pin and focus requests. Dismissal restores input. Settings remain interactive. The signed inline English or Chinese notes are selected for that build; external release-note URLs and active HTML are not passed through. After a successful upgrade, automatic launch pages use the built-in Welcome / What's New rules, with Welcome taking priority and at most one window per launch. Signed feed notes do not open automatically. Settings offers an explicit View release notes action, which fetches and verifies the signed feed again and selects only this installed build. Installation or verification failure still shows its status. The comparison uses the packaged **file version**, including the build revision.

## Local proxy boundaries

Construction and initialization do not listen. A check creates one operation with a new IPv4 `127.0.0.1` listener, an OS-selected port and a 192-bit random path token. There is no IPv6 or wildcard binding. A missing, incorrect or old token receives 404. The only routes are the current feed and opaque identifiers for packages declared by that verified feed. There is no command or general URL-forwarding endpoint.

Upstream requests use HTTPS only. The feed URL is fixed in the channel configuration; package URLs come only from signed feed metadata. All redirects, including same-host redirects, are errors. The HTTP client does not forward the caller's cookies, credentials or headers. The WinSparkle-to-proxy connection is HTTP on loopback; it never exposes an upstream URL or its query to WinSparkle.

Limits are 8 KiB/5 seconds for request headers, 1 MiB/20 seconds for the signed feed, 256 MiB/5 minutes for a package and four concurrent clients. Feed signatures are checked before XML parsing; DTDs and external entities are disabled. Compatible architecture, numeric build and minimum Windows version are required. Package length and Ed25519 signature are checked before any package bytes are returned to WinSparkle, and checked again before handoff.

No update, cancellation/dismissal, error and installer handoff all close the listener. Waiting for confirmation and downloading count as the same operation. **After 30 consecutive minutes without an authorized request, the proxy closes even if the WinSparkle window is still open. Selecting Download then starts a fresh check and proxy, with a new port and token.** It does not reuse the expired offer. This is a known UI limitation to include in the integration PR description.

Download, TLS and signature failures return HTTP 502 with a fixed error body and revoke the operation's installer candidates. Diagnostics retain only exception type/error code. Pacer does not log tokens, complete URLs, query parameters, remote response text or keys.

## Installation and recovery

All three WinSparkle configuration callbacks use a checked, bounded versioned file; none falls back to HKCU. Update files reject reparse points and hard links. Ownership must match the current user, or Administrators when the current token is elevated with that group enabled. Future state versions are preserved.

The host copies a verified package and the self-contained maintenance executable into its owned update directory. **签名者校验随签名方案开启。** When the channel configures `SignerSHA256`, both sides of the handoff additionally require cached Windows Authenticode trust and that exact signer-certificate SHA-256. An absent pin permits an unsigned preview installer. Empty or malformed pins are rejected; they cannot select unsigned mode. Ed25519 and SHA-256 remain mandatory at both handoff boundaries in either mode.

The installer product name, QA identity and file build must still match the signed offer. Test-only TLS trust and build overrides remain limited to an explicitly scoped, installed demo QA application using a loopback HTTPS feed and its isolated test key. A test channel can also provide `signerSHA256` to exercise the additional signer requirement.

The helper waits for the original process identity to exit before re-verifying and starting the installer. Normal app shutdown stops collectors, browsers and owned processes and releases the instance lock first. The installer runs with `/SILENT /SUPPRESSMSGBOXES`, showing only its progress, because the person already chose to install in the update offer. Installer argv are separate arguments and preserve spaces and Chinese paths. Cancellation, failed verification or installer failure relaunches the existing application and reports failure. Failure to save the result cannot prevent relaunch. A still-running installer is never killed or overlapped with a relaunch. If damaged application files prevent relaunch, repair is required.

## Development checks and integration acceptance

`WindowsUpdateChecks` covers signed/tampered feeds and packages, both optional-signer modes, architecture/OS/build selection, TLS certificate pins, rejection of redirects, operation tokens, idle closure, stale callbacks, daily/manual scheduling, asynchronous timeout, preference rollback, shutdown/install ordering, cancellation recovery and once-only notes. Both signer modes reject a wrong content hash, Ed25519 signature or key. Its HTTPS fixture creates only a temporary test key; no certificate is installed in a trust store. The native smoke check loads the pinned DLL and validates isolated public keys without starting update UI.

Run the targeted checks after a Debug build:

```powershell
dotnet run --no-build --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --updates-only output/toolchains/winsparkle/0.9.4/x64
```

For the later integration UI/install acceptance, build an installer with an isolated `QaScope` using the existing installer workflow. Its product metadata includes that scope. This fixture serves that installer over loopback HTTPS, signs its feed and package with an in-memory test key, and writes only public channel configuration:

```powershell
dotnet run --no-build --project windows/Tests/DesktopTests/Pacer.DesktopTests.csproj -c Debug -- --serve-update-feed <isolated-output-directory> <scope-in-N-format> <QA-installer> x64
```

Start the matching QA installation with `--demo --reference-fixture --activation-qa <scope> --update-qa <isolated-output-directory>/channel.json`. The fixture supplies a test-only current-build override, so the same packaged version can exercise the update path without changing `Info.plist` or project versions. The override is rejected for production. Press Enter or close the fixture's stdin to stop it; its maximum lifetime is 30 minutes.

The current development checks do **not** claim WinSparkle window, complete installer/relaunch, ARM64 hardware or Windows 10 hardware acceptance. Those belong to the unified integration and preview phase. No Release build, installer package or UI matrix was run for this feature during batch development.

## Dependency and build interface

`windows/winsparkle-lock.json` pins the official archive URL, archive SHA-256 and both DLL hashes. `setup-winsparkle.ps1 -Architecture x64|arm64` extracts only that architecture and the upstream MIT notices. Desktop builds use `PacerArchitecture`; `RuntimeIdentifier=win-arm64` also selects ARM64. C owns the broader platform-matrix/build work. B owns these updater DLLs and their packaging.

BouncyCastle.Cryptography 2.7.0 is pinned for managed Ed25519 verification; its license is included with the app. To take a security update, review upstream changes, update the archive/package pins and runtime DLL hashes together, refresh NuGet lock files and notices, then rerun the targeted signature, lifecycle and native ABI checks before integration. This does not rotate application trust keys or change the Mac updater.

## 待 Mac 实机检查

无。此功能仅修改 Windows。分支里前一项 Claude 远程 hooks 的可选 Core 注入仍需在统一集成时确认 Mac 原有 SSH 行为。

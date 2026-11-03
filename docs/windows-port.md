# Shared Core and Windows follow-up

The C phase closes the temporary source-selection mechanism. Both packages compile the entire `native/Sources/PacerCore` directory. New Core files enter both builds automatically; there is no Windows source or test inventory.

`PacerCore` owns provider parsing, state, projections and lifecycle policy. `PacerMacSupport` supplies Mac IO. The separate `PacerEngineSupport` target depends on Core and supplies Windows IO and engine protocol assembly. Native Windows calls stay in host code. Core cannot depend on either host target.

Both platforms run the complete `PacerCoreTests` target. Mac application discovery, Keychain, POSIX permissions, Unix sockets and actual Unix helper-process tests live in `PacerMacSupportTests`. Mixed suites retain their portable cases in Core tests. Synthetic Python programs and arguments use temporary files so Windows command-line limits do not remove test coverage.

The platform contract recursively scans Core, rejects host imports and business/platform conditionals, and checks full-directory target wiring. The only conditional imports are guarded `FoundationNetworking` and `CoreGraphics` imports. Mac and Windows CI run the same contract tests. Windows also compiles a forbidden Windows-type reference with the actual Core compiler command and verifies that it fails.

Shipping identity, resources, dependency pins and native/release scripts retain their existing protection. This build separation does not change provider paths, credentials, navigation, retention or the 650 ms shutdown budget.

## Remaining work

The 47-feature acceptance record is [platform-coverage.json](../windows/platform-coverage.json). Compilation and synthetic tests do not establish installed-host parity. Remaining work stays in that record and the relevant guides:

F1 merged in #137: observed Claude initialization backlog and bounded cold-history reads use the shared reader. Its real Mac smoke checks remain pending.

- P1: installed Windows lifecycle, provider login/storage, notifications, packaging and supported-platform acceptance. See [installation](windows-installation.md).
- P2: connect the compiled SSH, Remote Control and Cloud paths to Windows host services; preserve source and account isolation.
- P3: remaining settings/help/onboarding, keyboard, accessibility and display acceptance. See [the WPF guide](windows-shell.md).
- Material acceptance: #148 adds a native Composition background below the WPF content. Remaining device/DPI/system checks stay in coverage and [the Composition guide](windows-composition-backdrop.md); the earlier prototype branch remains separate.

Cadence test maintenance remains separate: verify explicit synchronization and a controlled clock with 20 consecutive passes on each Mac architecture, while retaining five-second batching, immediate expansion flush and no resubscription.

Mac hardware checks remain pending. The C closeout changes build boundaries and test placement; it is expected to preserve app behavior. Future work must follow the current supervisor instructions and existing release authorization limits.

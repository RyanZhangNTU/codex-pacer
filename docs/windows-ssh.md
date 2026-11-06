# Windows SSH sources

Windows reads hosts already saved by Codex or Claude. It uses the shared discovery, canonical route keys, activity monitors, runtime projection and shutdown deadline. Claude Desktop routes come from `ssh_configs.json` in the [active Desktop data folder](windows-shell.md#claude-desktop-data-folder); the selected Claude home's `settings.json` can override them. SSH identity paths use Windows absolute-path validation. Mac keeps its existing paths and validation defaults.

The General setting **Monitor Tasks on SSH Hosts** uses the Mac `monitorSSH` key, with an absent key meaning enabled. Disabling it closes owned helpers; enabling it discovers the saved sources again. Configuration refreshes retain healthy connections. Sleep and exit close stdin and use the shared 650 ms cleanup deadline, with forced termination of owned children when needed.

The host prefers `%SystemRoot%\System32\OpenSSH\ssh.exe`, then searches absolute PATH entries. Route resolution uses bounded `ssh -G` output. Connections require `BatchMode=yes` and `StrictHostKeyChecking=yes`; password prompts, host-key updates, local commands, agent forwarding, forwarding and connection sharing are disabled. Pacer does not edit SSH config or known_hosts. Missing access or an unknown key remains an unavailable source until the user establishes access separately.

Shared collector commands travel in a bounded length-prefixed stdin frame. A small remote Python bootstrap reads exactly that frame before executing the unchanged command; later control messages and EOF retain their order. This avoids Windows' command-line length limit without writing a helper onto the remote host.

Opening a task passes a structured base64 plan to a separate console mode of `PacerEngine.exe`. That mode validates the route and UUID again using Core before launching SSH with a TTY. Windows Terminal is preferred; a normal console is the fallback. Codex opens `codex resume <UUID>` and Claude uses the shared `ClaudeRemoteResume` program. Neither supplies a prompt. Terminal activation confirms that the console was opened; an authentication or missing-CLI failure can still appear in that console.

## Verification

`WindowsSSHTests` uses a synthetic SSH executable with disposable local directories. It covers discovery and deduplication, route caching, Windows identity paths, unchanged SSH files, long commands, split output, ordered stdin/EOF, approval/reply/ending projection, reconnect, disable/reopen and shutdown. The fixture's POSIX compatibility shims are test code only. Desktop tests check terminal argv, console fallback and preference persistence. The `ssh` presentation group checks the setting in English/Chinese and light/dark appearances.

No real remote is modified by these tests, and they do not exercise a real noninteractive target, Windows Terminal/console TTY resume or remote sleep/reconnect. WSL and Remote Control sources are described in [the WPF shell guide](windows-shell.md#wsl-sources).

## Claude remote hooks

Reachable Claude sources use Core's `ClaudeRemoteAutoSetup` and `ClaudeRemoteSetup`. Automatic setup requires an existing remote Claude home. It preserves user hooks, wraps the previous status-line renderer with the shared ownership manifest, and respects telemetry conflicts. The shipped adapter digest controls upgrades; a failed attempt waits 30 minutes before the next automatic retry. A single sleeping timer handles that deadline. No idle polling loop is added.

Windows sends the shared installer through the same bounded stdin frame as collectors, then sends EOF without applying the streaming helper's 500 ms close escalation. Core still limits setup to 15 seconds. Disablement, source replacement, sleep and quit revoke ownership and cancel setup; late results cannot update the cache or restart a discarded source. Successful setup refreshes that source's collector. Read-only diagnostics and demo mode do not install hooks.

The bounded version-1 cache contains only validated SSH aliases and adapter digests. It uses the existing `claudeRemoteSetupDigests` contract. Unknown versions and unsafe paths are preserved. Cache loss only causes the idempotent installer to check the remote setup again.

For the connection-page host, snapshots add `claudeRemoteSetups`: each row has `sourceID`, an opaque `context`, `configured`, `inFlight`, `canRetry`, an optional localized `message`, and optional Unix `retryAt`. Send `retryClaudeRemoteSetup` with the current row's `sourceID` and `context`. The engine resolves its owned target; the caller cannot supply a host or a command. The reply acknowledges scheduling, and later snapshots report the result. The UI must keep its normal asynchronous request timeout.

`WindowsClaudeRemoteTests` executes the unchanged shared installer only in disposable synthetic remotes. It checks existing user entries and renderer metadata, byte-identical repeat installation, malformed settings, missing Claude homes, telemetry conflicts, EOF/timeout, digest upgrades, retry boundaries, manual retry, revocation and private output. It installs no hooks on a real host.

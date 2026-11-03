# Windows SSH sources

Windows reads hosts already saved by Codex or Claude. It uses the shared discovery, canonical route keys, activity monitors, runtime projection and shutdown deadline. Claude Desktop routes come from the first existing `ssh_configs.json` in its roaming or packaged app-data locations; the selected Claude home's `settings.json` can override them. SSH identity paths use Windows absolute-path validation. Mac keeps its existing paths and validation defaults.

The General setting **Monitor Tasks on SSH Hosts** uses the Mac `monitorSSH` key, with an absent key meaning enabled. Disabling it closes owned helpers; enabling it discovers the saved sources again. Configuration refreshes retain healthy connections. Sleep and exit close stdin and use the shared 650 ms cleanup deadline, with forced termination of owned children when needed.

The host prefers `%SystemRoot%\System32\OpenSSH\ssh.exe`, then searches absolute PATH entries. Route resolution uses bounded `ssh -G` output. Connections require `BatchMode=yes` and `StrictHostKeyChecking=yes`; password prompts, host-key updates, local commands, agent forwarding, forwarding and connection sharing are disabled. Pacer does not edit SSH config or known_hosts. Missing access or an unknown key remains an unavailable source until the user establishes access separately.

Shared collector commands travel in a bounded length-prefixed stdin frame. A small remote Python bootstrap reads exactly that frame before executing the unchanged command; later control messages and EOF retain their order. This avoids Windows' command-line length limit without writing a helper onto the remote host.

Opening a task passes a structured base64 plan to a separate console mode of `PacerEngine.exe`. That mode validates the route and UUID again using Core before launching SSH with a TTY. Windows Terminal is preferred; a normal console is the fallback. Codex opens `codex resume <UUID>` and Claude uses the shared `ClaudeRemoteResume` program. Neither supplies a prompt. Terminal activation confirms that the console was opened; an authentication or missing-CLI failure can still appear in that console.

## Verification and remaining acceptance

`WindowsSSHTests` uses a synthetic SSH executable with disposable local directories. It covers discovery and deduplication, route caching, Windows identity paths, unchanged SSH files, long commands, split output, ordered stdin/EOF, approval/reply/ending projection, reconnect, disable/reopen and shutdown. The fixture's POSIX compatibility shims are test code only. Desktop tests check terminal argv, console fallback and preference persistence. The `ssh` presentation group checks the setting in English/Chinese and light/dark appearances.

No real remote is modified by these tests. A user must still verify an existing noninteractive target, real Windows Terminal/console TTY resume and remote sleep/reconnect. Preview coverage stays partial. Claude remote hook installation, its version checks, automatic retry and manual retry belong to the following Claude remote PR; this step reads existing remote instrumentation only. WSL and Remote Control are separate work.

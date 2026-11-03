Codex Pacer 4.2.1 comes to Windows, and fixes Claude Code tasks that stayed marked as running after `/code-review` and similar skills had finished.

- **Codex Pacer for Windows.** The same island, task list, quota rings, reminders and Settings as on the Mac, for Codex, Claude Code and DeepSeek Harness, including SSH hosts, WSL and Codex Remote Control. It needs Windows 10 2004 (build 19041) or later on x64 or ARM64; Windows 11 22H2 and later get the glass surface.
- A skill that runs in its own agent, such as `/code-review`, no longer leaves its task marked as running once it has finished. Such a skill reports its agent differently from the Agent tool, so Pacer never saw that agent end. It now ends when the skill returns; a skill started in the background ends when Claude reports it finished.

### Install

- **Mac, existing installation:** use **Check for Updates** to update in place. Your preferences are preserved.
- **Mac, manual installation:** quit Codex Pacer, replace the copy in Applications with the new app, then open it again. Requires macOS 14 or later.
- **Windows:** run the installer for your PC, listed below. It installs for the current user without administrator rights, and later versions update from **Settings → General**.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

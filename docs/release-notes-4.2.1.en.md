Codex Pacer 4.2.1 fixes Claude Code tasks that stayed marked as running after `/code-review` and similar skills had finished.

- A skill that runs in its own agent, such as `/code-review`, no longer leaves its task marked as running once it has finished. Such a skill reports its agent differently from the Agent tool, so Pacer never saw that agent end. It now ends when the skill returns; a skill started in the background ends when Claude reports it finished.

### Install

- **Existing installation:** use **Check for Updates** to update in place. Your preferences are preserved.
- **Manual installation:** quit Codex Pacer, replace the copy in Applications with the new app, then open it again.
- Requires macOS 14 or later.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

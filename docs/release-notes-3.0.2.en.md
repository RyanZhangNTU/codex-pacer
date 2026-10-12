Codex Pacer 3.0.2 fixes a task-status issue that could make an ended local Codex child task appear to be running.

- Older parent status hints no longer override a newer child completion or interruption.
- Ended child tasks stay ended after Pacer reconnects, wakes from sleep or relaunches while the parent task runs. A finished conversation is no longer kept running by its children.
- Removing a running hint restores the state recorded in the task log, even when the log has not changed. Confirmed endings survive the parent subscription closing, and a genuinely new activation can still resume the task.

### Install

- **Existing installation:** after this version is published, use **Check for Updates** to update in place. Your preferences are preserved.
- **Manual installation:** quit Codex Pacer, replace the copy in Applications with the new app, then open it again.
- Requires macOS 14 or later.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

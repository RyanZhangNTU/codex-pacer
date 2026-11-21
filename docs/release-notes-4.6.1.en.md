**Codex tasks are back.** Codex 26.1117 removed the connection Pacer read Codex tasks from ([#275](https://github.com/RyanZhangNTU/codex-pacer/issues/275)). Pacer now follows Codex through Codex's own hooks, so local Codex tasks, their progress and approval requests show again. After updating, Pacer shows two steps: update Codex if it's too old, then allow Pacer in Codex once. **Open Codex** opens Codex's settings with a small guide beside them, and each step checks itself off. New users see the same steps in the welcome guide.

**Pacer tells you if Codex goes quiet.** If Codex runs tasks that Pacer doesn't hear about, Settings → Remote and the collapsed bar say so, and the warning clears by itself once Pacer hears from Codex again.

**Remote Control is removed,** because Codex 26.1117 no longer supports it.

**Fixes.** SSH hosts added in Codex Desktop show their running tasks. A Codex that quits or crashes in the middle of a task no longer leaves the task showing as running.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

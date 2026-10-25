Codex Pacer 3.2.4 fixes finished Claude tasks that stayed marked as running after Codex Pacer restarted.

- Claude tasks that had already finished no longer stay marked as running after Codex Pacer restarts, such as right after an update. Pacer now reads its own hook records before matching a conversation's ending, as it already did for SSH hosts.
- A task that was actually cut off shortly before a restart no longer stays running indefinitely: once its last activity is 15 minutes old it shows as unconfirmed, and any new activity marks it running again.

### Install

- **Existing installation:** use **Check for Updates** to update in place. Your preferences are preserved.
- **Manual installation:** quit Codex Pacer, replace the copy in Applications with the new app, then open it again.
- Requires macOS 14 or later.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

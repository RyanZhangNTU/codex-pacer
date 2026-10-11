Codex Pacer 3.0 follows **Claude Code** as well as Codex. Tasks, output speed and quota for both services now share one island.

### Highlights

- **Claude Code support.** Claude tasks on your Mac and on SSH hosts appear next to Codex tasks, with their stages, replies and approvals that need you, endings, output speed and time to first output. Claude quota shows its 5-hour and 7-day windows.
- **Choose your services.** Codex and Claude are independent modules, turned on automatically when installed.
- **Sets itself up.** Pacer adds its own Claude Code hooks on your Mac and on SSH hosts that have Claude Code, and removes the local ones when you turn the module off. SSH hosts are picked up from Codex and Claude, including Claude Desktop's saved connections.
- **A clearer island.** One activity badge shows how many tasks are running, with an orbit while they work, solid amber when a task needs you and a mark for unread endings. Quota rings for both services carry a pace tick with Ahead, On pace or Fast.
- **Codex Remote Control.** Remote Control tasks join the list through the Codex app.
- **Liquid Glass** that follows the system's glass setting on macOS 26 and later, and a width that always fits its content.
- **New Settings.** A sidebar window that applies changes immediately, a drag-and-drop Collapsed Bar editor, a Connections page, a Help legend and a two-step welcome guide.
- **A new app icon.**

### Good to know

- Claude quota comes from Claude Code's status line or a claude.ai session in Pacer's own sign-in window. Pacer never reads other apps' Keychain items or browser cookies.
- The menu bar item and the in-island banner are gone. Everything shows on the island, and macOS notifications are optional.
- Preferences from 2.x carry over; retired options are cleared automatically.
- Requires macOS 14 or later, on Apple silicon or Intel.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

### Install

Versions with **Check for Updates** update in place. Otherwise, quit the old version and drag Codex Pacer from the DMG into Applications. If macOS blocks the unsigned app, open **System Settings → Privacy & Security**, choose **Open Anyway** under Security, and open it again.

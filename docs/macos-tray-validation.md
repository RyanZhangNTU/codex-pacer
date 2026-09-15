# macOS menu bar validation

## macOS 27 click handling

When an `NSStatusItem` has an attached menu, macOS 27 can consume left clicks before `tray-icon` receives them. Pacer uses those clicks to open its usage popup. The behavior is documented in [tray-icon issue #355](https://github.com/tauri-apps/tray-icon/issues/355) and [the proposed upstream fix](https://github.com/tauri-apps/tray-icon/pull/365).

On macOS, Pacer keeps the menu separate from the status item. Releasing the left mouse button toggles the usage popup. Releasing the right mouse button shows the context menu at the cursor, including when the main window is hidden. Menu presentation runs after the tray callback returns because AppKit's menu tracking loop can deliver more events. The menu stays alive until that loop ends, and Pacer then clears the tray highlight.

Windows and Linux keep their native tray menu binding.

## Automated checks

Checked on 2026-09-15 with macOS 27.0 (`26A428`) and Rust 1.94.0:

- `cargo test --manifest-path src-tauri/Cargo.toml --locked`: 421 passed, 2 ignored.
- `npm test`, `npm run lint`, and `npm run build`: passed.
- `git diff --check`: passed.

The added tests cover one popup toggle per left press/release, manual right-click menu handling, and ignored middle clicks. Existing tests cover popup size, monitor selection, and display scaling. These checks do not verify native event delivery.

## Desktop checks before merging

Native clicks remain unverified: Computer Use timed out while reading the installed Pacer window. Run these checks on the fixed build:

1. Close the main window and left-click the menu bar item. Confirm the usage popup opens and its controls respond.
2. Click the item again to close the popup, then reopen it. Click another app and confirm the popup closes.
3. Right-click the item. Confirm the context menu appears, opens the main window, and closes when dismissed. Repeat a left click afterward to check that popup access still works.
4. Test with the Dock icon hidden. Disable all menu bar content, enable it again, and repeat both click checks.
5. On an external display, check popup placement and the right-click menu with the main window on another display.
6. Disable the usage popup and confirm a left click opens the main window. Restore the setting, then confirm the context menu's Quit action exits Pacer.

Repeat the click checks on macOS 26 before claiming compatibility with that version.

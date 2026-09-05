# Windows tray popup validation

Validated on 2026-09-05 with a local v1.2.3 build using the isolated application identifier `com.codex.counter.traytest`. The installed application and its database were not replaced.

## Changes

- Windows monitor lookup uses the physical tray click position without dividing it by the display scale.
- Before a hidden popup is shown again, its size is reset to the height used to calculate its position.

## Results

- All 10 tray positioning tests passed, including scaled coordinates, negative-coordinate monitors, bottom taskbar placement, and upward resizing.
- The full Rust suite passed: 419 passed and 2 ignored.
- The frontend production build passed.
- Computer Use clicked the Windows tray icon and captured the popup after its content loaded. The complete popup appeared above the bottom taskbar.
- After the popup was hidden, Computer Use clicked the icon again. The returned screenshot origin and dimensions matched the first capture: origin `(2970, 1218)`, dimensions `423 x 575` in the capture tool's coordinate units.

The desktop check covers the current display configuration only. Other scale factors and monitor layouts were covered by automated tests, not by changing the user's Windows display settings.

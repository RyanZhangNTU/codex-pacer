For macOS 14 or later, with support for Apple Silicon and Intel.

- Improve TPS reporting with settled per-request usage and incremental local/SSH accounting. Recent measured throughput stays visible during sparse reports and after completion. The collapsed header shows global total TPS across active chats.
- Show observed first-output latency in each task, covering the first received model text or reasoning text.
- Display updates adapt automatically: five seconds collapsed and one second expanded. Opening the island flushes pending data; first output, tool waits, turn endings and input reminders remain immediate, with unchanged accounting precision.

Install from Settings → Check for Updates.

For a manual installation, quit the old app and drag Codex Pacer from the DMG into Applications. For the unsigned release, if macOS blocks the first launch, open System Settings → Privacy & Security, scroll to Security, choose Open Anyway, then reopen the installer or app.

For macOS 14 or later, with support for Apple Silicon and Intel.

- Reduce local collection overhead with a native event subscription that skips conversation bodies and limits retained history.
- Keep five-minute points for the seven-day quota curve and save normal changes in thirty-minute batches. Live task/token updates and quota-read cadence are unchanged; account/cycle changes, sleep and orderly quit still flush immediately.
- Improve local and SSH task discovery, preserve completion reminders through subscription release and conversation unload, and recognize dotted SSH host aliases without waiting for a log scan.
- Keep pending reply and approval reminders visible while work continues. A single running task shows its current stage; multiple tasks show a meaningful task count with the approved native status icons.
- Fix inflated token/s at the start of a turn and stale displayed estimates. Each turn establishes its own counter baseline; numbers expire after fifteen seconds without a new counter.
- Preserve existing preferences and improve reconnects, conversation-opening failures, failure-state labels and quota-window selection.

An abnormal exit may lose up to thirty minutes of local curve history. Remaining uncommon event-ordering, subscription, clock-skew and reset-correction cases are documented in [known issues](https://github.com/RyanZhangNTU/codex-pacer/blob/v2.2.0/docs/known-issues-2.2.0.md).

Install from Settings → Check for Updates.

For a manual installation, quit the old app and drag Codex Pacer from the DMG into Applications. For the unsigned release, if macOS blocks the first launch, open System Settings → Privacy & Security, scroll to Security, choose Open Anyway, then reopen the installer or app.

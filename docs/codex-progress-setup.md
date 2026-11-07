# Codex task progress

**Settings → Codex → Progress Ring** (**Show Codex Task Progress** on Windows) is on by default. Pacer registers its bundled reporting tool in the selected local Codex profile. Start a new local Codex session after Pacer shows that reporting is ready. The tool description tells Codex when to report, and the ring stays dashed until Codex sends its first estimate.

If setup fails, check the Codex executable and data folder in the same pane, then choose **Retry**. A same-name MCP entry that belongs to another tool takes precedence. Pacer reports the conflict in Settings.

Turning the ring off disables reporting and removes Pacer's registration. The Windows uninstaller also removes it from the profiles Pacer configured. On macOS, turn off the switch before dragging Pacer to the Trash. If Pacer is already gone, remove `pacer_progress` in Codex's MCP settings.

Pacer configures the local profile. Remote sources show task state when Pacer can observe it, and show a percentage when the source forwards a matching successful report.

The ring may move backward when Codex revises its estimate. It pauses for a question or approval and breathes while Codex waits for background work. A confirmed success fills the ring; a failure or cancellation keeps the last estimate.

A goal that stays paused or waits for another turn leaves the list 15 minutes after its last turn ends.

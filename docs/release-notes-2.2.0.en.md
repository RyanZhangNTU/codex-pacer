For macOS 14 or later. This 2.2.0 candidate is being tested locally; it has not been published to the update feed.

- Preserve queued SSH endings across disconnects and discover active tasks beyond an idle first page using bounded metadata requests. Late events from retired turns and old logs cannot overwrite newer task state or explicit runtime errors.
- Recognize newly observed SSH tasks without a fallback log when their host alias contains dots, including IP-address aliases.
- Keep completion reminders after the finished subscription is released, including a subsequent conversation unload or archive.
- Keep timestamp-less active turns and their completion visible, deliver one notification for a live turn that starts and ends within one UI batch, and treat collaboration-tool waits consistently on local and SSH tasks.
- Fix inflated new-turn token/s and frozen estimates: seed each turn independently, accumulate rapid counters, ignore delayed previous-turn usage, and expire numbers after 15 seconds without extra polling or disk I/O.
- Discover SSH activity from Desktop routing hints and remote runtime-index changes, including when no Desktop owner announces the new turn. Confirm task states through the runtime.
- Reduce local event-collection CPU and memory overhead with a native, bounded Desktop subscription that skips transcript bodies.
- Retain one weekly curve reading per five-minute interval and save normal updates in thirty-minute batches. Account/cycle changes, sleep and orderly quit still flush immediately. An abnormal exit may lose the last thirty minutes of local curve history. Live task/token updates and quota-read cadence are unchanged.
- Keep pending reply/approval reminders visible even when a task continues running. Observe Desktop message questions as well as server requests for local and enabled SSH sources. Opening a chat keeps its question pending. Desktop-only dismissals may remain indicated until a reply, question removal or turn ending is observed.
- Use approved native status icons and meaningful labels in both Notch and Floating modes. Pending requests appear in the corresponding task row; quota warnings remain on the right. Preserve explicit failure indicators separately from interruption.
- Show the current stage for a single running task and a task count for multiple tasks.
- Forward Desktop discovery hints to the SSH runtime subscription; confirm remote activity through runtime metadata and events, and retain explicit completion reminders.
- Preserve a confirmed SSH turn when its first tool event supplies the turn ID, preventing an older completed record from hiding activity and completion reminders.
- Keep the next turn in an open local conversation visible immediately, clear asynchronous reminders on steering replies, and preserve event order through connection shutdown.
- Improve reconnect/completion handling, failed conversation-opening reminders, bounded fallback transport, CLI/application discovery and saved quota-window choices. Existing notification preferences remain in place.

This local test uses the existing ad hoc signature. It is not a notarized public release.

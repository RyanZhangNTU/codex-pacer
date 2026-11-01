Codex Pacer 4.2.0 brings Claude's cloud Projects into the task list.

- **Threads as tasks:** each thread that is working, waiting for you or just ended gets its own row, with a cloud icon and the project's name. **Working** shows a count when more sessions share a thread.
- **Coordination:** the project's coordinator has its own row while it answers. Handing work to threads or reporting on one that just ended doesn't count as an ending, so each run reminds you once.
- **Reminders that fit:** **Decision needed**, **Reply needed** and **Approval needed** while a thread waits, then **Resolved**, **Turn finished** or **Task failed**. Short runs and runs that end while the Mac sleeps are still noticed, a thread stays **Working** through a long tool call, and a resolved thread you read in Claude clears its card here.
- **Open in place:** click a row to open that thread or Project in Claude Desktop, or on claude.ai without it.
- **Speed and timing:** Pacer checks Projects every 20 seconds while something runs and up to every 2 minutes otherwise, and a new run in a recently active Project appears within about 10 seconds. While a thread writes a reply, its row shows an estimated speed, which does not update during thinking or tool calls. A thread's ending card shows that turn's real speed and time to first output; the coordinator has neither.

Cloud Projects use the claude.ai session in Pacer's own window, the one Claude quota already uses. Turn it off in **Settings → Claude**.

### Install

- **Existing installation:** use **Check for Updates** to update in place. Your preferences are preserved, and a short What's New note appears once.
- **Manual installation:** quit Codex Pacer, replace the copy in Applications with the new app, then open it again.
- Requires macOS 14 or later. Cloud Projects need a claude.ai sign-in in Pacer.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).

---
name: codex
description: Hand work to OpenAI Codex through Codex Pacer and bring the result back into this Claude Code session (a task, an investigation, a second opinion, a code review of a diff, branch or commit, or a follow-up within the same turn), with explicit control of model, reasoning effort (low to ultra), fast mode and write access. Pacer shows each Codex run under this Claude task and deletes Codex's sessions, worktrees and run files when Claude's turn ends. Use it whenever the user wants Codex or GPT to do or check something, in any wording, e.g. "让 Codex 查一下", "问问 Codex", "交给 Codex 去修", "Codex 审一下这个改动", "用 xhigh 快速模式让 Codex 跑", "ask Codex", "get a second opinion from GPT", "run Codex in parallel with you". Do not use it when Codex is only the subject of the work, such as code that reads Codex data or quotas, the Codex app's settings, or Codex Pacer features.
argument-hint: "[review|resume <thread>|models|runs|stop <thread>] [-l label] [-m model] [-e effort] [--fast|--no-fast] [--write] [task]"
allowed-tools: Bash({{RUN}}:*)
---

# Codex

Run Codex as a disposable worker: one `codex exec` process per call, gone when its turn ends, and everything it leaves behind is deleted when your turn ends. You stay the orchestrator: you brief Codex, check what it did, keep what matters, and report to the user. Codex Pacer installed this skill and its runner; the user sees every run under this Claude task in Pacer, with its label, progress, speed and model, and can stop it there.

The runner (`--help` lists every option). Call it with the Bash tool, exactly as written:

```bash
{{RUN}} [task|resume <thread>] [options] -l "<label>" -f <brief-file>
{{RUN}} review --uncommitted|--base <branch>|--commit <sha> [options] -l "<label>" [-f <focus-file>]
{{RUN}} models|runs|cleanup
{{RUN}} stop|apply|discard <thread>
```

## Lifecycle: nothing survives your turn

Each run is filed under this Claude session. Your turn has ended when you stop with no background work left; stopping while a background job still runs is only a pause. When the turn ends, Pacer deletes every finished run of the session:

- the Codex thread and any sub-threads it spawned (a review always spawns one), so they vanish from Codex's history, files and database
- the Codex worktree, if the run used `--worktree`
- the run folder (`last.md`, `events.jsonl`, `stderr.log`, `meta.json`)

Runs still in progress are left alone and cleaned at the end of a later turn, after they finish. Runs whose Claude session no longer exists are stopped and swept by Pacer. If another Codex process holds a thread (the Codex desktop app can take over a thread whose run was killed), its deletion waits in a queue that Pacer retries until it succeeds. Executor runs have Codex's memories turned off, so they neither read nor feed the user's Codex memories; you supply the context in the brief.

So before you finish a turn, take what you need into your own hands: the findings go into your reply, worktree changes get applied (see below), anything worth keeping goes into the project or your scratchpad. A Codex thread can be resumed only within the turn that started it. For a follow-up in a later turn, start a fresh run and put the earlier result in the brief; you are the one who remembers. `cleanup` deletes this session's finished runs on demand, and `runs` lists what this session still holds.

## 1. Choose the mode and flags from the user's words

| The user wants | Pass |
|---|---|
| a task, question or investigation | nothing extra (task is the default mode) |
| a review of uncommitted changes / a branch / a commit | `review --uncommitted` · `review --base <branch>` · `review --commit <sha>` |
| a follow-up to a Codex run from this turn | `resume <thread-id>` (or `resume last` for this session's latest thread) |
| a specific model ("6.2 sol", "astra") | `-m gpt-6.2-sol`; run `models` first if the exact slug is unclear |
| a reasoning effort (思考等级 low … ultra) | `-e <level>` |
| fast mode on or off (快速模式) | `--fast` / `--no-fast` |
| Codex to change files (修、改、实现) | `--write` |
| Codex's changes kept apart from the working tree | `--worktree` (implies `--write`) |

Always pass `-l` with a short label in the user's language, two to eight words, saying what this run does ("审查登录改动", "Find the token refresh race"). Pacer shows it on the run's row; never put secrets or private details in it.

Leave model, effort, fast mode and write access unset unless the user names them: the user sets the defaults in Pacer (Settings → Collaboration) or in Codex's own configuration, and expects those to apply. The runner prints what the turn actually used, so you can report it either way. If the user asks you to choose: low or medium for lookups, high or xhigh for hard debugging, max or ultra only on request (slow and costly). Fast mode runs 1.5–2× faster depending on the model and uses more quota (`models` shows each model's figure).

Add `--write` only when the user asked Codex to change something; it uses the workspace-write sandbox, which confines writes to the working directory. Don't use danger-full-access or approval bypass unless the user explicitly asks for it: the sandbox is what makes an unattended Codex safe.

## 2. Write the brief to a file

Codex sees nothing of this conversation. Write a self-contained brief to a temp file (your scratchpad if you have one) and pass it with `-f`. A file also avoids shell quoting problems with quotes, `$`, backticks, newlines and Chinese text. A good brief covers:

- the goal in a sentence or two, and what "done" looks like
- the repo or folder, the files and areas that matter, what is already known or ruled out
- constraints: what not to touch; no commits, pushes or releases; stay in scope
- what to send back: findings with `file:line`, what it changed, what it could not verify, kept short

For a review, the brief is optional: add one only for a specific focus ("concurrency in the reader", "Windows path handling").

## 3. Run it

- Short, bounded work (a lookup, a small review): run in the foreground with `--timeout 9` and a Bash timeout of 600000 ms, so the runner stops Codex cleanly before the Bash tool's 10-minute ceiling cuts it off.
- Longer work, or several jobs at once: use `run_in_background: true`, keep working, and wait for the completion notification rather than polling or sleeping.
- `-C <dir>` sets Codex's working root (default: the current directory). `--timeout <minutes>` overrides Pacer's limit for this run.

Parallel read-only jobs are fine. Pacer refuses a second `--write` run in a repository where one is already changing files, and refuses runs beyond the number the user allows at once; the runner says which, and you either wait for the running job or use `--worktree`. Never edit the files a `--write` job is working on while it runs.

## 4. Check, keep what matters, report

The runner prints a header and then Codex's final message:

```
codex ok · 41.2s · model gpt-6.2-astra · effort high · fast config (default) · sandbox workspace-write
thread 01a1… · tokens in 52311 (cached 40960) out 2210 · commands 7
changed files (3): M src/reader.ts, ?? src/reader.test.ts, reverted src/old.ts
output: …/codex/runs/<session>/20261121-101500-task-1234 (deleted with the thread when this Claude turn ends)
follow up this turn: {{RUN}} resume 01a1… -f <brief>
----- Codex final message -----
…
```

- For `--write` runs, "changed files" comes from comparing `git status` before and after the run, so it includes edits Codex made through shell commands; `reverted` means a file that was dirty before now matches HEAD. Files that were already dirty and that Codex didn't touch are left out.
- Review runs report no token usage. Their final message lists findings as `[P1]`…`[P3]` (most severe first) with absolute `path:line` ranges.
- With `--worktree` there is also a `worktree:` line. Those changes live only in that checkout. Run `apply <thread>` to copy them into the original repo's working tree (nothing is staged or committed), or `discard <thread>` if they aren't wanted. If your turn ends with neither, Pacer stops you once to decide; after that the worktree is deleted regardless.
- `codex stopped by the user in Pacer` means the user stopped the run from Pacer's task list: don't start it again unless they ask.

Treat Codex's message as a report, not proof:

- After `--write` or `apply`, read the diff of the changed files and run the relevant checks before telling the user the work is done.
- Open the cited lines for the findings that matter before repeating them as fact, and say plainly where you disagree.

Reply in your own words. Cover what Codex found or changed, what you verified (and where you disagree), and what is left. Also give the model, effort and fast mode actually used. Quote Codex verbatim only when the user asks for its raw output.

## 5. When a run fails

The runner prints the error and the stderr tail, and exits non-zero (124 means it hit `--timeout`, 130 that it was stopped, 3 that Codex or this feature is unavailable, 4 that Pacer's limits refused it). Usual causes:

- not logged in: the user runs `codex login`
- unknown model slug, or an effort that model doesn't support: check `models`
- `--write` outside a git repository: Codex refuses; pick the repo with `-C`
- `resume` of a thread from an earlier turn: it was deleted; start a fresh run with the earlier result in the brief
- Codex not found, or the feature turned off: the user fixes it in Pacer (Settings → Collaboration)

## 6. When to start a run

{{INITIATIVE}}

`{{RUN}} doctor` checks everything a run needs (Codex, its sign-in, the ledger, this skill) without calling a model.

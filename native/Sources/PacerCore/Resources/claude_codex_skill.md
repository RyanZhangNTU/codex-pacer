---
name: codex
description: Hand work to OpenAI Codex through Codex Pacer and get its result back in this Claude Code session (a task, an investigation, a question, a code review of a diff, branch or commit, or a follow-up to an earlier Codex run). Use it only when the user explicitly asks to hand something to Codex or to ask Codex, in any wording, e.g. "让 Codex 查一下", "问问 Codex", "交给 Codex 去修", "Codex 审一下这个改动", "ask Codex", "have Codex review this". Don't start it on your own, and don't use it when Codex is only the subject of the work (code that reads Codex data, the Codex app's settings, Codex Pacer features).
argument-hint: "[review|resume <thread>|models|runs|stop <thread>] [-l label] [-m model] [-e effort] [--fast|--no-fast] [--read-only|--write] [--worktree] [task]"
allowed-tools: Bash({{RUN}}:*)
{{INVOCATION}}---

# Codex

Codex Pacer runs Codex for you: one `codex exec` process per call, with the settings the user chose in Pacer (Settings → Collaboration). The user sees each run under this Claude task in Pacer, with its progress, speed and model, and can stop it there.

Call the runner with the Bash tool, exactly as written (`--help` lists every option):

```bash
{{RUN}} [task|resume <thread>] [options] -l "<label>" -f <brief-file>
{{RUN}} review --uncommitted|--base <branch>|--commit <sha> [options] -l "<label>" [-f <focus-file>]
{{RUN}} models|runs|cleanup|doctor
{{RUN}} stop|apply|discard <thread>
```

## Options

| The user wants | Pass |
|---|---|
| a task, question or investigation | nothing extra (task is the default mode) |
| a review of uncommitted changes / a branch / a commit | `review --uncommitted` · `review --base <branch>` · `review --commit <sha>` |
| a follow-up to an earlier Codex run | `resume <thread-id>` (or `resume last` for this session's latest thread) |
| a specific model | `-m <slug>`; run `models` first if the exact slug is unclear |
| a reasoning effort (low … ultra) | `-e <level>` |
| fast mode on or off | `--fast` / `--no-fast` |
| Codex not to change anything | `--read-only` |
| Codex's changes kept apart from the working tree | `--worktree` |

Always pass `-l` with a short label in the user's language, two to eight words, saying what the run does ("审查登录改动", "Find the token refresh race"). Pacer shows it on the run's row; keep secrets and private details out of it.

Leave model, effort, fast mode, file access and work location unset unless the user names them for this run: Pacer applies the user's settings. A run never gets more file access than those settings allow, and reviews are always read-only. Pacer may add the user's standing instructions to the end of your brief.

## The brief

Codex sees nothing of this conversation. Write a self-contained brief to a temp file and pass it with `-f`; a file also avoids shell quoting problems. Cover the goal and what "done" looks like, the repo or folder and the files that matter, what is already known, any constraints, and what to send back. For a review, a brief is optional: add one only for a specific focus.

## Running

- Short work (a lookup, a small review): run in the foreground with `--timeout 9` and a Bash timeout of 600000 ms, so the runner stops Codex cleanly before the Bash tool's 10-minute limit.
- Longer work, or several jobs at once: use `run_in_background: true` and wait for the completion notification rather than polling.
- `-C <dir>` sets Codex's working root (default: the current directory).
- Pacer limits how many runs go at once, allows one writing run per repository outside a worktree, and can hold runs back when Codex's quota is low. When it refuses, the runner says why and exits with 4.
- Don't edit the files a writing run is working on while it runs.

## Output

The runner prints a header and then Codex's final message:

```
codex ok · 41.2s · model gpt-6.2-astra · effort high · fast config (default) · sandbox workspace-write + network
thread 01a1… · tokens in 52311 (cached 40960) out 2210 · commands 7
changed files (3): M src/reader.ts, ?? src/reader.test.ts, reverted src/old.ts
output: …/codex/runs/<session>/20261121-101500-task-1234 (deleted with the thread when this Claude turn ends)
follow up: {{RUN}} resume 01a1… -f <brief>
----- Codex final message -----
…
```

- "changed files" compares `git status` before and after the run; `reverted` means a file that was dirty before now matches HEAD.
- A `worktree:` line means the changes live only in that checkout. `apply <thread>` copies them into the original working tree (nothing is staged or committed); `discard <thread>` drops them. Unapplied changes are kept until this Claude session ends and then saved as a patch.
- `codex stopped by the user in Pacer` means the user stopped the run.
- The `output:` line says how long the thread stays, which follows the user's setting in Pacer; `resume` works while it exists.

## When a run fails

The runner prints the error and the stderr tail and exits non-zero (124: hit `--timeout`; 130: stopped; 3: Codex or this feature unavailable; 4: refused by Pacer's limits). Usual causes:

- not logged in: the user runs `codex login`
- unknown model slug, or an effort that model doesn't support: check `models`
- writing outside a git repository: Codex refuses; pick the repo with `-C`
- `resume` of a thread that was already deleted: start a fresh run with the earlier result in the brief
- Codex not found, the feature turned off, or file access too low: the user changes it in Pacer (Settings → Collaboration)

`{{RUN}} doctor` checks everything a run needs (Codex, its sign-in, the ledger, this skill) without calling a model.

---
name: codex
description: Hands a task, question, investigation or code review to OpenAI Codex through Codex Pacer and brings Codex's answer back here. Use only when the user explicitly asks to give work to Codex or to ask Codex; never start it on your own, and not when Codex is merely the subject of the work.
argument-hint: "[review|resume <thread>] [-l label] [-m model] [-e effort] [--fast|--no-fast] [--read-only|--write] [--worktree]"
allowed-tools: Bash({{RUN}}:*)
{{INVOCATION}}---

# Codex

Each call is one run: a `codex exec` process with the user's Pacer settings, shown under this Claude task where the user can stop it. A thread is Codex's conversation; `resume` continues it.

## Start a run

Use the Bash tool with `run_in_background: true`, pass the brief on standard input, and wait for the completion notification before reading the output:

```bash
{{RUN}} [resume <thread>|resume last] [options] -l "<label>" -f - <<'EOF'
<brief>
EOF
{{RUN}} review --uncommitted|--base <branch>|--commit <sha> -l "<label>"
```

- `-l`: two to eight words in the user's language saying what the run does; shown in Pacer, so no secrets.
- The brief must stand alone, since Codex sees nothing of this conversation: goal and done criteria, relevant paths and known facts, constraints, and what to send back. A review needs none unless there is a specific focus.
- Add options only when the user asks: `-m <model>` (list with `{{RUN}} models`), `-e <effort>`, `--fast`/`--no-fast`, `--read-only`, `--worktree` (changes kept apart in a git worktree), `-C <dir>` (default: current folder, which need not be a git repository). Pacer's settings supply the rest and cap file access.
- Runs may go in parallel. Don't edit files a writing run is changing.

## Output

A header (status, time, model, effort, sandbox; thread, tokens; `changed files`; `output:` with how long the thread stays), then Codex's final message.

- `worktree:` the changes exist only there: `{{RUN}} apply <thread>` copies them into the working tree, `{{RUN}} discard <thread>` drops them; unapplied changes are saved as a patch when the session ends.
- `{{RUN}} stop <thread>` stops a run; "stopped by the user in Pacer" means the user did.

## Failures

The runner explains the error and exits non-zero: 124 time limit, 130 stopped, 3 Codex or this feature unavailable, 4 refused by the user's Pacer limits (runs at once, one writer per folder, quota floor). Not signed in: the user runs `codex login`. Unknown model or effort: check `{{RUN}} models`. Settings belong to the user (Pacer's Collaboration settings). `{{RUN}} doctor` checks the setup without calling a model.

# Fork token accounting design

## Problem

Codex fork files can begin with a copy of the direct parent's `token_count` history. The copied records keep the parent's numeric `total_token_usage` and `last_token_usage` values, but Codex rewrites their timestamps to the fork creation time. Codex Pacer currently treats every file as an independent counter. It starts the child at zero and imports the copied cumulative history again.

The local audit found no duplicate SQLite rows and no duplicate import-state records. The error is in the JSONL import semantics. Across the current data set, the copied history accounts for about 43 percent of the displayed all-time total. In the active root conversation, it accounts for about 86 percent.

A second case occurs when the first child snapshot already contains an inherited cumulative baseline. For example, a child may report `total_token_usage.total_tokens = 153235349` while `last_token_usage.total_tokens = 289826`. Counting the cumulative value assigns the parent's history to the child. The child's first real increment is the `last_token_usage` value.

## Selected approach

The importer will keep the cumulative counter as its monotonic high-water mark. It will also parse `last_token_usage` for replay identification and first-snapshot recovery.

For a session with an explicit `forked_from_id`, the importer will load the direct parent's numeric token sequence. It will compare each child snapshot by the exact pair `(total_token_usage, last_token_usage)`. A copied prefix is removed only when at least two consecutive child pairs match one contiguous slice of the direct parent's sequence. Timestamps and model labels do not participate because Codex can rewrite them during a fork.

The matching algorithm finds the longest child prefix contained in the parent sequence in linear time. Missing `last_token_usage` breaks a candidate match. This keeps older JSONL formats on the existing cumulative-counter path.

After a match, the last copied cumulative value becomes the child's baseline. The first new child snapshot is calculated against that baseline. If no reliable parent prefix is available, the first explicit-fork snapshot uses `last_token_usage` when present. Later snapshots continue to use cumulative high-water differences, which preserves the existing protection against repeated and non-monotonic totals.

Sessions linked only through `source.subagent.thread_spawn.parent_thread_id` do not use cross-session replay removal. The audit did not find copied token prefixes in those files. Their current accounting remains unchanged.

## Data flow

`UsageSnapshot` will retain both cumulative and last-turn token usage. `ParsedSession` will separately retain the explicit fork parent ID so the importer can distinguish a true fork from a normal spawned subagent.

At scan time, the importer builds a session-to-source-path map from the files in the current scan and existing session records. When a changed explicit fork is parsed, the importer reads the direct parent's numeric token records on demand and caches the result for sibling forks. It does not load message text into memory.

The persisted `usage_events` table remains unchanged. It continues to store deltas, not source cumulative counters. API-equivalent value is calculated from the corrected deltas in the same transaction that replaces the session's usage rows.

## Historical repair

The existing `token_usage_monotonic_v2` repair marker has already completed on installed databases. The new algorithm therefore uses `token_usage_fork_replay_v3`. Its absence forces a full scan and rebuilds unchanged usage files under the selected Codex home.

If a source file is unreadable, the existing pending-file mechanism records it and retries it on a later scan. A direct parent that is no longer available cannot support exact prefix matching. In that case the child still receives the first-snapshot baseline correction, and the importer logs that full replay matching was unavailable.

Historical sessions from a different Codex home can only be rebuilt while their source files are available. Selecting that source again causes an authoritative full scan. Missing source files remain visible as missing and are not silently treated as repaired data.

## Performance

Normal root sessions do no extra file work. An explicit fork loads only its direct parent's numeric token records. Multiple children of one parent share the cached sequence for the duration of the scan. Prefix matching uses a KMP-style prefix table, so its cost is proportional to the parent and child sequence lengths.

## Verification

Automated tests cover:

- a child that copies three parent snapshots and then adds new usage;
- a fork whose first snapshot contains a large inherited baseline;
- a normal spawned subagent that must not use fork replay removal;
- a nested fork that compares against its direct parent;
- a missing `last_token_usage` field that keeps legacy cumulative behavior;
- the new repair marker rebuilding unchanged, previously overcounted rows;
- repeated and non-monotonic snapshots retaining their current high-water behavior.

Integration verification runs the importer against a copied `~/.codex` tree and a temporary SQLite database. The test compares corrected totals with the independent read-only audit, checks database integrity, and confirms that the installed database can be repaired without deleting settings.

The release check then runs Rust tests, frontend tests, lint, the production build, the macOS release script, code-signature verification, DMG verification, installation into `/Applications`, application launch, and a post-launch database query.

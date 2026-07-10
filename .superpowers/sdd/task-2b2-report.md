# Task 2B2 production integration report

Date: 2026-07-10

Base commit: `eee8405ae960ceecb9134579294f770d92a13352`

## Result

The importer now removes direct-parent token replay from explicit fork sessions. It resolves a parent source without walking the archive, reads only replay metadata and token counters, computes the reviewed cutoff, and applies that cutoff inside the existing session transaction. When a parent cannot be used, the first explicit-fork snapshot falls back to `last_token_usage`; roots and thread-spawn-only sessions keep their previous cumulative accounting.

## RED to GREEN evidence

Each named test was run separately before and after the production change.

| Test | RED value | GREEN value |
| --- | ---: | ---: |
| `fork_replay_counts_only_child_usage` | child `310`, expected `50` | child `50`; parent `260`; family `310` |
| `incremental_fork_scan_loads_unchanged_archived_parent` | child `310`, expected `50` | child `50`; unchanged archived parent `260`; family `310` |
| `nested_fork_replay_uses_direct_parent` | child `310`, expected `50` | root `260`; child `50`; grandchild `20`; family `330` |
| `parent_path_validation_rejects_child_file_with_replayed_parent_meta` | child `150`, expected `90` | child `90`; parent remains `25` |
| `fork_first_snapshot_uses_last_usage_as_baseline` | child `1000`, expected `40` | child `40` |
| `thread_spawn_without_fork_keeps_full_usage` | `1000` before the change | `1000` after the change |

The thread-spawn test was a guard rather than a RED case. It passed on both runs.

## Implementation

Changed production file: `src-tauri/src/importer.rs`.

- Added `inherited_token_snapshot_cutoff` to `ParsedSession`, initialized to zero by the parser.
- Built the session source map before changed files are processed. Priority is `sessions`, then `import_state`, then UUID-bearing files in the current scan.
- Added an on-demand direct-parent cache keyed by requested parent ID. The cache stores both loaded snapshots and unavailable results.
- Validated UUID-bearing filenames against the requested parent ID. Paths without a filename UUID must have a matching first usable `session_meta.payload.id`.
- Added a parent replay reader that prefilters unrelated JSONL lines before JSON parsing. It retains only timestamp, cumulative token usage, and optional last token usage. It does not retain model names, rate limits, titles, or message text, and warnings contain only IDs and source paths.
- Connected direct-parent snapshots to `replayed_child_snapshot_cutoff()` for changed explicit forks with a valid fork timestamp.
- Started persistence from the final skipped cumulative snapshot and iterated from the cutoff. Explicit forks with cutoff zero use `last_token_usage` for the first counted snapshot when available. Later snapshots retain the existing cumulative high-water behavior.
- Kept usage deletion, value calculation, usage insertion, import-state updates, and commit inside the existing session transaction.

No schema, repair key, pricing rule, topology rule, public command response, UI, or test expectation changed.

## Commands and results

Named tests, each run with its own exact filter:

```bash
tests=(
  fork_replay_counts_only_child_usage
  incremental_fork_scan_loads_unchanged_archived_parent
  nested_fork_replay_uses_direct_parent
  parent_path_validation_rejects_child_file_with_replayed_parent_meta
  fork_first_snapshot_uses_last_usage_as_baseline
  thread_spawn_without_fork_keeps_full_usage
)
for test_name in $tests; do
  cargo test --manifest-path src-tauri/Cargo.toml "importer::tests::$test_name" --locked -- --exact --nocapture
done
```

All six named filters passed after implementation.

Full importer suite:

```bash
cargo test --manifest-path src-tauri/Cargo.toml importer::tests --locked
```

Result: `64 passed; 0 failed; 83 filtered out` in the library target. The binary target ran zero tests and passed.

Compiler check:

```bash
cargo check --manifest-path src-tauri/Cargo.toml --locked
```

Result: exit code 0 with no warnings.

Whitespace check:

```bash
git diff --check
```

Result: exit code 0.

## Self-review

- Source resolution follows the required priority and uses persisted paths for parents omitted from an incremental scan.
- Parent lookup does not add an archive-directory walk.
- The reader rejects a stale child UUID path even when that child replays the requested parent's metadata.
- Nested forks read their direct parent file, not the root file or already persisted token totals.
- The cache key is the requested direct-parent ID, and unavailable reads are cached.
- The replay reader parses only prefiltered `session_meta` and `event_msg/token_count` records. It never logs file contents or parser errors.
- A nonzero cutoff seeds `previous_usage` from the last skipped raw snapshot. At-or-below high-water snapshots remain non-billable, and later growth still uses `diff_usage()`.
- The cutoff and fallback only change explicit forks. Thread-spawn-only children and roots still bill the full first cumulative snapshot.
- The production diff is limited to `src-tauri/src/importer.rs`; this report is the only additional file.

## Concerns

No known blocking concern remains. The conservative path is intentional: if a parent source is missing, unreadable, invalid, or points at another UUID, the importer uses cutoff zero and the explicit-fork first-snapshot fallback instead of guessing replay length.

The required verification scope covers the importer suite and a locked compiler check, not the entire workspace test suite. A separate default `cargo fmt --check` was informational only and reported existing repository-wide formatting differences in untouched files; it did not modify the working tree.

# Fork token accounting implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove parent token history copied into Codex fork files, repair existing usage rows, and install a verified macOS build.

**Architecture:** Keep cumulative usage as the monotonic high-water mark. Parse `last_token_usage`, identify exact direct-parent replay prefixes for explicit forks, and use the final copied cumulative value as the child baseline. A new durable repair key forces unchanged session files through the corrected importer.

**Tech stack:** Rust 2021, rusqlite, serde_json, Tauri 2, React 19, TypeScript 5.9, Node 22.18 or newer, macOS release shell scripts.

## Global constraints

- Apply cross-session replay removal only to `session_meta.payload.forked_from_id`.
- Require at least two consecutive exact `(total_token_usage, last_token_usage)` pairs.
- Do not compare child and parent timestamps; exclude parent records created after the explicit fork timestamp.
- Keep the `usage_events` schema and public response types unchanged.
- Preserve cumulative high-water handling for repeated and non-monotonic totals.
- Fall back to legacy cumulative accounting when `last_token_usage` is absent.
- Do not read or log user and model message bodies during replay matching.
- Every production behavior change begins with a test that fails for the expected reason.

---

### Task 1: Reproduce fork replay and inherited baselines

**Files:**

- Modify: `src-tauri/src/importer.rs`

**Interfaces:**

- Consumes: `perform_scan()`, `session_usage_totals()`, and JSONL test fixtures.
- Produces: regression tests for copied parent history, inherited first snapshots, and non-fork subagents.

- [ ] **Step 1: Add a fixture that writes cumulative and last usage**

Add a test helper that writes both source counters without depending on production parsing helpers:

```rust
#[derive(Clone, Copy)]
struct TokenFixture {
  timestamp: &'static str,
  total: (i64, i64, i64, i64),
  last: (i64, i64, i64, i64),
}

fn token_count_line(fixture: TokenFixture) -> String {
  let (input, cached, output, total) = fixture.total;
  let (last_input, last_cached, last_output, last_total) = fixture.last;
  format!(
    concat!(
      "{{\"timestamp\":\"{}\",\"type\":\"event_msg\",\"payload\":{{",
      "\"type\":\"token_count\",\"info\":{{",
      "\"total_token_usage\":{{\"input_tokens\":{},\"cached_input_tokens\":{},",
      "\"output_tokens\":{},\"reasoning_output_tokens\":0,\"total_tokens\":{}}},",
      "\"last_token_usage\":{{\"input_tokens\":{},\"cached_input_tokens\":{},",
      "\"output_tokens\":{},\"reasoning_output_tokens\":0,\"total_tokens\":{}}}",
      "}}}}}}\n"
    ),
    fixture.timestamp, input, cached, output, total,
    last_input, last_cached, last_output, last_total,
  )
}
```

- [ ] **Step 2: Add the copied-prefix regression test**

Create a parent with cumulative totals `100`, `180`, and `260`. Create an explicit child fork whose first three numeric pairs are identical but whose timestamps use the child creation time. Append one new child snapshot with total `310` and last usage `50`. Assert parent total `260`, child total `50`, and root-family total `310`.

- [ ] **Step 3: Add first-snapshot and non-fork tests**

For an explicit fork with cumulative total `1000` and last total `40`, assert child total `40`. For a session that has only `thread_spawn.parent_thread_id`, use the same counters and assert total `1000`, proving that normal child sessions keep their existing semantics.

- [ ] **Step 4: Run the three focused tests and verify RED**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml importer::tests::fork_replay_counts_only_child_usage -- --exact
cargo test --manifest-path src-tauri/Cargo.toml importer::tests::fork_first_snapshot_uses_last_usage_as_baseline -- --exact
cargo test --manifest-path src-tauri/Cargo.toml importer::tests::thread_spawn_without_fork_keeps_full_usage -- --exact
```

Expected: the fork tests report the full inherited cumulative totals. The thread-spawn test passes and remains a guard during implementation.

### Task 2: Parse source counters and remove exact replay prefixes

**Files:**

- Modify: `src-tauri/src/models.rs`
- Modify: `src-tauri/src/importer.rs`

**Interfaces:**

- Consumes: `total_token_usage`, optional `last_token_usage`, the direct parent's source path, and `persist_session()`.
- Produces: `UsageSnapshot.last_usage`, an explicit fork parent ID, linear replay matching, and corrected deltas.

- [ ] **Step 1: Retain last-turn usage and explicit fork identity**

Extend the internal snapshot data and parser:

```rust
pub struct UsageSnapshot {
  pub timestamp: String,
  pub model_id: String,
  pub usage: TokenUsage,
  pub last_usage: Option<TokenUsage>,
  pub plan_type: Option<String>,
  pub limit_id: Option<String>,
  pub limit_name: Option<String>,
  pub explicit_fast_mode: Option<bool>,
}
```

Add `forked_from_session_id: Option<String>` to `SessionMetaCandidate` and `ParsedSession`. Populate it only from `payload.forked_from_id`; keep the existing broader `parent_session_id` behavior.

- [ ] **Step 2: Add unit tests for replay matching**

Test a complete match, a match starting inside the parent sequence, a one-record match that returns zero, and a sequence interrupted by a missing last-usage value. Add a same-total record whose last usage changes and assert that cumulative canonicalization removes it. Add a parent record after the fork whose numbers equal the child's first new usage and assert that the match stops before it.

```rust
assert_eq!(longest_inherited_prefix(&child, &parent), 3);
assert_eq!(longest_inherited_prefix(&one_record_child, &parent), 0);
assert_eq!(longest_inherited_prefix(&legacy_child, &parent), 0);
```

- [ ] **Step 3: Run matching tests and verify RED**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml importer::tests::replay_prefix_ -- --nocapture
```

Expected: compilation fails because the replay-key and prefix functions do not exist.

- [ ] **Step 4: Implement linear prefix matching**

Define an equality-only replay key and KMP prefix scan:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
struct UsageReplayKey {
  total_usage: TokenUsage,
  last_usage: TokenUsage,
}

fn usage_replay_key(snapshot: &UsageSnapshot) -> Option<UsageReplayKey> {
  Some(UsageReplayKey {
    total_usage: snapshot.usage.clone(),
    last_usage: snapshot.last_usage.clone()?,
  })
}
```

Reduce parent and child snapshots to strictly increasing cumulative high-water records. Keep each canonical child's original snapshot index so the matched prefix can map back to the raw sequence. Build the child pattern only through its first missing key. Exclude parent records later than the explicit fork timestamp, scan the remaining parent segments with a KMP prefix table, and return zero for matches shorter than two records.

- [ ] **Step 5: Resolve and cache direct-parent sequences**

Build a session source-path map from current scan files and `sessions.source_path`. For each changed explicit fork, read only timestamps and `event_msg/token_count` metadata from the direct parent. Cache the raw replay records by parent session ID for the rest of the scan, then apply each child's fork-time cutoff before canonicalization and matching.

- [ ] **Step 6: Apply the corrected baseline in persistence**

Store the inherited prefix length on `ParsedSession`. Start `previous_usage` from the last skipped snapshot. If no prefix was found for an explicit fork, use `last_usage` for its first delta when present. Continue using `diff_usage()` for later snapshots.

```rust
let mut previous_usage = parsed
  .inherited_token_snapshot_count
  .checked_sub(1)
  .and_then(|index| parsed.snapshots.get(index))
  .map(|snapshot| snapshot.usage.clone());

for snapshot in parsed.snapshots.iter().skip(parsed.inherited_token_snapshot_count) {
  let delta = match previous_usage.as_ref() {
    Some(previous) => diff_usage(previous, &snapshot.usage),
    None if parsed.forked_from_session_id.is_some() => {
      snapshot.last_usage.clone().unwrap_or_else(|| snapshot.usage.clone())
    }
    None => snapshot.usage.clone(),
  };
  previous_usage = Some(snapshot.usage.clone());
  // Persist non-zero monotonic deltas through the existing path.
}
```

- [ ] **Step 7: Verify GREEN and preserve monotonic tests**

Run all `importer::tests` and require the new fork tests plus existing replay, archive, source-switch, and pending-repair tests to pass.

### Task 3: Force a durable historical rebuild

**Files:**

- Modify: `src-tauri/src/importer.rs`

**Interfaces:**

- Consumes: `data_repairs`, `data_repair_pending_files`, and unchanged import-state metadata.
- Produces: the `token_usage_fork_replay_v3` repair marker and a retryable one-time sweep.

- [ ] **Step 1: Add a failing v2-to-v3 repair test**

Create an unchanged fork file and preseed overcounted `usage_events`, matching `import_state`, `rate_limit_sample_backfill_v1`, and `token_usage_monotonic_v2`. Run `perform_incremental_scan()` and assert that the corrected rows replace the stale rows and `token_usage_fork_replay_v3` is recorded.

- [ ] **Step 2: Run the repair test and verify RED**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml importer::tests::v3_repair_rebuilds_unchanged_fork_usage -- --exact
```

Expected: no file is reimported because the installed v2 marker is already complete.

- [ ] **Step 3: Add the repair key and keep pending-file behavior**

Add `token_usage_fork_replay_v3` without deleting the v2 constant or marker. Promote an incremental request to a full scan when either repair is pending, merge both sets of pending paths into the changed-file set, and keep retrying v2 pending files. Record completion for each sweep independently. Reuse the existing per-file pending records and completion helpers.

- [ ] **Step 4: Verify repair retry tests**

Run the v3 test and all existing tests that contain `repair` in their name. Confirm that an unreadable file remains pending and a later successful read clears it.

### Task 4: Validate with real data and the full test matrix

**Files:**

- No production file changes.

**Interfaces:**

- Consumes: a temporary copy of `~/.codex`, a temporary SQLite database, and the independent audit script.
- Produces: corrected totals, database integrity evidence, and complete automated-test output.

- [ ] **Step 1: Run formatting and focused Rust tests**

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --manifest-path src-tauri/Cargo.toml importer::tests --locked
```

- [ ] **Step 2: Run the complete project checks**

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked
npm test
npm run lint
npm run build
./scripts/release/test-build-macos-release.sh
```

- [ ] **Step 3: Scan a copied source into a temporary database**

Copy `~/.codex` into a temporary directory, run the importer against a temporary SQLite database, and compare all-time plus selected-root totals with `/tmp/codex_pacer_token_replay_audit.py`. Require `PRAGMA quick_check = ok`, zero exact duplicate usage rows, and a repaired total within the audit's documented conservative bounds.

- [ ] **Step 4: Verify the installed database repair on a backup**

Copy `~/Library/Application Support/com.codex.counter/codex-counter.sqlite` to a temporary path. Run the new importer against the copy. Confirm the v3 marker exists, pending v3 files are reported, settings are unchanged, and the current root no longer contains the copied parent prefix.

### Task 5: Build, install, and launch the macOS app

**Files:**

- Build artifacts under an external `CARGO_TARGET_DIR`.
- Install: `/Applications/Codex Pacer.app`.

**Interfaces:**

- Consumes: the release script, local Developer ID identity, and the completed source tree.
- Produces: a signed app, DMG, checksum, installed app, running process, and repaired live database.

- [ ] **Step 1: Commit and verify a clean release tree**

```bash
git add docs/superpowers/specs/2026-07-10-fork-token-accounting-design.md \
  docs/superpowers/plans/2026-07-10-fork-token-accounting.md \
  src-tauri/src/models.rs src-tauri/src/importer.rs
git commit -m "fix: remove fork token replay from usage totals"
git status --short
```

- [ ] **Step 2: Build the signed app and DMG**

Use an external target directory because the repository is stored in iCloud:

```bash
export CARGO_TARGET_DIR="$HOME/.cache/codex-pacer-target"
export APPLE_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*\"\(Developer ID Application:[^\"]*\)\".*/\1/p' | head -n 1)"
./scripts/release/build-macos-release.sh 1.1.2
```

Require the app bundle, DMG, and SHA-256 file to exist. Run `codesign --verify --deep --strict` and `hdiutil verify` on the generated artifacts.

- [ ] **Step 3: Replace the installed app safely**

Quit Codex Pacer, copy the existing app to a timestamped temporary backup, install the newly built bundle into `/Applications`, and remove the backup only after launch verification.

```bash
osascript -e 'tell application "Codex Pacer" to quit' || true
ditto "/Applications/Codex Pacer.app" "/tmp/Codex Pacer.previous.app"
rm -rf "/Applications/Codex Pacer.app"
ditto "$CARGO_TARGET_DIR/release/bundle/macos/Codex Pacer.app" "/Applications/Codex Pacer.app"
open -a "/Applications/Codex Pacer.app"
```

- [ ] **Step 4: Verify the running installation**

Confirm the process executable resolves inside `/Applications/Codex Pacer.app`, the bundle version is `1.1.2`, the code signature passes, the v3 repair marker appears after scan completion, SQLite quick check returns `ok`, and the dashboard database totals match the corrected importer output.

- [ ] **Step 5: Push the development branch**

```bash
git push origin codex/adapt-chatgpt-codex-5-6
```

Report the installed app path, DMG path, checksum, test commands, corrected before-and-after totals, and any source files that remain pending. Ask the user to test before starting the PR flow.

# Codex 5.6 and ChatGPT app compatibility implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Codex Pacer accurate with the GPT-5.6 model family and the merged ChatGPT desktop app, while repairing confirmed stale and partial data-update paths.

**Architecture:** Preserve the current JSONL-to-SQLite pipeline. Extend the executable resolver and pricing catalog at their existing boundaries, then make importer, persisted quota, and frontend cache updates fail safely. Startup pricing-signature comparison remains the migration trigger for historical value recalculation.

**Tech stack:** Rust 2021, rusqlite, serde_json, Tauri 2, React 19, TypeScript 5.9, Node 22, Vite 8.

## Global constraints

- Keep `CODEX_BIN` and explicit `CODEX_HOME` settings authoritative.
- Keep Codex Pacer branding, bundle identifiers, database names, and internal event names unchanged.
- Treat `gpt-5.6` as an alias for `gpt-5.6-sol`.
- Use OpenAI Standard API prices, not Codex credit rates.
- Preserve unknown model IDs and assign no guessed API-equivalent value.
- Do not expose implementation notes or migration mechanics in the user interface.
- Every production behavior change begins with a test that fails for the expected reason.

---

### Task 1: GPT-5.6 pricing and historical value repair

**Files:**

- Modify: `src-tauri/src/pricing.rs`
- Modify: `src-tauri/src/importer.rs`
- Modify: `src-tauri/src/lib.rs`

**Interfaces:**

- Consumes: `pricing_seed()`, `parse_official_pricing_catalog()`, `resolve_pricing()`, and the existing startup pricing-signature check.
- Produces: catalog entries for `gpt-5.6`, `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`; row parsing that uses the last price as output; automatic repair and recalculation of stored values.

- [ ] **Step 1: Add failing pricing tests**

Add tests that require exact prices, dated-prefix fallback, alias behavior, distinct display names, and the new four-price official row:

```rust
#[test]
fn resolve_pricing_includes_gpt_56_family_and_alias() {
    let catalog = pricing_seed()
        .into_iter()
        .map(|entry| (entry.model_id.clone(), entry))
        .collect::<HashMap<_, _>>();

    for (model, input, cached, output) in [
        ("gpt-5.6", 5.0, 0.5, 30.0),
        ("gpt-5.6-sol-2026-07-09", 5.0, 0.5, 30.0),
        ("gpt-5.6-terra-2026-07-09", 2.5, 0.25, 15.0),
        ("gpt-5.6-luna-2026-07-09", 1.0, 0.1, 6.0),
    ] {
        let pricing = resolve_pricing(&catalog, model).expect(model);
        assert_eq!(pricing.input_price_per_million, input);
        assert_eq!(pricing.cached_input_price_per_million, cached);
        assert_eq!(pricing.output_price_per_million, output);
    }
}

#[test]
fn parses_gpt_56_cache_write_price_without_treating_it_as_output() {
    let html = complete_standard_fixture_with_gpt56_rows();
    let catalog = parse_official_pricing_catalog(&html)
        .expect("parse pricing")
        .into_iter()
        .map(|entry| (entry.model_id.clone(), entry))
        .collect::<HashMap<_, _>>();

    assert_eq!(catalog["gpt-5.6-sol"].output_price_per_million, 30.0);
    assert_eq!(catalog["gpt-5.6-terra"].output_price_per_million, 15.0);
    assert_eq!(catalog["gpt-5.6-luna"].output_price_per_million, 6.0);
}

fn complete_standard_fixture_with_gpt56_rows() -> String {
    concat!(
        "<astro-island component-export=\"TextTokenPricingTables\" props=\"{&quot;tier&quot;:[0,&quot;standard&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.6-sol&quot;],[0,5],[0,0.5],[0,6.25],[0,30]]],[1,[[0,&quot;gpt-5.6-terra&quot;],[0,2.5],[0,0.25],[0,3.125],[0,15]]],[1,[[0,&quot;gpt-5.6-luna&quot;],[0,1],[0,0.1],[0,1.25],[0,6]]],[1,[[0,&quot;gpt-5.5 (&lt;272K context length)&quot;],[0,5],[0,0.5],[0,30]]],[1,[[0,&quot;gpt-5.4 (&lt;272K context length)&quot;],[0,2.5],[0,0.25],[0,15]]],[1,[[0,&quot;gpt-5.4-mini&quot;],[0,0.75],[0,0.075],[0,4.5]]],[1,[[0,&quot;gpt-5.4-nano&quot;],[0,0.2],[0,0.02],[0,1.25]]]]]}\"></astro-island>",
        "<astro-island component-export=\"GroupedPricingTable\" props=\"{&quot;groups&quot;:[1,[[0,{&quot;model&quot;:[0,&quot;Codex&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.3-codex&quot;],[0,1.75],[0,0.175],[0,14]]]]]}]]]}\"></astro-island>"
    ).to_string()
}
```

- [ ] **Step 2: Run the pricing tests and verify RED**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml pricing::tests::resolve_pricing_includes_gpt_56_family_and_alias -- --exact
cargo test --manifest-path src-tauri/Cargo.toml pricing::tests::parses_gpt_56_cache_write_price_without_treating_it_as_output -- --exact
```

Expected: the first test fails because 5.6 has no catalog entry; the second fails because `6.25` is read as Sol output.

- [ ] **Step 3: Implement the model catalog and row-boundary parser**

Add the official Standard prices to the seed. Store the alias with `effective_model_id` set to `gpt-5.6-sol`. Refactor row parsing to collect values only until the next model-name marker:

```rust
let next_row = block[name_end..]
    .find(marker)
    .map(|offset| name_end + offset)
    .unwrap_or(block.len());
let row_source = &block[name_end..next_row];
let mut value_cursor = 0usize;
let mut values = Vec::new();
while let Some(value) = parse_next_pricing_value(row_source, &mut value_cursor) {
    values.push(value);
}

let input = values.first().copied().flatten();
let cached_input = values.get(1).copied().flatten();
let output = values.last().copied().flatten();
```

Require the three explicit GPT-5.6 rows in `required_models`. Add prefix resolution in this order: Sol, Terra, Luna, then the family alias. Add display names and existing-theme chart colors for all four IDs.

- [ ] **Step 4: Add failing corruption and startup-recalculation tests**

Insert an official Sol row with input `5.0`, cached input `0.5`, and output `6.25`, then call `seed_pricing_catalog`. Assert output becomes `30.0`. Add a startup database test with a zero-valued `gpt-5.6-sol` usage event and assert `prepare_app_database` recalculates it.

- [ ] **Step 5: Verify the repair tests fail for the intended reasons**

Run:

```bash
cargo test --manifest-path src-tauri/Cargo.toml pricing::tests::seed_repairs_misparsed_gpt_56_output_prices -- --exact
cargo test --manifest-path src-tauri/Cargo.toml tests::startup_database_prepare_recalculates_new_gpt_56_values -- --exact
```

Expected: the malformed official row remains `6.25`, and the event remains zero.

- [ ] **Step 6: Repair only the known malformed pattern**

Allow `PreserveOfficial` seeding to replace a GPT-5.6 row only when its current output equals `input * 1.25`, within floating-point tolerance. Correct official rows remain untouched. The existing before-and-after pricing signature then triggers `recalculate_all_session_values`.

- [ ] **Step 7: Add and pass a GPT-5.6 importer fixture**

Create a JSONL fixture in the importer test with `turn_context.payload.model = "gpt-5.6-sol"` and a token snapshot. Assert token totals and the Standard API-equivalent value. Run the full pricing and importer test modules.

- [ ] **Step 8: Commit Task 1**

```bash
git add src-tauri/src/pricing.rs src-tauri/src/importer.rs src-tauri/src/lib.rs
git commit -m "fix: support GPT-5.6 pricing and value repair"
```

### Task 2: ChatGPT desktop executable discovery

**Files:**

- Modify: `src-tauri/src/rate_limits.rs`

**Interfaces:**

- Consumes: `resolve_codex_binary_from_env()` and `app_server_command_spec()`.
- Produces: macOS candidate paths for the merged ChatGPT app and legacy Codex app without changing Windows or Linux behavior.

- [ ] **Step 1: Add failing macOS resolver tests**

```rust
#[test]
#[cfg(target_os = "macos")]
fn resolve_codex_binary_prefers_chatgpt_app_bundle() {
    let resolved = super::resolve_codex_binary_from_env(
        None,
        None,
        Some(Path::new("/Users/CodexUser")),
        existing_paths(&[
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ]),
    );
    assert_eq!(resolved, PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"));
}

#[test]
#[cfg(target_os = "macos")]
fn resolve_codex_binary_uses_legacy_app_when_chatgpt_is_missing() {
    let resolved = super::resolve_codex_binary_from_env(
        None,
        None,
        Some(Path::new("/Users/CodexUser")),
        existing_paths(&["/Applications/Codex.app/Contents/Resources/codex"]),
    );
    assert_eq!(resolved, PathBuf::from("/Applications/Codex.app/Contents/Resources/codex"));
}
```

- [ ] **Step 2: Run both tests and verify RED**

Expected: both resolve to the fallback command name because app bundle paths are absent from the candidate list.

- [ ] **Step 3: Add ordered macOS bundle candidates**

Inside the non-Windows candidate builder, prepend system and user `ChatGPT.app` paths, followed by system and user `Codex.app` paths under `#[cfg(target_os = "macos")]`. Keep `CODEX_BIN` resolution outside this list so it stays first.

- [ ] **Step 4: Verify GREEN and remove platform-only warnings**

Conditionally import Windows-only test types. Run `cargo test --manifest-path src-tauri/Cargo.toml rate_limits::tests` and require clean compiler output.

- [ ] **Step 5: Commit Task 2**

```bash
git add src-tauri/src/rate_limits.rs
git commit -m "fix: discover Codex inside the ChatGPT app"
```

### Task 3: Importer update integrity

**Files:**

- Modify: `src-tauri/src/importer.rs`

**Interfaces:**

- Consumes: `perform_scan()`, `perform_incremental_scan()`, `ImportState`, session JSONL, and `session_index.jsonl`.
- Produces: validated custom homes, immediate moved-archive imports, title-only refresh, read-error retry, and topology self-repair.

- [ ] **Step 1: Add failing tests for each confirmed importer edge**

Add five tests. Reuse the existing `write_session_file`, `write_session_file_with_parent`, `session_usage_totals`, and `conversation_link` test helpers:

```rust
#[test]
fn invalid_custom_home_does_not_advance_completed_scan_time() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("usage.sqlite");
    let missing = directory.path().join("missing-codex-home");

    let error = perform_scan(&db_path, Some(missing.to_string_lossy().to_string()))
        .expect_err("missing home must fail");
    assert!(error.contains("existing directory"));

    let conn = open_connection(&db_path).expect("open db");
    let completed: Option<String> = conn
        .query_row(
            "SELECT last_scan_completed_at FROM sync_settings WHERE singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .expect("load completion");
    assert!(completed.is_none());
}

#[test]
fn incremental_scan_imports_final_snapshot_after_active_file_is_archived() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    let archived = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    std::fs::create_dir_all(&archived).expect("archive");
    let session_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    let active_path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let archived_path = archived.join(active_path.file_name().expect("filename"));
    write_session_file(&active_path, session_id, &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)]);
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");

    write_session_file(
        &active_path,
        session_id,
        &[
            ("2026-07-10T00:00:00Z", 100, 20, 10, 110),
            ("2026-07-10T00:01:00Z", 180, 40, 20, 200),
        ],
    );
    std::fs::rename(&active_path, &archived_path).expect("archive session");
    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
        .expect("incremental scan");

    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(session_usage_totals(&conn, session_id).4, 200);
    assert_eq!(session_source_state(&conn, session_id).as_deref(), Some("archived"));
}

#[test]
fn full_scan_refreshes_title_when_only_session_index_changes() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    write_session_file(
        &sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl")),
        session_id,
        &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    let index_path = codex_home.join("session_index.jsonl");
    std::fs::write(&index_path, format!("{{\"id\":\"{session_id}\",\"thread_name\":\"A\"}}\n"))
        .expect("title A");
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    std::fs::write(&index_path, format!("{{\"id\":\"{session_id}\",\"thread_name\":\"B\"}}\n"))
        .expect("title B");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("second scan");

    let conn = open_connection(&db_path).expect("open db");
    let title: String = conn
        .query_row("SELECT title FROM sessions WHERE session_id = ?1", params![session_id], |row| row.get(0))
        .expect("title");
    assert_eq!(title, "B");
}

#[test]
fn invalid_utf8_does_not_commit_partial_session_or_import_state() {
    use std::io::Write;

    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let session_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    let path = sessions.join(format!("rollout-2026-07-10T00-00-00-{session_id}.jsonl"));
    let mut file = File::create(&path).expect("session file");
    writeln!(file, "{{\"timestamp\":\"2026-07-10T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{session_id}\"}}}}")
        .expect("meta");
    file.write_all(&[0xff, b'\n']).expect("invalid utf8");
    writeln!(file, "{{\"timestamp\":\"2026-07-10T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.6-sol\"}}}}")
        .expect("tail");
    drop(file);

    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("scan skips bad file");
    let conn = open_connection(&db_path).expect("open db");
    let sessions_count: i64 = conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0)).expect("sessions");
    let states_count: i64 = conn.query_row("SELECT COUNT(*) FROM import_state", [], |row| row.get(0)).expect("states");
    assert_eq!((sessions_count, states_count), (0, 0));
}

#[test]
fn incremental_scan_repairs_missing_conversation_link_without_source_change() {
    let directory = tempdir().expect("tempdir");
    let codex_home = directory.path().join("codex-home");
    let sessions = codex_home.join("sessions");
    std::fs::create_dir_all(&sessions).expect("sessions");
    let parent = "dddddddd-dddd-dddd-dddd-dddddddddddd";
    let child = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee";
    write_session_file_with_parent(
        &sessions.join(format!("rollout-2026-07-10T00-00-00-{parent}.jsonl")),
        parent,
        None,
        &[("2026-07-10T00:00:00Z", 100, 20, 10, 110)],
    );
    write_session_file_with_parent(
        &sessions.join(format!("rollout-2026-07-10T00-01-00-{child}.jsonl")),
        child,
        Some(parent),
        &[("2026-07-10T00:01:00Z", 50, 10, 5, 55)],
    );
    let db_path = directory.path().join("usage.sqlite");
    perform_scan(&db_path, Some(codex_home.to_string_lossy().to_string())).expect("first scan");
    let conn = open_connection(&db_path).expect("open db");
    conn.execute("DELETE FROM conversation_links WHERE session_id = ?1", params![child])
        .expect("remove link");
    drop(conn);

    perform_incremental_scan(&db_path, Some(codex_home.to_string_lossy().to_string()))
        .expect("repair scan");
    let conn = open_connection(&db_path).expect("open db");
    assert_eq!(conversation_link(&conn, child).expect("child link").0, parent);
}
```

Use concrete assertions: final token total equals the appended snapshot, source state is `archived`, title equals `B`, partial session count is zero, and the child root equals its parent.

- [ ] **Step 2: Run each test and verify RED**

Run each exact test name with `cargo test --manifest-path src-tauri/Cargo.toml importer::tests::<name> -- --exact`. Confirm each failure matches the audited behavior.

- [ ] **Step 3: Validate and expand Codex home paths**

Add a helper that expands exactly `~` and `~/...` against the resolved home directory, then rejects a path that does not exist or is not a directory:

```rust
fn validate_codex_home(path: PathBuf, home_dir: Option<&Path>) -> Result<PathBuf, String> {
    let expanded = expand_home_prefix(path, home_dir)?;
    if !expanded.is_dir() {
        return Err(format!("Codex home is not an existing directory: {}", expanded.display()));
    }
    Ok(expanded)
}
```

Call this before `set_last_scan_started`.

- [ ] **Step 4: Detect active files moved to the archive**

Load `source_bucket` into `ImportState`. During an incremental scan, build the active path set. For each missing active import state, test `codex_home/archived_sessions/<original filename>`. Add an existing match as an archived `SessionFile` so normal parsing and duplicate-state cleanup handle it.

- [ ] **Step 5: Refresh titles and topology independently of changed JSONL**

On a full scan, load `session_index.jsonl` once and update matching non-empty titles even if no session file changed. Add `conversation_links_need_repair()` that detects a session without a link or with a direct-parent mismatch. Recompute links when this check or the existing topology flag is true.

- [ ] **Step 6: Propagate line read errors**

Replace `map_while(Result::ok)` in `parse_session_file_once` with an explicit loop:

```rust
for line_result in BufReader::new(file).lines() {
    let line = line_result.map_err(|error| {
        SessionParseError::Fatal(format!("Failed to read {}: {error}", session_file.path.display()))
    })?;
    // Existing JSON parsing follows.
}
```

Keep malformed JSON lines retryable, including an incomplete trailing record.

- [ ] **Step 7: Run all importer tests and verify GREEN**

Run `cargo test --manifest-path src-tauri/Cargo.toml importer::tests`. Require all old incomplete-line and replay tests to remain green.

- [ ] **Step 8: Commit Task 3**

```bash
git add src-tauri/src/importer.rs
git commit -m "fix: make session imports update safely"
```

### Task 4: Persisted live-quota freshness

**Files:**

- Modify: `src-tauri/src/lib.rs`

**Interfaces:**

- Consumes: `rate_limit_samples.sample_timestamp` and `load_persisted_live_rate_limits_for_source()`.
- Produces: absolute-time ordering and a snapshot containing only windows from the same sample instant.

- [ ] **Step 1: Add failing mixed-offset and mixed-sample tests**

Insert `2026-07-10T09:00:00+08:00` followed by `2026-07-10T02:00:00Z`; assert the latter wins. Insert an older primary and secondary pair plus a newer primary-only sample; assert the result contains the newer primary and no secondary.

- [ ] **Step 2: Run both tests and verify RED**

Expected: text sorting chooses `09:00+08:00`, and the loader combines windows from different samples.

- [ ] **Step 3: Order by SQLite time and select one coherent sample**

Use `ORDER BY julianday(sample_timestamp) DESC, id DESC`. Parse each selected timestamp with `DateTime::parse_from_rfc3339`, find the newest instant, and discard a window whose timestamp differs from that instant. Set `fetched_at` to the retained timestamp.

- [ ] **Step 4: Run live-rate fallback tests and verify GREEN**

Run `cargo test --manifest-path src-tauri/Cargo.toml tests::background_live_rate_limit` and the two new exact tests.

- [ ] **Step 5: Commit Task 4**

```bash
git add src-tauri/src/lib.rs
git commit -m "fix: select coherent persisted quota samples"
```

### Task 5: Settings, detail cache, and overlapping refreshes

**Files:**

- Create: `src/app/dataFreshness.ts`
- Create: `scripts/test-data-freshness.mjs`
- Modify: `src/App.tsx`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src-tauri/src/database/sync_settings.rs`
- Modify: `package.json`

**Interfaces:**

- Consumes: `ConversationDetail`, `ConversationListItem`, `SubscriptionProfile`, scan state, and saved sync settings.
- Produces: cache-retention and scan-settle helpers plus freshness reset when Codex home changes.

- [ ] **Step 1: Add failing Node behavior tests**

Export these pure helpers from `src/app/dataFreshness.ts`:

```ts
export function shouldKeepConversationDetail(
  cached: ConversationDetail,
  summary: ConversationListItem,
  monthlyPrice: number,
): boolean

export async function waitForOverlappingScan(
  getScanInProgress: () => Promise<boolean>,
  waitForScanToSettle: () => Promise<void>,
): Promise<void>
```

The Node test imports the TypeScript file directly. It asserts cache rejection when API value or expected subscription share changes, cache retention when all derived values match, and one settle wait when scan state is true.

- [ ] **Step 2: Run the Node test and verify RED**

Run `node scripts/test-data-freshness.mjs`. Expected: module or export not found.

- [ ] **Step 3: Implement the helpers and use them in App.tsx**

Use a small epsilon for floating-point comparisons. In `loadShell`, retain cached detail only through `shouldKeepConversationDetail`. After `refreshBackgroundData`, call `waitForOverlappingScan(getScanInProgress, waitForScanToSettle)` before `loadShell(false)`.

- [ ] **Step 4: Add a failing Rust test for source switching**

Save settings with scan timestamps, change only `codex_home`, call the backend normalization helper, and assert both exposed scan timestamps and `last_full_scan_completed_at` are cleared.

- [ ] **Step 5: Reset freshness and trigger the new full scan**

Add `clear_scan_timestamps()` in `database/sync_settings.rs`. Call it after saving when normalized `codex_home` changed. In `handleSaveSettings`, update `syncSettingsRef.current` immediately and call `loadShell(true)` when the home changed; otherwise call `loadShell(false)`.

- [ ] **Step 6: Add the Node test to npm test and verify GREEN**

Add `test:data-freshness` to `package.json` and include it in `npm test`. Run `npm test`, `npm run lint`, and `npm run build`.

- [ ] **Step 7: Commit Task 5**

```bash
git add src/app/dataFreshness.ts scripts/test-data-freshness.mjs src/App.tsx src-tauri/src/lib.rs src-tauri/src/database/sync_settings.rs package.json
git commit -m "fix: invalidate stale dashboard data"
```

### Task 6: Documentation and full verification

**Files:**

- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CONTRIBUTING.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

- Consumes: final verified behavior and exact commands.
- Produces: current setup guidance and a concise change record.

- [ ] **Step 1: Update setup and test commands**

State that Codex Pacer can use the CLI bundled with the ChatGPT desktop app on macOS. Replace root-level `cargo test` examples with:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --locked
```

- [ ] **Step 2: Humanize and audit the documentation**

Keep the prose factual. Scan for placeholders, em dashes, en dashes, stale Codex app-only wording, and accidental implementation notes.

- [ ] **Step 3: Run static and unit verification**

```bash
npm test
npm run lint
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
./scripts/release/audit-public-branding.sh
./scripts/release/test-build-macos-release.sh
```

- [ ] **Step 4: Run real local-data verification without mutating the live Pacer database**

Copy the current `~/.codex` session and index files to a temporary Codex home. Run the backend scan against a temporary SQLite database. Compare session count, latest session model, latest token total, and GPT-5.6 API-equivalent value with direct JSONL inspection.

- [ ] **Step 5: Verify the ChatGPT-bundled app-server and packaged app**

Run initialize plus `account/rateLimits/read` through `/Applications/ChatGPT.app/Contents/Resources/codex`. Build the Tauri app, launch it with the temporary database and copied Codex home, then confirm dashboard, conversation detail, model legend, refresh, and live quota behavior.

- [ ] **Step 6: Review the complete diff**

Run `git diff develop...HEAD`, `git diff --check`, and `git status --short`. Confirm no personal paths, copied session content, credentials, build products, or unrelated dependency changes are tracked.

- [ ] **Step 7: Commit documentation and any verification-only fixtures**

```bash
git add README.md README.zh-CN.md CONTRIBUTING.md CHANGELOG.md docs/superpowers/plans/2026-07-10-codex-5-6-chatgpt-compatibility.md
git commit -m "docs: document ChatGPT and GPT-5.6 support"
```

- [ ] **Step 8: Push the development branch**

```bash
git push -u origin codex/adapt-chatgpt-codex-5-6
```

Report the branch, commit list, exact verification results, remaining warnings or environmental limits, and the user tests needed before starting the pull-request process.

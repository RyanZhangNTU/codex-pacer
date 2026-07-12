# Auto refresh quota fallback implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a newer session history timestamp from replacing a valid online quota value during a failed background refresh.

**Architecture:** Keep source precedence separate from timestamp ordering. A live value confirmed in the current process wins first, followed by persisted live data, then an existing display fallback, and finally session history. Compare timestamps only within the live source group. The change stays in the Rust fallback loader and its tests. The frontend and database schema do not change.

**Tech Stack:** Rust 2021, Tauri 2, rusqlite, chrono, Cargo tests, npm scripts, TypeScript, Vite, ESLint.

## Global Constraints

- A session timestamp must never outrank an online value merely because it is later.
- A live fallback remains eligible for another live refresh and must not be treated as a fresh success.
- Startup fallback loading must prefer persisted live data before session history.
- Passive reads must not start a fetch or a scan.
- Use the current codex/release-1.2.0 branch as explicitly requested by the user.
- Do not change the frontend or database schema for this fix.

---

### Task 1: Add failing mixed-source fallback tests

**Files:**

- Modify: src-tauri/src/lib.rs in the existing test module, near background_live_rate_limit_fallback_prefers_newest_persisted_sample

**Interfaces:**

- Consumes: prepare_app_database, database::replace_session_rate_limit_samples, insert_live_rate_limit_snapshot, LiveQuotaCache, and load_display_live_rate_limit_fallback.
- Produces: Regression tests that fail against the current mixed-source timestamp selection and preserve the existing history fallback contract.

- [ ] **Step 1: Add small test builders for live and session samples**

Add test-only helpers beside the existing quota fallback tests. Use a fixed five-hour window so each fixture has a coherent bucket and a distinct value:

~~~rust
fn test_live_quota_snapshot(fetched_at: &str, remaining_percent: i64) -> LiveRateLimitSnapshot {
  LiveRateLimitSnapshot {
    limit_id: Some("codex".to_string()),
    limit_name: Some("Codex".to_string()),
    plan_type: Some("pro".to_string()),
    primary: Some(RateLimitWindowSnapshot {
      used_percent: 100 - remaining_percent,
      remaining_percent,
      window_duration_mins: Some(300),
      resets_at: Some("2026-07-12T05:00:00+08:00".to_string()),
      window_start: Some("2026-07-12T00:00:00+08:00".to_string()),
    }),
    secondary: None,
    fetched_at: fetched_at.to_string(),
  }
}

fn test_session_quota_sample(
  session_id: &str,
  sample_timestamp: &str,
  remaining_percent: i64,
) -> crate::models::RateLimitSampleRecord {
  crate::models::RateLimitSampleRecord {
    source_kind: "session".to_string(),
    source_session_id: Some(session_id.to_string()),
    bucket: "five_hour".to_string(),
    sample_timestamp: sample_timestamp.to_string(),
    limit_id: Some("codex".to_string()),
    limit_name: Some("Codex".to_string()),
    plan_type: Some("pro".to_string()),
    window_start: "2026-07-12T00:00:00+08:00".to_string(),
    resets_at: "2026-07-12T05:00:00+08:00".to_string(),
    used_percent: 100 - remaining_percent,
    remaining_percent,
  }
}
~~~

- [ ] **Step 2: Add the current-process live value regression test**

Add background_live_fallback_keeps_current_live_over_newer_session. Insert a session sample at 2026-07-12T00:10:00+08:00, put a live snapshot at 2026-07-12T00:05:00+08:00 into the cache with publish_live, then call load_display_live_rate_limit_fallback. Assert that the returned timestamp is 2026-07-12T00:05:00+08:00 and the returned remaining value is the live value, not the session value:

~~~rust
#[test]
fn background_live_fallback_keeps_current_live_over_newer_session() {
  let directory = tempdir().expect("tempdir");
  let db_path = directory.path().join("usage.sqlite");
  prepare_app_database(&db_path).expect("prepare app database");
  let conn = open_connection(&db_path).expect("open database");
  database::replace_session_rate_limit_samples(
    &conn,
    "session-late",
    &[test_session_quota_sample(
      "session-late",
      "2026-07-12T00:10:00+08:00",
      20,
    )],
  )
  .expect("insert newer session sample");
  drop(conn);

  let live_cache = refresh::LiveQuotaCache::new();
  live_cache.publish_live(
    Arc::new(test_live_quota_snapshot(
      "2026-07-12T00:05:00+08:00",
      88,
    )),
    Instant::now(),
    Utc::now(),
  );

  let snapshot = load_display_live_rate_limit_fallback(&db_path, &live_cache)
    .expect("load fallback");

  assert_eq!(snapshot.fetched_at, "2026-07-12T00:05:00+08:00");
  assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(88));
}
~~~

- [ ] **Step 3: Add the persisted live precedence test**

Add background_live_fallback_prefers_persisted_live_over_newer_session. Insert a persisted live snapshot at 2026-07-12T00:05:00+08:00 with 88 percent remaining and a session sample at 2026-07-12T00:10:00+08:00 with 20 percent remaining. Use an empty cache and assert that the fallback returns the persisted live snapshot:

~~~rust
#[test]
fn background_live_fallback_prefers_persisted_live_over_newer_session() {
  let directory = tempdir().expect("tempdir");
  let db_path = directory.path().join("usage.sqlite");
  prepare_app_database(&db_path).expect("prepare app database");
  let conn = open_connection(&db_path).expect("open database");
  insert_live_rate_limit_snapshot(
    &conn,
    &test_live_quota_snapshot("2026-07-12T00:05:00+08:00", 88),
  )
  .expect("insert persisted live sample");
  database::replace_session_rate_limit_samples(
    &conn,
    "session-late",
    &[test_session_quota_sample(
      "session-late",
      "2026-07-12T00:10:00+08:00",
      20,
    )],
  )
  .expect("insert newer session sample");
  drop(conn);

  let snapshot = load_display_live_rate_limit_fallback(
    &db_path,
    &refresh::LiveQuotaCache::new(),
  )
  .expect("load fallback");

  assert_eq!(snapshot.fetched_at, "2026-07-12T00:05:00+08:00");
  assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(88));
}
~~~

- [ ] **Step 4: Add the no-live history fallback test**

Add background_live_fallback_uses_session_when_no_live_data_exists. Insert only the session sample, use an empty cache, and assert that the session timestamp and remaining value are returned. This protects the last-resort behavior.

~~~rust
#[test]
fn background_live_fallback_uses_session_when_no_live_data_exists() {
  let directory = tempdir().expect("tempdir");
  let db_path = directory.path().join("usage.sqlite");
  prepare_app_database(&db_path).expect("prepare app database");
  let conn = open_connection(&db_path).expect("open database");
  database::replace_session_rate_limit_samples(
    &conn,
    "session-only",
    &[test_session_quota_sample(
      "session-only",
      "2026-07-12T00:10:00+08:00",
      20,
    )],
  )
  .expect("insert session sample");
  drop(conn);

  let snapshot = load_display_live_rate_limit_fallback(
    &db_path,
    &refresh::LiveQuotaCache::new(),
  )
  .expect("load history fallback");

  assert_eq!(snapshot.fetched_at, "2026-07-12T00:10:00+08:00");
  assert_eq!(snapshot.primary.map(|window| window.remaining_percent), Some(20));
}
~~~

- [ ] **Step 5: Run the focused tests and verify the failure**

Run:

~~~bash
cargo test --manifest-path src-tauri/Cargo.toml --locked background_live_rate_limit_fallback -- --nocapture
~~~

Expected result: the new current-process and persisted-live tests fail because load_display_live_rate_limit_fallback currently calls load_persisted_live_rate_limits_from_connection with no source filter and compares session rows with live rows. The session-only test may pass before the production change.

- [ ] **Step 6: Commit the failing regression tests**

~~~bash
git add src-tauri/src/lib.rs
git commit -m "test: cover mixed-source quota fallback"
~~~

### Task 2: Implement source-prioritized fallback loading

**Files:**

- Modify: src-tauri/src/lib.rs in load_display_live_rate_limit_fallback and app setup fallback initialization

**Interfaces:**

- Consumes: the failing tests from Task 1, LiveQuotaCache::state, LiveQuotaCache::rate_limits, load_persisted_live_rate_limits_from_connection, and newest_live_rate_limit_snapshot.
- Produces: a fallback loader that compares only live candidates before considering session history.

- [ ] **Step 1: Add a source-priority helper for startup data**

Add this helper near load_persisted_live_rate_limits_from_connection:

~~~rust
fn load_preferred_persisted_live_rate_limits(
  conn: &rusqlite::Connection,
) -> Option<LiveRateLimitSnapshot> {
  load_persisted_live_rate_limits_from_connection(conn, Some("live"))
    .or_else(|| load_persisted_live_rate_limits_from_connection(conn, Some("session")))
}
~~~

Change app setup so display_fallback calls this helper instead of loading with no source filter and then trying session again:

~~~rust
let display_fallback = load_preferred_persisted_live_rate_limits(&conn);
~~~

Keep live_last_success_at sourced from Some("live") so the scheduler still restores the live deadline from online data only.

- [ ] **Step 2: Replace mixed-source fallback selection**

Update load_display_live_rate_limit_fallback to use the following order:

~~~rust
fn load_display_live_rate_limit_fallback(
  db_path: &Path,
  live_cache: &refresh::LiveQuotaCache,
) -> Option<LiveRateLimitSnapshot> {
  let memory = live_cache
    .rate_limits()
    .map(|snapshot| snapshot.as_ref().clone());
  let memory_is_live = live_cache.state().last_live_success_at.is_some();
  let Ok(conn) = open_connection(db_path) else {
    return memory;
  };

  let persisted_live = load_persisted_live_rate_limits_from_connection(&conn, Some("live"));
  if memory_is_live {
    return newest_live_rate_limit_snapshot([memory, persisted_live]);
  }
  if persisted_live.is_some() {
    return persisted_live;
  }
  memory.or_else(|| load_persisted_live_rate_limits_from_connection(&conn, Some("session")))
}
~~~

This preserves timestamp comparison for two live candidates. It prevents a session row from entering that comparison. A live value published by this process remains the display value even when the database contains a later session timestamp. A startup cache that has only a historical value gives persisted live data the next chance before keeping history.

- [ ] **Step 3: Run the focused regression tests**

Run:

~~~bash
cargo test --manifest-path src-tauri/Cargo.toml --locked background_live_rate_limit_fallback -- --nocapture
~~~

Expected result: all fallback tests pass, including the existing test that chooses a newer persisted live sample and the new tests from Task 1.

- [ ] **Step 4: Run formatter and focused neighboring tests**

Run:

~~~bash
cargo fmt --all -- --check
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::live_cache::tests -- --nocapture
cargo test --manifest-path src-tauri/Cargo.toml --locked refresh::runtime::tests -- --nocapture
~~~

Expected result: formatting and all focused Rust tests pass. The runtime tests must still show that a failed live request triggers a retry and a fallback token intent.

- [ ] **Step 5: Commit the production fix**

~~~bash
git add src-tauri/src/lib.rs
git commit -m "fix: prioritize live quota fallback sources"
~~~

### Task 3: Run full verification and prepare the branch

**Files:**

- Inspect: src-tauri/src/lib.rs
- Inspect: docs/superpowers/specs/2026-07-12-auto-quota-fallback-design.md
- Inspect: docs/superpowers/plans/2026-07-12-auto-quota-fallback.md

**Interfaces:**

- Consumes: the committed regression tests and source-priority implementation from Tasks 1 and 2.
- Produces: evidence that the fix does not break refresh runtime behavior, frontend checks, formatting, or build output.

- [ ] **Step 1: Run the complete Rust test suite**

Run:

~~~bash
cargo test --manifest-path src-tauri/Cargo.toml --locked
~~~

Expected result: every Rust test passes. Intentional panic messages from existing worker recovery tests are acceptable only when the tests finish successfully.

- [ ] **Step 2: Run frontend tests, lint, and build**

Run:

~~~bash
npm test
npm run lint
npm run build
~~~

Expected result: all Node test scripts pass, ESLint exits successfully, and TypeScript plus Vite produce a successful build.

- [ ] **Step 3: Inspect the final diff for scope and formatting**

Run:

~~~bash
git diff --check HEAD~2..HEAD
git diff --stat HEAD~2..HEAD
git status --short --branch
~~~

Expected result: only the fallback tests and source-priority loader changed in the implementation commits, the design and plan documents are present, and the working tree is clean.

- [ ] **Step 4: Push the current branch after verification**

Run:

~~~bash
git push origin codex/release-1.2.0
~~~

Do not create or merge a pull request in this plan. The project workflow requires the user to test the pushed branch and explicitly approve entering the PR process.

use chrono::DateTime;
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use std::sync::atomic::{AtomicBool, Ordering};

use super::now_utc_string;

const REPAIR_KEY: &str = "epoch_timestamp_backfill_v1";
const USAGE_STREAM: &str = "usage_events";
const QUOTA_STREAM: &str = "rate_limit_samples";
const MAX_BATCH_SIZE: usize = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EpochBackfillProgress {
    pub usage_rows_updated: usize,
    pub quota_rows_updated: usize,
    pub complete: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EpochBackfillCancellationPoint {
    Transaction,
    UsageRow,
    QuotaRow,
    CompletionMarker,
    Commit,
}

struct UsageEpochRow {
    id: i64,
    timestamp: String,
    timestamp_ms: Option<i64>,
}

struct QuotaEpochRow {
    id: i64,
    sample_timestamp: String,
    sample_timestamp_ms: Option<i64>,
    window_start: String,
    window_start_ms: Option<i64>,
    resets_at: String,
    resets_at_ms: Option<i64>,
}

pub(super) fn ensure_epoch_schema(conn: &Connection) -> rusqlite::Result<()> {
    ensure_integer_column(conn, "usage_events", "timestamp_ms")?;
    ensure_integer_column(conn, "rate_limit_samples", "sample_timestamp_ms")?;
    ensure_integer_column(conn, "rate_limit_samples", "window_start_ms")?;
    ensure_integer_column(conn, "rate_limit_samples", "resets_at_ms")?;
    Ok(())
}

fn ensure_integer_column(
    conn: &Connection,
    table_name: &str,
    column_name: &str,
) -> rusqlite::Result<()> {
    let mut statement = conn.prepare(&format!("PRAGMA table_info({table_name})"))?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if row.get::<_, String>(1)? == column_name {
            return Ok(());
        }
    }
    drop(rows);
    drop(statement);

    conn.execute_batch(&format!(
        "ALTER TABLE {table_name} ADD COLUMN {column_name} INTEGER"
    ))
}

pub fn parse_epoch_millis(value: &str) -> Result<i64, String> {
    DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp.timestamp_millis())
        .map_err(|error| error.to_string())
}

pub fn backfill_epoch_batch(
    conn: &Connection,
    batch_size: usize,
) -> rusqlite::Result<EpochBackfillProgress> {
    backfill_epoch_batch_with_cancel_check(conn, batch_size, |_| false)
        .map(|progress| progress.expect("non-cancellable epoch backfill returns progress"))
}

pub fn backfill_epoch_batch_cancellable(
    conn: &Connection,
    batch_size: usize,
    cancelled: &AtomicBool,
) -> rusqlite::Result<Option<EpochBackfillProgress>> {
    backfill_epoch_batch_with_cancel_check(conn, batch_size, |_| {
        cancelled.load(Ordering::Acquire)
    })
}

fn backfill_epoch_batch_with_cancel_check(
    conn: &Connection,
    batch_size: usize,
    mut is_cancelled: impl FnMut(EpochBackfillCancellationPoint) -> bool,
) -> rusqlite::Result<Option<EpochBackfillProgress>> {
    if is_cancelled(EpochBackfillCancellationPoint::Transaction) {
        return Ok(None);
    }
    let batch_size = batch_size.min(MAX_BATCH_SIZE);
    if batch_size == 0 {
        return Ok(Some(EpochBackfillProgress {
            usage_rows_updated: 0,
            quota_rows_updated: 0,
            complete: repair_is_complete(conn)?,
        }));
    }

    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if repair_is_complete(&transaction)? {
        if is_cancelled(EpochBackfillCancellationPoint::Commit) {
            return Ok(None);
        }
        transaction.commit()?;
        return Ok(Some(EpochBackfillProgress {
            usage_rows_updated: 0,
            quota_rows_updated: 0,
            complete: true,
        }));
    }

    ensure_cursor(&transaction, USAGE_STREAM)?;
    ensure_cursor(&transaction, QUOTA_STREAM)?;

    let usage_cursor = load_cursor(&transaction, USAGE_STREAM)?;
    let usage_rows = load_usage_rows(&transaction, usage_cursor, batch_size)?;
    let usage_rows_updated = usage_rows.len();
    let usage_exhausted = usage_rows_updated < batch_size;
    for row in &usage_rows {
        if is_cancelled(EpochBackfillCancellationPoint::UsageRow) {
            return Ok(None);
        }
        migrate_usage_row(&transaction, row)?;
    }
    if let Some(last_row) = usage_rows.last() {
        save_cursor(&transaction, USAGE_STREAM, last_row.id)?;
    }

    let remaining = batch_size - usage_rows_updated;
    let (quota_rows_updated, quota_exhausted) = if usage_exhausted {
        let quota_cursor = load_cursor(&transaction, QUOTA_STREAM)?;
        let quota_rows = load_quota_rows(&transaction, quota_cursor, remaining)?;
        let rows_updated = quota_rows.len();
        let exhausted = rows_updated < remaining;
        for row in &quota_rows {
            if is_cancelled(EpochBackfillCancellationPoint::QuotaRow) {
                return Ok(None);
            }
            migrate_quota_row(&transaction, row)?;
        }
        if let Some(last_row) = quota_rows.last() {
            save_cursor(&transaction, QUOTA_STREAM, last_row.id)?;
        }
        (rows_updated, exhausted)
    } else {
        (0, false)
    };

    let complete = usage_exhausted && quota_exhausted;
    if complete {
        if is_cancelled(EpochBackfillCancellationPoint::CompletionMarker) {
            return Ok(None);
        }
        transaction.execute(
            "
            INSERT INTO data_repairs (repair_key, completed_at)
            VALUES (?1, ?2)
            ON CONFLICT(repair_key) DO NOTHING
            ",
            params![REPAIR_KEY, now_utc_string()],
        )?;
    }
    if is_cancelled(EpochBackfillCancellationPoint::Commit) {
        return Ok(None);
    }
    transaction.commit()?;

    Ok(Some(EpochBackfillProgress {
        usage_rows_updated,
        quota_rows_updated,
        complete,
    }))
}

fn repair_is_complete(conn: &Connection) -> rusqlite::Result<bool> {
    epoch_backfill_pending(conn).map(|pending| !pending)
}

pub fn epoch_backfill_pending(conn: &Connection) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT 1 FROM data_repairs WHERE repair_key = ?1",
        params![REPAIR_KEY],
        |_| Ok(()),
    )
    .optional()
    .map(|value| value.is_none())
}

fn ensure_cursor(transaction: &Transaction<'_>, stream_key: &str) -> rusqlite::Result<()> {
    transaction.execute(
        "
        INSERT INTO data_repair_progress (repair_key, stream_key, progress_value)
        VALUES (?1, ?2, 0)
        ON CONFLICT(repair_key, stream_key) DO NOTHING
        ",
        params![REPAIR_KEY, stream_key],
    )?;
    Ok(())
}

fn load_cursor(transaction: &Transaction<'_>, stream_key: &str) -> rusqlite::Result<i64> {
    transaction.query_row(
        "
        SELECT progress_value
        FROM data_repair_progress
        WHERE repair_key = ?1 AND stream_key = ?2
        ",
        params![REPAIR_KEY, stream_key],
        |row| row.get(0),
    )
}

fn save_cursor(
    transaction: &Transaction<'_>,
    stream_key: &str,
    progress_value: i64,
) -> rusqlite::Result<()> {
    transaction.execute(
        "
        UPDATE data_repair_progress
        SET progress_value = ?3
        WHERE repair_key = ?1 AND stream_key = ?2
        ",
        params![REPAIR_KEY, stream_key, progress_value],
    )?;
    Ok(())
}

fn load_usage_rows(
    transaction: &Transaction<'_>,
    cursor: i64,
    limit: usize,
) -> rusqlite::Result<Vec<UsageEpochRow>> {
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let mut statement = transaction.prepare(
        "
        SELECT id, timestamp, timestamp_ms
        FROM usage_events
        WHERE id > ?1
        ORDER BY id
        LIMIT ?2
        ",
    )?;
    let rows = statement
        .query_map(params![cursor, limit], |row| {
            Ok(UsageEpochRow {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                timestamp_ms: row.get(2)?,
            })
        })?
        .collect();
    rows
}

fn load_quota_rows(
    transaction: &Transaction<'_>,
    cursor: i64,
    limit: usize,
) -> rusqlite::Result<Vec<QuotaEpochRow>> {
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let mut statement = transaction.prepare(
        "
        SELECT id,
               sample_timestamp, sample_timestamp_ms,
               window_start, window_start_ms,
               resets_at, resets_at_ms
        FROM rate_limit_samples
        WHERE id > ?1
        ORDER BY id
        LIMIT ?2
        ",
    )?;
    let rows = statement
        .query_map(params![cursor, limit], |row| {
            Ok(QuotaEpochRow {
                id: row.get(0)?,
                sample_timestamp: row.get(1)?,
                sample_timestamp_ms: row.get(2)?,
                window_start: row.get(3)?,
                window_start_ms: row.get(4)?,
                resets_at: row.get(5)?,
                resets_at_ms: row.get(6)?,
            })
        })?
        .collect();
    rows
}

fn migrate_usage_row(
    transaction: &Transaction<'_>,
    row: &UsageEpochRow,
) -> rusqlite::Result<()> {
    if row.timestamp_ms.is_some() {
        return Ok(());
    }

    match parse_epoch_millis(&row.timestamp) {
        Ok(timestamp_ms) => {
            transaction.execute(
                "
                UPDATE usage_events
                SET timestamp_ms = ?1
                WHERE id = ?2 AND timestamp_ms IS NULL
                ",
                params![timestamp_ms, row.id],
            )?;
        }
        Err(error) => quarantine_value(
            transaction,
            "usage_events",
            row.id,
            "timestamp",
            &row.timestamp,
            &error,
        )?,
    }
    Ok(())
}

fn migrate_quota_row(
    transaction: &Transaction<'_>,
    row: &QuotaEpochRow,
) -> rusqlite::Result<()> {
    let sample_timestamp_ms = parse_missing_value(
        transaction,
        "rate_limit_samples",
        row.id,
        "sample_timestamp",
        &row.sample_timestamp,
        row.sample_timestamp_ms,
    )?;
    let window_start_ms = parse_missing_value(
        transaction,
        "rate_limit_samples",
        row.id,
        "window_start",
        &row.window_start,
        row.window_start_ms,
    )?;
    let resets_at_ms = parse_missing_value(
        transaction,
        "rate_limit_samples",
        row.id,
        "resets_at",
        &row.resets_at,
        row.resets_at_ms,
    )?;

    if sample_timestamp_ms.is_none() && window_start_ms.is_none() && resets_at_ms.is_none() {
        return Ok(());
    }

    transaction.execute(
        "
        UPDATE rate_limit_samples
        SET sample_timestamp_ms = COALESCE(sample_timestamp_ms, ?1),
            window_start_ms = COALESCE(window_start_ms, ?2),
            resets_at_ms = COALESCE(resets_at_ms, ?3)
        WHERE id = ?4
        ",
        params![sample_timestamp_ms, window_start_ms, resets_at_ms, row.id],
    )?;
    Ok(())
}

fn parse_missing_value(
    transaction: &Transaction<'_>,
    table_name: &str,
    row_id: i64,
    column_name: &str,
    raw_value: &str,
    current_value: Option<i64>,
) -> rusqlite::Result<Option<i64>> {
    if current_value.is_some() {
        return Ok(None);
    }

    match parse_epoch_millis(raw_value) {
        Ok(value) => Ok(Some(value)),
        Err(error) => {
            quarantine_value(
                transaction,
                table_name,
                row_id,
                column_name,
                raw_value,
                &error,
            )?;
            Ok(None)
        }
    }
}

fn quarantine_value(
    transaction: &Transaction<'_>,
    table_name: &str,
    row_id: i64,
    column_name: &str,
    raw_value: &str,
    error_message: &str,
) -> rusqlite::Result<()> {
    transaction.execute(
        "
        INSERT INTO data_repair_quarantine (
          repair_key, table_name, row_id, column_name,
          raw_value, error_message, quarantined_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(repair_key, table_name, row_id, column_name) DO UPDATE SET
          raw_value = excluded.raw_value,
          error_message = excluded.error_message,
          quarantined_at = excluded.quarantined_at
        ",
        params![
            REPAIR_KEY,
            table_name,
            row_id,
            column_name,
            raw_value,
            error_message,
            now_utc_string()
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, Ordering};

    use rusqlite::{params, Connection};
    use tempfile::tempdir;

    use super::{
        backfill_epoch_batch, backfill_epoch_batch_cancellable,
        backfill_epoch_batch_with_cancel_check, epoch_backfill_pending,
        EpochBackfillCancellationPoint, parse_epoch_millis,
    };
    use crate::database::init_db;

    const REPAIR_KEY: &str = "epoch_timestamp_backfill_v1";

    fn assert_repair_transaction_is_empty(conn: &Connection) {
        let usage_epochs: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE timestamp_ms IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .expect("count usage epochs");
        let quota_epochs: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM rate_limit_samples WHERE sample_timestamp_ms IS NOT NULL OR window_start_ms IS NOT NULL OR resets_at_ms IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .expect("count quota epochs");
        let cursors: i64 = conn
            .query_row("SELECT COUNT(*) FROM data_repair_progress", [], |row| row.get(0))
            .expect("count repair cursors");
        let quarantine: i64 = conn
            .query_row("SELECT COUNT(*) FROM data_repair_quarantine", [], |row| row.get(0))
            .expect("count quarantine rows");
        let completion: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("count completion markers");
        assert_eq!((usage_epochs, quota_epochs, cursors, quarantine, completion), (0, 0, 0, 0, 0));
    }

    fn assert_cancel_at(point: EpochBackfillCancellationPoint, seed: impl FnOnce(&Connection)) {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        seed(&conn);

        let outcome = backfill_epoch_batch_with_cancel_check(&conn, 1_000, |observed| {
            observed == point
        })
        .expect("cancel bounded epoch repair");

        assert!(outcome.is_none(), "cancelled repair returns no progress");
        assert_repair_transaction_is_empty(&conn);
    }

    fn create_legacy_epoch_tables(conn: &Connection) {
        conn.execute_batch(
            "
            CREATE TABLE usage_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              model_id TEXT NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              value_usd REAL NOT NULL,
              fast_mode_auto INTEGER NOT NULL,
              fast_mode_effective INTEGER NOT NULL
            );

            CREATE TABLE rate_limit_samples (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_kind TEXT NOT NULL,
              source_session_id TEXT NOT NULL DEFAULT '',
              bucket TEXT NOT NULL,
              sample_timestamp TEXT NOT NULL,
              limit_id TEXT NOT NULL DEFAULT '',
              limit_name TEXT NOT NULL DEFAULT '',
              plan_type TEXT NOT NULL DEFAULT '',
              window_start TEXT NOT NULL,
              resets_at TEXT NOT NULL,
              used_percent INTEGER NOT NULL,
              remaining_percent INTEGER NOT NULL,
              created_at TEXT NOT NULL
            );
            ",
        )
        .expect("create legacy epoch tables");
    }

    fn insert_usage(conn: &Connection, timestamp: &str) -> i64 {
        conn.execute(
            "
            INSERT INTO usage_events (
              session_id, timestamp, model_id,
              input_tokens, cached_input_tokens, output_tokens,
              reasoning_output_tokens, total_tokens, value_usd,
              fast_mode_auto, fast_mode_effective
            )
            VALUES ('session', ?1, 'gpt-5', 1, 0, 1, 0, 2, 0.01, 0, 0)
            ",
            params![timestamp],
        )
        .expect("insert usage event");
        conn.last_insert_rowid()
    }

    fn insert_quota(conn: &Connection, timestamp: &str) -> i64 {
        insert_quota_fields(conn, timestamp, timestamp, timestamp)
    }

    fn insert_quota_fields(
        conn: &Connection,
        sample_timestamp: &str,
        window_start: &str,
        resets_at: &str,
    ) -> i64 {
        conn.execute(
            "
            INSERT INTO rate_limit_samples (
              source_kind, source_session_id, bucket,
              sample_timestamp, limit_id, limit_name, plan_type,
              window_start, resets_at, used_percent, remaining_percent, created_at
            )
            VALUES (
              'session', '', 'five_hour',
              ?1, '', '', 'plus',
              ?2, ?3, 25, 75, ?1
            )
            ",
            params![sample_timestamp, window_start, resets_at],
        )
        .expect("insert quota sample");
        conn.last_insert_rowid()
    }

    fn column_names(conn: &Connection, table: &str) -> Vec<String> {
        let mut statement = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .expect("prepare table info");
        statement
            .query_map([], |row| row.get(1))
            .expect("query table info")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("collect column names")
    }

    fn open_initialized(path: &Path) -> Connection {
        let conn = Connection::open(path).expect("open database");
        init_db(&conn).expect("initialize database");
        conn
    }

    #[test]
    fn init_db_adds_epoch_columns_without_updating_history() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        create_legacy_epoch_tables(&conn);
        let usage_id = insert_usage(&conn, "2026-07-10T10:00:00+08:00");
        let quota_id = insert_quota(&conn, "2026-07-10T03:00:01Z");

        init_db(&conn).expect("migrate legacy database");

        let usage_columns = column_names(&conn, "usage_events");
        assert!(usage_columns.iter().any(|name| name == "timestamp_ms"));
        let quota_columns = column_names(&conn, "rate_limit_samples");
        for expected in ["sample_timestamp_ms", "window_start_ms", "resets_at_ms"] {
            assert!(quota_columns.iter().any(|name| name == expected));
        }

        let (usage_timestamp, usage_epoch): (String, Option<i64>) = conn
            .query_row(
                "SELECT timestamp, timestamp_ms FROM usage_events WHERE id = ?1",
                params![usage_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load migrated usage event");
        assert_eq!(usage_timestamp, "2026-07-10T10:00:00+08:00");
        assert_eq!(usage_epoch, None);

        let quota_epochs: (Option<i64>, Option<i64>, Option<i64>) = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE id = ?1
                ",
                params![quota_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load migrated quota sample");
        assert_eq!(quota_epochs, (None, None, None));
    }

    #[test]
    fn epoch_backfill_pending_reads_only_completion_marker() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        conn.execute_batch(
            "
            DROP TABLE usage_events;
            DROP TABLE rate_limit_samples;
            DROP TABLE data_repair_progress;
            DROP TABLE data_repair_quarantine;
            ",
        )
        .expect("remove every repair history source");

        assert!(epoch_backfill_pending(&conn).expect("read pending marker"));
        conn.execute(
            "INSERT INTO data_repairs (repair_key, completed_at) VALUES (?1, ?2)",
            params![REPAIR_KEY, "2026-07-11T00:00:00Z"],
        )
        .expect("mark repair complete");
        assert!(!epoch_backfill_pending(&conn).expect("read completed marker"));
    }

    #[test]
    fn pre_cancelled_epoch_backfill_does_not_open_a_transaction() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        insert_usage(&conn, "2026-07-10T03:00:00Z");
        let cancelled = AtomicBool::new(true);

        let outcome = backfill_epoch_batch_cancellable(&conn, 1_000, &cancelled)
            .expect("observe pre-cancelled repair");

        assert!(outcome.is_none());
        assert!(cancelled.load(Ordering::Acquire));
        assert_repair_transaction_is_empty(&conn);
    }

    #[test]
    fn epoch_backfill_cancellation_before_usage_mutation_rolls_back_everything() {
        assert_cancel_at(EpochBackfillCancellationPoint::UsageRow, |conn| {
            insert_usage(conn, "2026-07-10T03:00:00Z");
        });
    }

    #[test]
    fn epoch_backfill_cancellation_before_quota_mutation_rolls_back_everything() {
        assert_cancel_at(EpochBackfillCancellationPoint::QuotaRow, |conn| {
            insert_usage(conn, "malformed-usage");
            insert_quota(conn, "2026-07-10T03:00:00Z");
        });
    }

    #[test]
    fn epoch_backfill_cancellation_before_completion_marker_rolls_back_everything() {
        assert_cancel_at(EpochBackfillCancellationPoint::CompletionMarker, |conn| {
            insert_usage(conn, "malformed-usage");
            insert_quota(conn, "malformed-quota");
        });
    }

    #[test]
    fn epoch_backfill_cancellation_before_commit_rolls_back_everything() {
        assert_cancel_at(EpochBackfillCancellationPoint::Commit, |conn| {
            insert_usage(conn, "malformed-usage");
            insert_quota(conn, "malformed-quota");
        });
    }

    #[test]
    fn epoch_schema_omits_large_missing_indexes() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");

        let epoch_indexes: Vec<(String, String)> = {
            let mut statement = conn
                .prepare(
                    "
                    SELECT name, sql
                    FROM sqlite_master
                    WHERE type = 'index'
                      AND sql IS NOT NULL
                      AND (
                        sql LIKE '%timestamp_ms%'
                        OR sql LIKE '%window_start_ms%'
                        OR sql LIKE '%resets_at_ms%'
                      )
                    ORDER BY name
                    ",
                )
                .expect("prepare epoch index query");
            statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
                .expect("query epoch indexes")
                .collect::<rusqlite::Result<Vec<_>>>()
                .expect("collect epoch indexes")
        };

        assert_eq!(
            epoch_indexes
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "idx_rate_limit_samples_window_ms",
                "idx_usage_events_timestamp_ms"
            ]
        );
        assert!(epoch_indexes.iter().all(|(_, sql)| {
            let normalized = sql.to_ascii_lowercase();
            normalized.contains(" where ") && !normalized.contains(" is null")
        }));
    }

    #[test]
    fn epoch_parser_orders_mixed_offsets_by_instant() {
        let earlier = parse_epoch_millis("2026-07-10T10:00:00+08:00")
            .expect("parse timestamp with positive offset");
        let later = parse_epoch_millis("2026-07-10T03:00:01Z")
            .expect("parse timestamp in UTC");

        assert!(earlier < later);
    }

    #[test]
    fn backfill_updates_at_most_requested_batch_size() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        for second in 0..4 {
            insert_usage(&conn, &format!("2026-07-10T03:00:0{second}Z"));
            insert_quota(&conn, &format!("2026-07-10T04:00:0{second}Z"));
        }

        let progress = backfill_epoch_batch(&conn, 3).expect("backfill one bounded batch");

        assert_eq!(progress.usage_rows_updated + progress.quota_rows_updated, 3);
        assert!(!progress.complete);
        let usage_migrated: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE timestamp_ms IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .expect("count migrated usage rows");
        let quota_migrated: i64 = conn
            .query_row(
                "
                SELECT COUNT(*)
                FROM rate_limit_samples
                WHERE sample_timestamp_ms IS NOT NULL
                  AND window_start_ms IS NOT NULL
                  AND resets_at_ms IS NOT NULL
                ",
                [],
                |row| row.get(0),
            )
            .expect("count migrated quota rows");
        assert_eq!(usage_migrated + quota_migrated, 3);
    }

    #[test]
    fn backfill_caps_oversized_batches_at_one_thousand_rows() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        for _ in 0..1_001 {
            insert_usage(&conn, "2026-07-10T03:00:00Z");
        }

        let progress =
            backfill_epoch_batch(&conn, 1_001).expect("backfill oversized requested batch");

        assert_eq!(progress.usage_rows_updated + progress.quota_rows_updated, 1_000);
        assert!(!progress.complete);
    }

    #[test]
    fn backfill_zero_batch_does_not_complete_unfinished_repair() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        insert_usage(&conn, "2026-07-10T03:00:00Z");

        let progress = backfill_epoch_batch(&conn, 0).expect("run zero-sized batch");

        assert_eq!(progress.usage_rows_updated, 0);
        assert_eq!(progress.quota_rows_updated, 0);
        assert!(!progress.complete);
        let completion_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("count completion markers");
        assert_eq!(completion_count, 0);
    }

    #[test]
    fn epoch_backfill_resumes_from_durable_cursors_after_restart() {
        let directory = tempdir().expect("create temporary directory");
        let db_path = directory.path().join("epoch-resume.sqlite3");
        let conn = open_initialized(&db_path);
        let first_id = insert_usage(&conn, "2026-07-10T03:00:00Z");
        let second_id = insert_usage(&conn, "2026-07-10T03:00:01Z");
        insert_usage(&conn, "2026-07-10T03:00:02Z");

        let first = backfill_epoch_batch(&conn, 1).expect("run first batch");
        assert_eq!(first.usage_rows_updated, 1);
        conn.execute(
            "UPDATE usage_events SET timestamp_ms = NULL WHERE id = ?1",
            params![first_id],
        )
        .expect("clear migrated value behind durable cursor");
        drop(conn);

        let reopened = open_initialized(&db_path);
        let second = backfill_epoch_batch(&reopened, 1).expect("resume after restart");

        assert_eq!(second.usage_rows_updated, 1);
        let first_epoch: Option<i64> = reopened
            .query_row(
                "SELECT timestamp_ms FROM usage_events WHERE id = ?1",
                params![first_id],
                |row| row.get(0),
            )
            .expect("load first epoch");
        let second_epoch: Option<i64> = reopened
            .query_row(
                "SELECT timestamp_ms FROM usage_events WHERE id = ?1",
                params![second_id],
                |row| row.get(0),
            )
            .expect("load second epoch");
        assert_eq!(first_epoch, None);
        assert!(second_epoch.is_some());
        let cursor: i64 = reopened
            .query_row(
                "
                SELECT progress_value
                FROM data_repair_progress
                WHERE repair_key = ?1 AND stream_key = 'usage_events'
                ",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("load durable usage cursor");
        assert_eq!(cursor, second_id);
    }

    #[test]
    fn malformed_epoch_is_quarantined_without_blocking_later_rows() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        let malformed_id = insert_usage(&conn, "not-a-timestamp");
        let valid_id = insert_usage(&conn, "2026-07-10T03:00:01Z");

        let progress = backfill_epoch_batch(&conn, 10).expect("backfill malformed row");

        assert!(progress.complete);
        let malformed_epoch: Option<i64> = conn
            .query_row(
                "SELECT timestamp_ms FROM usage_events WHERE id = ?1",
                params![malformed_id],
                |row| row.get(0),
            )
            .expect("load malformed epoch");
        let valid_epoch: Option<i64> = conn
            .query_row(
                "SELECT timestamp_ms FROM usage_events WHERE id = ?1",
                params![valid_id],
                |row| row.get(0),
            )
            .expect("load valid epoch");
        assert_eq!(malformed_epoch, None);
        assert_eq!(
            valid_epoch,
            Some(parse_epoch_millis("2026-07-10T03:00:01Z").expect("parse expected epoch"))
        );
        let quarantined: (String, i64, String, String) = conn
            .query_row(
                "
                SELECT table_name, row_id, column_name, raw_value
                FROM data_repair_quarantine
                WHERE repair_key = ?1
                ",
                params![REPAIR_KEY],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load quarantine row");
        assert_eq!(
            quarantined,
            (
                "usage_events".to_string(),
                malformed_id,
                "timestamp".to_string(),
                "not-a-timestamp".to_string()
            )
        );
    }

    #[test]
    fn malformed_quota_epochs_are_quarantined_per_column_without_blocking_later_rows() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        let partial_id = insert_quota_fields(
            &conn,
            "bad-sample",
            "2026-07-10T05:00:00Z",
            "2026-07-10T10:00:00Z",
        );
        let malformed_id =
            insert_quota_fields(&conn, "bad-sample-2", "bad-window", "bad-reset");
        let valid_id = insert_quota_fields(
            &conn,
            "2026-07-10T06:00:00Z",
            "2026-07-10T06:00:00Z",
            "2026-07-10T11:00:00Z",
        );

        let progress = backfill_epoch_batch(&conn, 10).expect("backfill quota rows");

        assert!(progress.complete);
        let partial_epochs: (Option<i64>, Option<i64>, Option<i64>) = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE id = ?1
                ",
                params![partial_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load partially malformed quota epochs");
        assert_eq!(partial_epochs.0, None);
        assert_eq!(
            partial_epochs.1,
            Some(parse_epoch_millis("2026-07-10T05:00:00Z").expect("parse window"))
        );
        assert_eq!(
            partial_epochs.2,
            Some(parse_epoch_millis("2026-07-10T10:00:00Z").expect("parse reset"))
        );

        let malformed_epochs: (Option<i64>, Option<i64>, Option<i64>) = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE id = ?1
                ",
                params![malformed_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load malformed quota epochs");
        assert_eq!(malformed_epochs, (None, None, None));

        let valid_epochs: (Option<i64>, Option<i64>, Option<i64>) = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE id = ?1
                ",
                params![valid_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load valid quota epochs");
        assert!(valid_epochs.0.is_some());
        assert!(valid_epochs.1.is_some());
        assert!(valid_epochs.2.is_some());

        let quarantine_rows: Vec<(i64, String, String)> = {
            let mut statement = conn
                .prepare(
                    "
                    SELECT row_id, column_name, raw_value
                    FROM data_repair_quarantine
                    WHERE repair_key = ?1 AND table_name = 'rate_limit_samples'
                    ORDER BY row_id, column_name
                    ",
                )
                .expect("prepare quota quarantine query");
            statement
                .query_map(params![REPAIR_KEY], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                })
                .expect("query quota quarantine")
                .collect::<rusqlite::Result<Vec<_>>>()
                .expect("collect quota quarantine")
        };
        assert_eq!(
            quarantine_rows,
            vec![
                (partial_id, "sample_timestamp".to_string(), "bad-sample".to_string()),
                (malformed_id, "resets_at".to_string(), "bad-reset".to_string()),
                (
                    malformed_id,
                    "sample_timestamp".to_string(),
                    "bad-sample-2".to_string()
                ),
                (
                    malformed_id,
                    "window_start".to_string(),
                    "bad-window".to_string()
                )
            ]
        );
        let quota_cursor: i64 = conn
            .query_row(
                "
                SELECT progress_value
                FROM data_repair_progress
                WHERE repair_key = ?1 AND stream_key = 'rate_limit_samples'
                ",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("load durable quota cursor");
        assert_eq!(quota_cursor, valid_id);
    }

    #[test]
    fn quota_backfill_skips_updates_when_no_epoch_value_can_change() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        let populated_id = insert_quota(&conn, "2026-07-10T05:00:00Z");
        conn.execute(
            "
            UPDATE rate_limit_samples
            SET sample_timestamp_ms = 1, window_start_ms = 2, resets_at_ms = 3
            WHERE id = ?1
            ",
            params![populated_id],
        )
        .expect("prepopulate epoch fields");
        insert_quota_fields(&conn, "bad-sample", "bad-window", "bad-reset");
        conn.execute_batch(
            "
            CREATE TRIGGER reject_noop_quota_update
            BEFORE UPDATE ON rate_limit_samples
            BEGIN
              SELECT RAISE(ABORT, 'unexpected quota update');
            END;
            ",
        )
        .expect("install quota update guard");

        let progress = backfill_epoch_batch(&conn, 10).expect("backfill no-op quota rows");

        assert!(progress.complete);
        assert_eq!(progress.quota_rows_updated, 2);
        let populated_epochs: (i64, i64, i64) = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE id = ?1
                ",
                params![populated_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load prepopulated epochs");
        assert_eq!(populated_epochs, (1, 2, 3));
        let quarantined: i64 = conn
            .query_row(
                "
                SELECT COUNT(*)
                FROM data_repair_quarantine
                WHERE repair_key = ?1 AND table_name = 'rate_limit_samples'
                ",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("count malformed quota fields");
        assert_eq!(quarantined, 3);
    }

    #[test]
    fn epoch_backfill_rolls_back_rows_quarantine_cursors_and_completion_together() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        let malformed_id = insert_usage(&conn, "bad-timestamp");
        let valid_id = insert_usage(&conn, "2026-07-10T03:00:01Z");
        conn.execute_batch(
            "
            CREATE TRIGGER fail_epoch_completion
            BEFORE INSERT ON data_repairs
            WHEN NEW.repair_key = 'epoch_timestamp_backfill_v1'
            BEGIN
              SELECT RAISE(ABORT, 'injected completion failure');
            END;
            ",
        )
        .expect("install completion failure trigger");

        let error = backfill_epoch_batch(&conn, 10).expect_err("inject transaction failure");

        assert!(error.to_string().contains("injected completion failure"));
        for row_id in [malformed_id, valid_id] {
            let epoch: Option<i64> = conn
                .query_row(
                    "SELECT timestamp_ms FROM usage_events WHERE id = ?1",
                    params![row_id],
                    |row| row.get(0),
                )
                .expect("load rolled-back usage epoch");
            assert_eq!(epoch, None);
        }
        let quarantine_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM data_repair_quarantine", [], |row| {
                row.get(0)
            })
            .expect("count rolled-back quarantine rows");
        assert_eq!(quarantine_count, 0);
        let cursor_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM data_repair_progress", [], |row| {
                row.get(0)
            })
            .expect("count rolled-back cursors");
        assert_eq!(cursor_count, 0);
        let completion_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("count rolled-back completion markers");
        assert_eq!(completion_count, 0);
    }

    #[test]
    fn epoch_backfill_completion_is_idempotent() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init_db(&conn).expect("initialize database");
        insert_usage(&conn, "2026-07-10T03:00:00Z");
        insert_quota(&conn, "2026-07-10T04:00:00Z");

        let first = backfill_epoch_batch(&conn, 10).expect("complete backfill");
        assert!(first.complete);
        let completed_at: String = conn
            .query_row(
                "SELECT completed_at FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("load completion time");
        let cursor_snapshot: Vec<(String, i64)> = {
            let mut statement = conn
                .prepare(
                    "
                    SELECT stream_key, progress_value
                    FROM data_repair_progress
                    WHERE repair_key = ?1
                    ORDER BY stream_key
                    ",
                )
                .expect("prepare cursor snapshot");
            statement
                .query_map(params![REPAIR_KEY], |row| Ok((row.get(0)?, row.get(1)?)))
                .expect("query cursor snapshot")
                .collect::<rusqlite::Result<Vec<_>>>()
                .expect("collect cursor snapshot")
        };

        let second = backfill_epoch_batch(&conn, 10).expect("rerun completed backfill");

        assert!(second.complete);
        assert_eq!(second.usage_rows_updated, 0);
        assert_eq!(second.quota_rows_updated, 0);
        let completion_rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("count completion rows");
        assert_eq!(completion_rows, 1);
        let rerun_completed_at: String = conn
            .query_row(
                "SELECT completed_at FROM data_repairs WHERE repair_key = ?1",
                params![REPAIR_KEY],
                |row| row.get(0),
            )
            .expect("reload completion time");
        assert_eq!(rerun_completed_at, completed_at);
        let rerun_cursor_snapshot: Vec<(String, i64)> = {
            let mut statement = conn
                .prepare(
                    "
                    SELECT stream_key, progress_value
                    FROM data_repair_progress
                    WHERE repair_key = ?1
                    ORDER BY stream_key
                    ",
                )
                .expect("prepare rerun cursor snapshot");
            statement
                .query_map(params![REPAIR_KEY], |row| Ok((row.get(0)?, row.get(1)?)))
                .expect("query rerun cursor snapshot")
                .collect::<rusqlite::Result<Vec<_>>>()
                .expect("collect rerun cursor snapshot")
        };
        assert_eq!(rerun_cursor_snapshot, cursor_snapshot);
    }

    #[test]
    fn integrity_check_is_ok_after_epoch_migration() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        create_legacy_epoch_tables(&conn);
        insert_usage(&conn, "2026-07-10T03:00:00Z");
        insert_usage(&conn, "malformed");
        insert_quota(&conn, "2026-07-10T04:00:00Z");
        init_db(&conn).expect("migrate legacy database");

        let mut complete = false;
        for _ in 0..10 {
            complete = backfill_epoch_batch(&conn, 1)
                .expect("run bounded migration batch")
                .complete;
            if complete {
                break;
            }
        }
        assert!(complete);
        let integrity: String = conn
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))
            .expect("run integrity check");
        assert_eq!(integrity, "ok");
    }
}

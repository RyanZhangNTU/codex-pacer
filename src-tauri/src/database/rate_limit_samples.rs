use std::io::{Error as IoError, ErrorKind};

use rusqlite::{params, Connection, OptionalExtension};

use crate::models::{LiveRateLimitSnapshot, RateLimitSampleRecord, RateLimitWindowSnapshot};

use super::{now_utc_string, parse_epoch_millis};

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedRateLimitSample {
    source_kind: String,
    source_session_id: String,
    bucket: String,
    sample_timestamp: String,
    sample_timestamp_ms: i64,
    limit_id: String,
    limit_name: String,
    plan_type: String,
    window_start: String,
    window_start_ms: i64,
    resets_at: String,
    resets_at_ms: i64,
    used_percent: i64,
    remaining_percent: i64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RateLimitWriteStats {
    pub observed: usize,
    pub historical_inserted: usize,
    pub latest_updated: usize,
}

pub fn replace_session_rate_limit_samples(
    conn: &Connection,
    session_id: &str,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<RateLimitWriteStats> {
    let mut parsed = parse_rate_limit_samples(samples)?;
    normalize_session_owner(&mut parsed, session_id);
    let compacted = compact_complete_session_history(&parsed);
    with_rate_limit_savepoint(conn, |conn| {
        let mut stats = RateLimitWriteStats {
            observed: parsed.len(),
            ..RateLimitWriteStats::default()
        };
        if load_session_history(conn, session_id)? != compacted {
            conn.execute(
                "DELETE FROM rate_limit_samples WHERE source_kind = 'session' AND source_session_id = ?1",
                params![session_id],
            )?;
            stats.historical_inserted = insert_parsed_rate_limit_samples(conn, &compacted)?;
        }
        let buckets = compacted
            .iter()
            .map(|sample| sample.bucket.as_str())
            .collect::<std::collections::HashSet<_>>();
        for bucket in ["five_hour", "seven_day"] {
            if !buckets.contains(bucket) {
                conn.execute(
                    "DELETE FROM latest_rate_limits WHERE source_kind = 'session' AND source_session_id = ?1 AND bucket = ?2",
                    params![session_id, bucket],
                )?;
            }
        }
        for sample in newest_per_owner_bucket(&parsed) {
            stats.latest_updated += upsert_latest(conn, sample)?;
        }
        Ok(stats)
    })
}

#[allow(dead_code)]
pub fn append_session_rate_limit_samples(
    conn: &Connection,
    session_id: &str,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<RateLimitWriteStats> {
    let mut parsed = parse_rate_limit_samples(samples)?;
    normalize_session_owner(&mut parsed, session_id);
    with_rate_limit_savepoint(conn, |conn| append_parsed_samples(conn, &parsed))
}

#[cfg(test)]
pub fn insert_rate_limit_samples(
    conn: &Connection,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
    let parsed = parse_rate_limit_samples(samples)?;
    with_rate_limit_savepoint(conn, |conn| {
        insert_parsed_rate_limit_samples(conn, &parsed).map(|_| ())
    })
}

fn parse_rate_limit_samples(
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<Vec<ParsedRateLimitSample>> {
    let mut parsed = Vec::with_capacity(samples.len());
    for sample in samples {
        parsed.push(ParsedRateLimitSample {
            source_kind: sample.source_kind.clone(),
            source_session_id: sample.source_session_id.clone().unwrap_or_default(),
            bucket: sample.bucket.clone(),
            sample_timestamp: sample.sample_timestamp.clone(),
            sample_timestamp_ms: parse_epoch_field("sample_timestamp", &sample.sample_timestamp)?,
            limit_id: sample.limit_id.clone().unwrap_or_default(),
            limit_name: sample.limit_name.clone().unwrap_or_default(),
            plan_type: sample.plan_type.clone().unwrap_or_default(),
            window_start: sample.window_start.clone(),
            window_start_ms: parse_epoch_field("window_start", &sample.window_start)?,
            resets_at: sample.resets_at.clone(),
            resets_at_ms: parse_epoch_field("resets_at", &sample.resets_at)?,
            used_percent: sample.used_percent.clamp(0, 100),
            remaining_percent: sample.remaining_percent.clamp(0, 100),
        });
    }
    Ok(parsed)
}

fn normalize_session_owner(samples: &mut [ParsedRateLimitSample], session_id: &str) {
    for sample in samples {
        sample.source_kind = "session".to_string();
        sample.source_session_id = session_id.to_string();
    }
}

fn parse_epoch_field(field_name: &str, value: &str) -> rusqlite::Result<i64> {
    parse_epoch_millis(value).map_err(|error| {
        rusqlite::Error::ToSqlConversionFailure(Box::new(IoError::new(
            ErrorKind::InvalidData,
            format!("Invalid rate limit {field_name} {value:?}: {error}"),
        )))
    })
}

fn insert_parsed_rate_limit_samples(
    conn: &Connection,
    samples: &[ParsedRateLimitSample],
) -> rusqlite::Result<usize> {
    if samples.is_empty() {
        return Ok(0);
    }
    let created_at = now_utc_string();
    let mut stmt = conn.prepare(
        "
    INSERT OR IGNORE INTO rate_limit_samples (
      source_kind, source_session_id, bucket, sample_timestamp, sample_timestamp_ms,
      limit_id, limit_name, plan_type, window_start, window_start_ms,
      resets_at, resets_at_ms, used_percent, remaining_percent, created_at
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
    ",
    )?;

    let mut inserted = 0;
    for sample in samples {
        inserted += stmt.execute(params![
            sample.source_kind,
            sample.source_session_id,
            sample.bucket,
            sample.sample_timestamp,
            sample.sample_timestamp_ms,
            sample.limit_id,
            sample.limit_name,
            sample.plan_type,
            sample.window_start,
            sample.window_start_ms,
            sample.resets_at,
            sample.resets_at_ms,
            sample.used_percent,
            sample.remaining_percent,
            created_at,
        ])?;
    }

    Ok(inserted)
}

pub fn insert_live_rate_limit_snapshot(
    conn: &Connection,
    snapshot: &LiveRateLimitSnapshot,
) -> rusqlite::Result<RateLimitWriteStats> {
    let mut samples = Vec::new();
    for (bucket, window) in [
        ("five_hour", snapshot.primary.as_ref()),
        ("seven_day", snapshot.secondary.as_ref()),
    ] {
        let Some(window) = window else {
            continue;
        };
        let (Some(window_start), Some(resets_at)) =
            (window.window_start.clone(), window.resets_at.clone())
        else {
            continue;
        };
        samples.push(RateLimitSampleRecord {
            source_kind: "live".to_string(),
            source_session_id: None,
            bucket: bucket.to_string(),
            sample_timestamp: snapshot.fetched_at.clone(),
            limit_id: snapshot.limit_id.clone(),
            limit_name: snapshot.limit_name.clone(),
            plan_type: snapshot.plan_type.clone(),
            window_start,
            resets_at,
            used_percent: window.used_percent,
            remaining_percent: window.remaining_percent,
        });
    }
    let parsed = parse_rate_limit_samples(&samples)?;
    with_rate_limit_savepoint(conn, |conn| append_parsed_samples(conn, &parsed))
}

fn with_rate_limit_savepoint<T>(
    conn: &Connection,
    operation: impl FnOnce(&Connection) -> rusqlite::Result<T>,
) -> rusqlite::Result<T> {
    conn.execute_batch("SAVEPOINT codex_pacer_rate_limit_write")?;
    match operation(conn) {
        Ok(value) => {
            conn.execute_batch("RELEASE SAVEPOINT codex_pacer_rate_limit_write")?;
            Ok(value)
        }
        Err(error) => {
            let _ = conn.execute_batch(
                "ROLLBACK TO SAVEPOINT codex_pacer_rate_limit_write; RELEASE SAVEPOINT codex_pacer_rate_limit_write",
            );
            Err(error)
        }
    }
}

fn same_window(left: &ParsedRateLimitSample, right: &ParsedRateLimitSample) -> bool {
    left.window_start_ms == right.window_start_ms && left.resets_at_ms == right.resets_at_ms
}

fn same_value(left: &ParsedRateLimitSample, right: &ParsedRateLimitSample) -> bool {
    left.used_percent == right.used_percent && left.remaining_percent == right.remaining_percent
}

fn same_history_point(left: &ParsedRateLimitSample, right: &ParsedRateLimitSample) -> bool {
    left.source_kind == right.source_kind
        && left.source_session_id == right.source_session_id
        && left.bucket == right.bucket
        && left.sample_timestamp_ms == right.sample_timestamp_ms
        && left.limit_id == right.limit_id
        && left.limit_name == right.limit_name
        && left.plan_type == right.plan_type
        && same_window(left, right)
        && same_value(left, right)
}

fn grouped_sorted(samples: &[ParsedRateLimitSample]) -> Vec<Vec<ParsedRateLimitSample>> {
    let mut ordered = samples.to_vec();
    ordered.sort_by(|left, right| {
        (
            &left.source_kind,
            &left.source_session_id,
            &left.bucket,
            left.sample_timestamp_ms,
        )
            .cmp(&(
                &right.source_kind,
                &right.source_session_id,
                &right.bucket,
                right.sample_timestamp_ms,
            ))
    });
    let mut groups: Vec<Vec<ParsedRateLimitSample>> = Vec::new();
    for sample in ordered {
        if groups
            .last()
            .and_then(|group| group.first())
            .is_some_and(|first| {
                first.source_kind == sample.source_kind
                    && first.source_session_id == sample.source_session_id
                    && first.bucket == sample.bucket
            })
        {
            groups.last_mut().expect("group exists").push(sample);
        } else {
            groups.push(vec![sample]);
        }
    }
    groups
}

fn compact_complete_session_history(
    samples: &[ParsedRateLimitSample],
) -> Vec<ParsedRateLimitSample> {
    let mut compacted = Vec::new();
    for group in grouped_sorted(samples) {
        let Some(first) = group.first() else { continue };
        compacted.push(first.clone());
        let mut previous = first;
        for sample in group.iter().skip(1) {
            if !same_window(previous, sample) || !same_value(previous, sample) {
                compacted.push(sample.clone());
            }
            previous = sample;
        }
        if let Some(last) = group.last() {
            if compacted
                .last()
                .map_or(true, |point| !same_history_point(point, last))
            {
                compacted.push(last.clone());
            }
        }
    }
    compacted
}

fn newest_per_owner_bucket(samples: &[ParsedRateLimitSample]) -> Vec<&ParsedRateLimitSample> {
    grouped_sorted(samples)
        .iter()
        .filter_map(|group| group.last())
        .map(|sample| {
            samples
                .iter()
                .find(|candidate| same_history_point(candidate, sample))
                .expect("newest sample belongs to input")
        })
        .collect()
}

fn append_parsed_samples(
    conn: &Connection,
    samples: &[ParsedRateLimitSample],
) -> rusqlite::Result<RateLimitWriteStats> {
    let mut stats = RateLimitWriteStats {
        observed: samples.len(),
        ..RateLimitWriteStats::default()
    };
    for group in grouped_sorted(samples) {
        let Some(first) = group.first() else { continue };
        let mut previous = load_latest_owner_bucket(
            conn,
            &first.source_kind,
            &first.source_session_id,
            &first.bucket,
        )?;
        let mut history = Vec::new();
        for sample in &group {
            if previous
                .as_ref()
                .is_some_and(|current| sample.sample_timestamp_ms < current.sample_timestamp_ms)
            {
                continue;
            }
            match previous.as_ref() {
                None => history.push(sample.clone()),
                Some(current) if !same_window(current, sample) => {
                    history.push(current.clone());
                    history.push(sample.clone());
                }
                Some(current) if !same_value(current, sample) => history.push(sample.clone()),
                Some(_) => {}
            }
            previous = Some(sample.clone());
        }
        history.dedup_by(|left, right| same_history_point(left, right));
        stats.historical_inserted += insert_parsed_rate_limit_samples(conn, &history)?;
        if let Some(latest) = previous.as_ref() {
            stats.latest_updated += upsert_latest(conn, latest)?;
        }
    }
    Ok(stats)
}

fn upsert_latest(conn: &Connection, sample: &ParsedRateLimitSample) -> rusqlite::Result<usize> {
    conn.execute(
        "
        INSERT INTO latest_rate_limits (
          source_kind, source_session_id, bucket, sample_timestamp, sample_timestamp_ms,
          limit_id, limit_name, plan_type, window_start, window_start_ms,
          resets_at, resets_at_ms, used_percent, remaining_percent, updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        ON CONFLICT(source_kind, source_session_id, bucket) DO UPDATE SET
          sample_timestamp = excluded.sample_timestamp,
          sample_timestamp_ms = excluded.sample_timestamp_ms,
          limit_id = excluded.limit_id,
          limit_name = excluded.limit_name,
          plan_type = excluded.plan_type,
          window_start = excluded.window_start,
          window_start_ms = excluded.window_start_ms,
          resets_at = excluded.resets_at,
          resets_at_ms = excluded.resets_at_ms,
          used_percent = excluded.used_percent,
          remaining_percent = excluded.remaining_percent,
          updated_at = excluded.updated_at
        WHERE excluded.sample_timestamp_ms >= latest_rate_limits.sample_timestamp_ms
          AND (
            excluded.sample_timestamp_ms <> latest_rate_limits.sample_timestamp_ms
            OR excluded.limit_id <> latest_rate_limits.limit_id
            OR excluded.limit_name <> latest_rate_limits.limit_name
            OR excluded.plan_type <> latest_rate_limits.plan_type
            OR excluded.window_start_ms <> latest_rate_limits.window_start_ms
            OR excluded.resets_at_ms <> latest_rate_limits.resets_at_ms
            OR excluded.used_percent <> latest_rate_limits.used_percent
            OR excluded.remaining_percent <> latest_rate_limits.remaining_percent
          )
        ",
        params![
            sample.source_kind,
            sample.source_session_id,
            sample.bucket,
            sample.sample_timestamp,
            sample.sample_timestamp_ms,
            sample.limit_id,
            sample.limit_name,
            sample.plan_type,
            sample.window_start,
            sample.window_start_ms,
            sample.resets_at,
            sample.resets_at_ms,
            sample.used_percent,
            sample.remaining_percent,
            now_utc_string(),
        ],
    )
}

fn load_latest_owner_bucket(
    conn: &Connection,
    source_kind: &str,
    source_session_id: &str,
    bucket: &str,
) -> rusqlite::Result<Option<ParsedRateLimitSample>> {
    conn.query_row(
        "
        SELECT source_kind, source_session_id, bucket, sample_timestamp, sample_timestamp_ms,
               limit_id, limit_name, plan_type, window_start, window_start_ms,
               resets_at, resets_at_ms, used_percent, remaining_percent
        FROM latest_rate_limits
        WHERE source_kind = ?1 AND source_session_id = ?2 AND bucket = ?3
        ",
        params![source_kind, source_session_id, bucket],
        parsed_sample_from_row,
    )
    .optional()
}

fn parsed_sample_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ParsedRateLimitSample> {
    Ok(ParsedRateLimitSample {
        source_kind: row.get(0)?,
        source_session_id: row.get(1)?,
        bucket: row.get(2)?,
        sample_timestamp: row.get(3)?,
        sample_timestamp_ms: row.get(4)?,
        limit_id: row.get(5)?,
        limit_name: row.get(6)?,
        plan_type: row.get(7)?,
        window_start: row.get(8)?,
        window_start_ms: row.get(9)?,
        resets_at: row.get(10)?,
        resets_at_ms: row.get(11)?,
        used_percent: row.get(12)?,
        remaining_percent: row.get(13)?,
    })
}

fn load_session_history(
    conn: &Connection,
    session_id: &str,
) -> rusqlite::Result<Vec<ParsedRateLimitSample>> {
    let mut stmt = conn.prepare(
        "
        SELECT source_kind, source_session_id, bucket, sample_timestamp, sample_timestamp_ms,
               limit_id, limit_name, plan_type, window_start, window_start_ms,
               resets_at, resets_at_ms, used_percent, remaining_percent
        FROM rate_limit_samples
        WHERE source_kind = 'session' AND source_session_id = ?1
        ORDER BY bucket, sample_timestamp_ms, id
        ",
    )?;
    let rows = stmt.query_map(params![session_id], |row| {
        Ok(ParsedRateLimitSample {
            source_kind: row.get(0)?,
            source_session_id: row.get(1)?,
            bucket: row.get(2)?,
            sample_timestamp: row.get(3)?,
            sample_timestamp_ms: row.get::<_, Option<i64>>(4)?.unwrap_or(i64::MIN),
            limit_id: row.get(5)?,
            limit_name: row.get(6)?,
            plan_type: row.get(7)?,
            window_start: row.get(8)?,
            window_start_ms: row.get::<_, Option<i64>>(9)?.unwrap_or(i64::MIN),
            resets_at: row.get(10)?,
            resets_at_ms: row.get::<_, Option<i64>>(11)?.unwrap_or(i64::MIN),
            used_percent: row.get(12)?,
            remaining_percent: row.get(13)?,
        })
    })?;
    rows.collect()
}

#[derive(Clone)]
struct LatestWindow {
    owner: (String, String),
    sample: ParsedRateLimitSample,
}

fn load_latest_window(
    conn: &Connection,
    bucket: &str,
    source_kind: Option<&str>,
) -> rusqlite::Result<Option<LatestWindow>> {
    conn.query_row(
        "
        SELECT source_kind, source_session_id, bucket, sample_timestamp, sample_timestamp_ms,
               limit_id, limit_name, plan_type, window_start, window_start_ms,
               resets_at, resets_at_ms, used_percent, remaining_percent
        FROM latest_rate_limits
        WHERE bucket = ?1 AND (?2 IS NULL OR source_kind = ?2)
        ORDER BY sample_timestamp_ms DESC, rowid DESC
        LIMIT 1
        ",
        params![bucket, source_kind],
        |row| {
            let sample = parsed_sample_from_row(row)?;
            Ok(LatestWindow {
                owner: (sample.source_kind.clone(), sample.source_session_id.clone()),
                sample,
            })
        },
    )
    .optional()
}

pub fn load_latest_rate_limits(
    conn: &Connection,
    source_kind: Option<&str>,
) -> rusqlite::Result<Option<LiveRateLimitSnapshot>> {
    let mut primary = load_latest_window(conn, "five_hour", source_kind)?;
    let mut secondary = load_latest_window(conn, "seven_day", source_kind)?;
    let newest = match (primary.as_ref(), secondary.as_ref()) {
        (Some(left), Some(right)) => {
            if right.sample.sample_timestamp_ms > left.sample.sample_timestamp_ms {
                right
            } else {
                left
            }
        }
        (Some(left), None) => left,
        (None, Some(right)) => right,
        (None, None) => return Ok(None),
    };
    let newest_owner = newest.owner.clone();
    let newest_timestamp = newest.sample.sample_timestamp_ms;
    if primary.as_ref().is_some_and(|window| {
        window.owner != newest_owner || window.sample.sample_timestamp_ms != newest_timestamp
    }) {
        primary = None;
    }
    if secondary.as_ref().is_some_and(|window| {
        window.owner != newest_owner || window.sample.sample_timestamp_ms != newest_timestamp
    }) {
        secondary = None;
    }
    let reference = primary
        .as_ref()
        .or(secondary.as_ref())
        .expect("latest window exists");
    let limit_id =
        (!reference.sample.limit_id.is_empty()).then(|| reference.sample.limit_id.clone());
    let limit_name =
        (!reference.sample.limit_name.is_empty()).then(|| reference.sample.limit_name.clone());
    let plan_type =
        (!reference.sample.plan_type.is_empty()).then(|| reference.sample.plan_type.clone());
    let fetched_at = reference.sample.sample_timestamp.clone();
    let window_snapshot = |window: LatestWindow| RateLimitWindowSnapshot {
        used_percent: window.sample.used_percent,
        remaining_percent: window.sample.remaining_percent,
        window_duration_mins: Some(
            (window.sample.resets_at_ms - window.sample.window_start_ms)
                .div_euclid(60_000)
                .max(0),
        ),
        resets_at: Some(window.sample.resets_at),
        window_start: Some(window.sample.window_start),
    };
    Ok(Some(LiveRateLimitSnapshot {
        limit_id,
        limit_name,
        plan_type,
        primary: primary.map(window_snapshot),
        secondary: secondary.map(window_snapshot),
        fetched_at,
    }))
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use crate::database::{init_db, parse_epoch_millis};
    use crate::models::{LiveRateLimitSnapshot, RateLimitSampleRecord, RateLimitWindowSnapshot};

    use super::{
        append_session_rate_limit_samples, insert_live_rate_limit_snapshot,
        insert_rate_limit_samples, load_latest_rate_limits, replace_session_rate_limit_samples,
    };

    fn session_sample(
        sample_timestamp: &str,
        window_start: &str,
        resets_at: &str,
    ) -> RateLimitSampleRecord {
        RateLimitSampleRecord {
            source_kind: "session".to_string(),
            source_session_id: Some("session-1".to_string()),
            bucket: "five_hour".to_string(),
            sample_timestamp: sample_timestamp.to_string(),
            limit_id: Some("codex".to_string()),
            limit_name: Some("Codex".to_string()),
            plan_type: Some("pro".to_string()),
            window_start: window_start.to_string(),
            resets_at: resets_at.to_string(),
            used_percent: 25,
            remaining_percent: 75,
        }
    }

    fn live_snapshot(
        fetched_at: &str,
        primary_used: i64,
        secondary_used: i64,
        primary_window_start: &str,
        primary_resets_at: &str,
    ) -> LiveRateLimitSnapshot {
        LiveRateLimitSnapshot {
            limit_id: Some("codex".to_string()),
            limit_name: Some("Codex".to_string()),
            plan_type: Some("pro".to_string()),
            primary: Some(RateLimitWindowSnapshot {
                used_percent: primary_used,
                remaining_percent: 100 - primary_used,
                window_duration_mins: Some(300),
                window_start: Some(primary_window_start.to_string()),
                resets_at: Some(primary_resets_at.to_string()),
            }),
            secondary: Some(RateLimitWindowSnapshot {
                used_percent: secondary_used,
                remaining_percent: 100 - secondary_used,
                window_duration_mins: Some(10_080),
                window_start: Some("2026-07-06T00:00:00Z".to_string()),
                resets_at: Some("2026-07-13T00:00:00Z".to_string()),
            }),
            fetched_at: fetched_at.to_string(),
        }
    }

    #[test]
    fn repeated_live_percent_updates_latest_without_growing_history() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let first = live_snapshot(
            "2026-07-10T10:00:00Z",
            40,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        let repeated = live_snapshot(
            "2026-07-10T10:05:00Z",
            40,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );

        let first_stats = insert_live_rate_limit_snapshot(&conn, &first).expect("insert first");
        let repeated_stats =
            insert_live_rate_limit_snapshot(&conn, &repeated).expect("insert repeated");

        assert_eq!(first_stats.historical_inserted, 2);
        assert_eq!(first_stats.latest_updated, 2);
        assert_eq!(repeated_stats.historical_inserted, 0);
        assert_eq!(repeated_stats.latest_updated, 2);
        let history_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rate_limit_samples", [], |row| {
                row.get(0)
            })
            .expect("count history");
        let latest_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM latest_rate_limits", [], |row| {
                row.get(0)
            })
            .expect("count latest");
        assert_eq!(history_count, 2);
        assert_eq!(latest_count, 2);
        assert_eq!(
            load_latest_rate_limits(&conn, Some("live"))
                .expect("load latest")
                .expect("latest snapshot")
                .fetched_at,
            repeated.fetched_at
        );
    }

    #[test]
    fn changed_percent_adds_one_history_point() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let first = live_snapshot(
            "2026-07-10T10:00:00Z",
            40,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        let changed = live_snapshot(
            "2026-07-10T10:05:00Z",
            41,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        insert_live_rate_limit_snapshot(&conn, &first).expect("insert first");

        let stats = insert_live_rate_limit_snapshot(&conn, &changed).expect("insert changed");

        assert_eq!(stats.historical_inserted, 1);
        assert_eq!(stats.latest_updated, 2);
        let history_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rate_limit_samples", [], |row| {
                row.get(0)
            })
            .expect("count history");
        assert_eq!(history_count, 3);
    }

    #[test]
    fn new_window_keeps_previous_close_and_new_start() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let mut first = live_snapshot(
            "2026-07-10T10:00:00Z",
            40,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        first.secondary = None;
        let mut close = first.clone();
        close.fetched_at = "2026-07-10T12:59:00Z".to_string();
        let mut next = live_snapshot(
            "2026-07-10T13:00:00Z",
            0,
            20,
            "2026-07-10T13:00:00Z",
            "2026-07-10T18:00:00Z",
        );
        next.secondary = None;
        insert_live_rate_limit_snapshot(&conn, &first).expect("insert first");
        insert_live_rate_limit_snapshot(&conn, &close).expect("observe close");

        let stats = insert_live_rate_limit_snapshot(&conn, &next).expect("insert next window");

        assert_eq!(stats.historical_inserted, 2);
        let timestamps = conn
            .prepare(
                "SELECT sample_timestamp FROM rate_limit_samples ORDER BY sample_timestamp_ms, id",
            )
            .expect("prepare timestamps")
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query timestamps")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("collect timestamps");
        assert_eq!(
            timestamps,
            vec![
                "2026-07-10T10:00:00Z",
                "2026-07-10T12:59:00Z",
                "2026-07-10T13:00:00Z"
            ]
        );
    }

    #[test]
    fn session_batch_keeps_first_change_and_last() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let mut samples = vec![
            session_sample(
                "2026-07-10T10:00:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
            session_sample(
                "2026-07-10T10:01:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
            session_sample(
                "2026-07-10T10:02:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
            session_sample(
                "2026-07-10T10:03:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
        ];
        samples[2].used_percent = 26;
        samples[2].remaining_percent = 74;
        samples[3].used_percent = 26;
        samples[3].remaining_percent = 74;

        let stats = replace_session_rate_limit_samples(&conn, "session-1", &samples)
            .expect("replace session samples");

        assert_eq!(stats.observed, 4);
        assert_eq!(stats.historical_inserted, 3);
        let timestamps = conn
            .prepare(
                "SELECT sample_timestamp FROM rate_limit_samples ORDER BY sample_timestamp_ms, id",
            )
            .expect("prepare timestamps")
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query timestamps")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("collect timestamps");
        assert_eq!(
            timestamps,
            vec![
                "2026-07-10T10:00:00Z",
                "2026-07-10T10:02:00Z",
                "2026-07-10T10:03:00Z"
            ]
        );
    }

    #[test]
    fn repeated_session_replace_performs_zero_semantic_writes() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let samples = vec![
            session_sample(
                "2026-07-10T10:00:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
            session_sample(
                "2026-07-10T10:01:00Z",
                "2026-07-10T08:00:00Z",
                "2026-07-10T13:00:00Z",
            ),
        ];
        replace_session_rate_limit_samples(&conn, "session-1", &samples)
            .expect("insert session samples");
        let changes_before = conn.total_changes();

        let stats = replace_session_rate_limit_samples(&conn, "session-1", &samples)
            .expect("repeat session samples");

        assert_eq!(stats.historical_inserted, 0);
        assert_eq!(stats.latest_updated, 0);
        assert_eq!(conn.total_changes(), changes_before);
    }

    #[test]
    fn latest_quota_uses_epoch_order() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let newer = live_snapshot(
            "2026-07-10T03:00:01Z",
            41,
            20,
            "2026-07-10T02:00:00Z",
            "2026-07-10T07:00:00Z",
        );
        let older = live_snapshot(
            "2026-07-10T10:00:00+08:00",
            40,
            20,
            "2026-07-10T09:00:00+08:00",
            "2026-07-10T14:00:00+08:00",
        );
        insert_live_rate_limit_snapshot(&conn, &newer).expect("insert newer");
        insert_live_rate_limit_snapshot(&conn, &older).expect("insert older later");

        let latest = load_latest_rate_limits(&conn, Some("live"))
            .expect("load latest")
            .expect("latest snapshot");

        assert_eq!(latest.fetched_at, newer.fetched_at);
        assert_eq!(latest.primary.map(|window| window.used_percent), Some(41));
    }

    #[test]
    fn latest_lookup_does_not_scan_history() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let snapshot = live_snapshot(
            "2026-07-10T10:00:00Z",
            40,
            20,
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        insert_live_rate_limit_snapshot(&conn, &snapshot).expect("insert snapshot");
        conn.execute_batch("DROP TABLE rate_limit_samples")
            .expect("drop history table");

        let latest = load_latest_rate_limits(&conn, Some("live"))
            .expect("load latest without history")
            .expect("latest snapshot");

        assert_eq!(latest.fetched_at, snapshot.fetched_at);
    }

    #[test]
    fn session_latest_rows_are_owned_independently() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let first = session_sample(
            "2026-07-10T10:00:00Z",
            "2026-07-10T08:00:00Z",
            "2026-07-10T13:00:00Z",
        );
        let mut second = first.clone();
        second.source_session_id = Some("session-2".to_string());
        second.sample_timestamp = "2026-07-10T10:01:00Z".to_string();
        append_session_rate_limit_samples(&conn, "session-1", &[first])
            .expect("append first session");
        append_session_rate_limit_samples(&conn, "session-2", &[second])
            .expect("append second session");

        let owner_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM latest_rate_limits WHERE source_kind = 'session' AND bucket = 'five_hour'",
                [],
                |row| row.get(0),
            )
            .expect("count owners");
        assert_eq!(owner_count, 2);
    }

    #[test]
    fn session_replace_plan_uses_owner_index() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");

        let details = conn
            .prepare(
                "EXPLAIN QUERY PLAN DELETE FROM rate_limit_samples WHERE source_kind = 'session' AND source_session_id = ?1",
            )
            .expect("prepare delete plan")
            .query_map(["session-1"], |row| row.get::<_, String>(3))
            .expect("query delete plan")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("collect delete plan");

        assert!(
            details
                .iter()
                .any(|detail| detail.contains("idx_rate_limit_samples_owner")),
            "owner delete must not scan all quota history: {details:?}"
        );
    }

    #[test]
    fn session_quota_write_populates_all_epoch_fields() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let sample = session_sample(
            "2026-07-10T10:00:00+08:00",
            "2026-07-10T09:00:00+08:00",
            "2026-07-10T14:00:00+08:00",
        );

        replace_session_rate_limit_samples(&conn, "session-1", &[sample.clone()])
            .expect("replace session quota samples");

        let epochs = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                ",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .expect("load quota epochs");
        assert_eq!(
            epochs,
            (
                parse_epoch_millis(&sample.sample_timestamp).expect("parse sample timestamp"),
                parse_epoch_millis(&sample.window_start).expect("parse window start"),
                parse_epoch_millis(&sample.resets_at).expect("parse resets at"),
            )
        );
    }

    #[test]
    fn live_quota_write_populates_all_epoch_fields() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let snapshot = LiveRateLimitSnapshot {
            limit_id: Some("codex".to_string()),
            limit_name: Some("Codex".to_string()),
            plan_type: Some("pro".to_string()),
            primary: Some(RateLimitWindowSnapshot {
                used_percent: 10,
                remaining_percent: 90,
                window_duration_mins: Some(300),
                window_start: Some("2026-07-10T02:00:00Z".to_string()),
                resets_at: Some("2026-07-10T07:00:00Z".to_string()),
            }),
            secondary: None,
            fetched_at: "2026-07-10T10:00:00+08:00".to_string(),
        };

        insert_live_rate_limit_snapshot(&conn, &snapshot).expect("insert live quota snapshot");

        let epochs = conn
            .query_row(
                "
                SELECT sample_timestamp_ms, window_start_ms, resets_at_ms
                FROM rate_limit_samples
                WHERE source_kind = 'live'
                ",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .expect("load live quota epochs");
        assert_eq!(
            epochs,
            (
                parse_epoch_millis(&snapshot.fetched_at).expect("parse fetched at"),
                parse_epoch_millis("2026-07-10T02:00:00Z").expect("parse window start"),
                parse_epoch_millis("2026-07-10T07:00:00Z").expect("parse resets at"),
            )
        );
    }

    #[test]
    fn malformed_quota_append_writes_nothing() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let samples = [
            session_sample(
                "2026-07-10T02:00:00Z",
                "2026-07-10T02:00:00Z",
                "2026-07-10T07:00:00Z",
            ),
            session_sample(
                "2026-07-10T02:01:00Z",
                "invalid-window-start",
                "2026-07-10T07:01:00Z",
            ),
        ];

        let result = insert_rate_limit_samples(&conn, &samples);

        assert!(result.is_err());
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rate_limit_samples", [], |row| {
                row.get(0)
            })
            .expect("count quota samples");
        assert_eq!(count, 0);
    }

    #[test]
    fn malformed_quota_replace_preserves_existing_session_rows() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let existing = session_sample(
            "2026-07-10T02:00:00Z",
            "2026-07-10T02:00:00Z",
            "2026-07-10T07:00:00Z",
        );
        replace_session_rate_limit_samples(&conn, "session-1", &[existing.clone()])
            .expect("insert existing sample");
        let malformed = session_sample(
            "invalid-sample-timestamp",
            "2026-07-10T02:01:00Z",
            "2026-07-10T07:01:00Z",
        );

        let result = replace_session_rate_limit_samples(&conn, "session-1", &[malformed]);

        assert!(result.is_err());
        let persisted = conn
            .query_row(
                "
                SELECT COUNT(*), MIN(sample_timestamp)
                FROM rate_limit_samples
                WHERE source_kind = 'session' AND source_session_id = 'session-1'
                ",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .expect("load preserved samples");
        assert_eq!(persisted, (1, existing.sample_timestamp));
    }

    #[test]
    fn session_replace_repairs_legacy_null_epoch_rows() {
        let conn = Connection::open_in_memory().expect("open database");
        init_db(&conn).expect("initialize database");
        let sample = session_sample(
            "2026-07-10T02:00:00Z",
            "2026-07-10T02:00:00Z",
            "2026-07-10T07:00:00Z",
        );
        replace_session_rate_limit_samples(&conn, "session-1", &[sample.clone()])
            .expect("insert initial sample");
        conn.execute(
            "UPDATE rate_limit_samples SET sample_timestamp_ms = NULL, window_start_ms = NULL, resets_at_ms = NULL WHERE source_session_id = 'session-1'",
            [],
        )
        .expect("simulate legacy null epochs");

        replace_session_rate_limit_samples(&conn, "session-1", &[sample])
            .expect("repair legacy session sample");

        let populated: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM rate_limit_samples WHERE source_session_id = 'session-1' AND sample_timestamp_ms IS NOT NULL AND window_start_ms IS NOT NULL AND resets_at_ms IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .expect("count populated epochs");
        assert_eq!(populated, 1);
    }
}

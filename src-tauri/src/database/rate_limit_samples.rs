use std::io::{Error as IoError, ErrorKind};

use rusqlite::{params, Connection};

use crate::models::{LiveRateLimitSnapshot, RateLimitSampleRecord};

use super::{now_utc_string, parse_epoch_millis};

struct ParsedRateLimitSample<'a> {
    sample: &'a RateLimitSampleRecord,
    sample_timestamp_ms: i64,
    window_start_ms: i64,
    resets_at_ms: i64,
}

pub fn replace_session_rate_limit_samples(
    conn: &Connection,
    session_id: &str,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
    let parsed = parse_rate_limit_samples(samples)?;
    conn.execute(
        "
    DELETE FROM rate_limit_samples
    WHERE source_kind = 'session' AND source_session_id = ?1
    ",
        params![session_id],
    )?;
    insert_parsed_rate_limit_samples(conn, &parsed)
}

pub fn insert_rate_limit_samples(
    conn: &Connection,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
    let parsed = parse_rate_limit_samples(samples)?;
    insert_parsed_rate_limit_samples(conn, &parsed)
}

fn parse_rate_limit_samples(
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<Vec<ParsedRateLimitSample<'_>>> {
    let mut parsed = Vec::with_capacity(samples.len());
    for sample in samples {
        parsed.push(ParsedRateLimitSample {
            sample,
            sample_timestamp_ms: parse_epoch_field(
                "sample_timestamp",
                &sample.sample_timestamp,
            )?,
            window_start_ms: parse_epoch_field("window_start", &sample.window_start)?,
            resets_at_ms: parse_epoch_field("resets_at", &sample.resets_at)?,
        });
    }
    Ok(parsed)
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
    samples: &[ParsedRateLimitSample<'_>],
) -> rusqlite::Result<()> {
    if samples.is_empty() {
        return Ok(());
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

    for parsed in samples {
        let sample = parsed.sample;
        stmt.execute(params![
            sample.source_kind,
            sample.source_session_id.as_deref().unwrap_or_default(),
            sample.bucket,
            sample.sample_timestamp,
            parsed.sample_timestamp_ms,
            sample.limit_id.as_deref().unwrap_or_default(),
            sample.limit_name.as_deref().unwrap_or_default(),
            sample.plan_type.as_deref().unwrap_or_default(),
            sample.window_start,
            parsed.window_start_ms,
            sample.resets_at,
            parsed.resets_at_ms,
            sample.used_percent.clamp(0, 100),
            sample.remaining_percent.clamp(0, 100),
            created_at,
        ])?;
    }

    Ok(())
}

pub fn insert_live_rate_limit_snapshot(
    conn: &Connection,
    snapshot: &LiveRateLimitSnapshot,
) -> rusqlite::Result<()> {
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
    insert_rate_limit_samples(conn, &samples)
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use crate::database::{init_db, parse_epoch_millis};
    use crate::models::{
        LiveRateLimitSnapshot, RateLimitSampleRecord, RateLimitWindowSnapshot,
    };

    use super::{
        insert_live_rate_limit_snapshot, insert_rate_limit_samples,
        replace_session_rate_limit_samples,
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
            .query_row("SELECT COUNT(*) FROM rate_limit_samples", [], |row| row.get(0))
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
}

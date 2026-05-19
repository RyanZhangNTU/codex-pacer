use rusqlite::{params, Connection};

use crate::models::{LiveRateLimitSnapshot, RateLimitSampleRecord};

use super::now_utc_string;

pub fn replace_session_rate_limit_samples(
    conn: &Connection,
    session_id: &str,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
    conn.execute(
        "
    DELETE FROM rate_limit_samples
    WHERE source_kind = 'session' AND source_session_id = ?1
    ",
        params![session_id],
    )?;
    insert_rate_limit_samples(conn, samples)
}

pub fn insert_rate_limit_samples(
    conn: &Connection,
    samples: &[RateLimitSampleRecord],
) -> rusqlite::Result<()> {
    let created_at = now_utc_string();
    let mut stmt = conn.prepare(
        "
    INSERT OR IGNORE INTO rate_limit_samples (
      source_kind, source_session_id, bucket, sample_timestamp, limit_id, limit_name, plan_type,
      window_start, resets_at, used_percent, remaining_percent, created_at
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    ",
    )?;

    for sample in samples {
        stmt.execute(params![
            sample.source_kind,
            sample.source_session_id.clone().unwrap_or_default(),
            sample.bucket,
            sample.sample_timestamp,
            sample.limit_id.clone().unwrap_or_default(),
            sample.limit_name.clone().unwrap_or_default(),
            sample.plan_type.clone().unwrap_or_default(),
            sample.window_start,
            sample.resets_at,
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

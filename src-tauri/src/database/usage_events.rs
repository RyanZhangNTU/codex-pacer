use std::io::{Error as IoError, ErrorKind};

use rusqlite::{params, Connection};

use super::{bool_to_i64, parse_epoch_millis};

pub struct NewUsageEvent<'a> {
  pub session_id: &'a str,
  pub model_id: String,
  pub input_tokens: i64,
  pub cached_input_tokens: i64,
  pub output_tokens: i64,
  pub reasoning_output_tokens: i64,
  pub total_tokens: i64,
  pub value_usd: f64,
  pub fast_mode_auto: bool,
  pub fast_mode_effective: bool,
}

#[derive(Clone, Debug, PartialEq)]
struct PreparedUsageEvent {
  session_id: String,
  timestamp: String,
  timestamp_ms: i64,
  model_id: String,
  input_tokens: i64,
  cached_input_tokens: i64,
  output_tokens: i64,
  reasoning_output_tokens: i64,
  total_tokens: i64,
  value_usd: f64,
  fast_mode_auto: bool,
  fast_mode_effective: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct UsageEventWriteStats {
  pub observed: usize,
  pub inserted: usize,
  pub deleted: usize,
  pub rebuilt: bool,
}

#[cfg(test)]
pub fn insert_usage_events<'a, Timestamps, EventAt>(
  conn: &Connection,
  timestamps: Timestamps,
  mut event_at: EventAt,
) -> rusqlite::Result<usize>
where
  Timestamps: ExactSizeIterator<Item = &'a str> + Clone,
  EventAt: FnMut(usize) -> Option<NewUsageEvent<'a>>,
{
  let prepared = prepare_usage_events(timestamps, &mut event_at)?;
  insert_prepared_usage_events(conn, &prepared)
}

pub fn replace_session_usage_events<'a, Timestamps, EventAt>(
  conn: &Connection,
  session_id: &str,
  timestamps: Timestamps,
  mut event_at: EventAt,
) -> rusqlite::Result<UsageEventWriteStats>
where
  Timestamps: ExactSizeIterator<Item = &'a str> + Clone,
  EventAt: FnMut(usize) -> Option<NewUsageEvent<'a>>,
{
  let mut desired = prepare_usage_events(timestamps, &mut event_at)?;
  for event in &mut desired {
    event.session_id = session_id.to_string();
  }
  let existing = load_session_usage_events(conn, session_id)?;
  let matching_prefix = existing
    .iter()
    .zip(&desired)
    .take_while(|(left, right)| left == right)
    .count();

  conn.execute_batch("SAVEPOINT codex_pacer_usage_event_write")?;
  let result = if matching_prefix == existing.len() {
    insert_prepared_usage_events(conn, &desired[matching_prefix..]).map(|inserted| {
      UsageEventWriteStats {
        observed: desired.len(),
        inserted,
        deleted: 0,
        rebuilt: false,
      }
    })
  } else {
    conn.execute(
      "DELETE FROM usage_events WHERE session_id = ?1",
      params![session_id],
    )
    .and_then(|deleted| {
      insert_prepared_usage_events(conn, &desired).map(|inserted| UsageEventWriteStats {
        observed: desired.len(),
        inserted,
        deleted,
        rebuilt: true,
      })
    })
  };
  match result {
    Ok(stats) => {
      conn.execute_batch("RELEASE SAVEPOINT codex_pacer_usage_event_write")?;
      Ok(stats)
    }
    Err(error) => {
      let _ = conn.execute_batch(
        "ROLLBACK TO SAVEPOINT codex_pacer_usage_event_write; RELEASE SAVEPOINT codex_pacer_usage_event_write",
      );
      Err(error)
    }
  }
}

fn prepare_usage_events<'a, Timestamps, EventAt>(
  timestamps: Timestamps,
  event_at: &mut EventAt,
) -> rusqlite::Result<Vec<PreparedUsageEvent>>
where
  Timestamps: ExactSizeIterator<Item = &'a str> + Clone,
  EventAt: FnMut(usize) -> Option<NewUsageEvent<'a>>,
{
  let mut parsed_timestamps = Vec::with_capacity(timestamps.len());
  for timestamp in timestamps.clone() {
    let timestamp_ms = parse_epoch_millis(timestamp).map_err(|error| {
      rusqlite::Error::ToSqlConversionFailure(Box::new(IoError::new(
        ErrorKind::InvalidData,
        format!("Invalid usage event timestamp {timestamp:?}: {error}"),
      )))
    })?;
    parsed_timestamps.push((timestamp.to_string(), timestamp_ms));
  }

  let mut prepared = Vec::with_capacity(parsed_timestamps.len());
  for (index, (timestamp, timestamp_ms)) in parsed_timestamps.into_iter().enumerate() {
    let Some(event) = event_at(index) else {
      continue;
    };
    prepared.push(PreparedUsageEvent {
      session_id: event.session_id.to_string(),
      timestamp,
      timestamp_ms,
      model_id: event.model_id,
      input_tokens: event.input_tokens,
      cached_input_tokens: event.cached_input_tokens,
      output_tokens: event.output_tokens,
      reasoning_output_tokens: event.reasoning_output_tokens,
      total_tokens: event.total_tokens,
      value_usd: event.value_usd,
      fast_mode_auto: event.fast_mode_auto,
      fast_mode_effective: event.fast_mode_effective,
    });
  }
  Ok(prepared)
}

fn insert_prepared_usage_events(
  conn: &Connection,
  events: &[PreparedUsageEvent],
) -> rusqlite::Result<usize> {
  if events.is_empty() {
    return Ok(0);
  }

  let mut statement = conn.prepare(
    "
    INSERT INTO usage_events (
      session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens,
      output_tokens, reasoning_output_tokens, total_tokens, value_usd,
      fast_mode_auto, fast_mode_effective
    )
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    ",
  )?;

  let mut inserted = 0usize;
  for event in events {
    statement.execute(params![
      event.session_id,
      event.timestamp,
      event.timestamp_ms,
      event.model_id,
      event.input_tokens,
      event.cached_input_tokens,
      event.output_tokens,
      event.reasoning_output_tokens,
      event.total_tokens,
      event.value_usd,
      bool_to_i64(event.fast_mode_auto),
      bool_to_i64(event.fast_mode_effective),
    ])?;
    inserted += 1;
  }

  Ok(inserted)
}

fn load_session_usage_events(
  conn: &Connection,
  session_id: &str,
) -> rusqlite::Result<Vec<PreparedUsageEvent>> {
  let mut statement = conn.prepare(
    "
    SELECT session_id, timestamp, timestamp_ms, model_id, input_tokens, cached_input_tokens,
           output_tokens, reasoning_output_tokens, total_tokens, value_usd,
           fast_mode_auto, fast_mode_effective
    FROM usage_events
    WHERE session_id = ?1
    ORDER BY id
    ",
  )?;
  let rows = statement.query_map(params![session_id], |row| {
    Ok(PreparedUsageEvent {
      session_id: row.get(0)?,
      timestamp: row.get(1)?,
      timestamp_ms: row.get::<_, Option<i64>>(2)?.unwrap_or(i64::MIN),
      model_id: row.get(3)?,
      input_tokens: row.get(4)?,
      cached_input_tokens: row.get(5)?,
      output_tokens: row.get(6)?,
      reasoning_output_tokens: row.get(7)?,
      total_tokens: row.get(8)?,
      value_usd: row.get(9)?,
      fast_mode_auto: row.get::<_, i64>(10)? != 0,
      fast_mode_effective: row.get::<_, i64>(11)? != 0,
    })
  })?;
  rows.collect()
}

#[cfg(test)]
mod tests {
  use rusqlite::Connection;

  use crate::database::{init_db, parse_epoch_millis};

  use super::{insert_usage_events, replace_session_usage_events, NewUsageEvent};

  fn event<'a>(
    session_id: &'a str,
    model_id: &str,
    total_tokens: i64,
  ) -> NewUsageEvent<'a> {
    NewUsageEvent {
      session_id,
      model_id: model_id.to_string(),
      input_tokens: total_tokens,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 0,
      total_tokens,
      value_usd: 0.0,
      fast_mode_auto: false,
      fast_mode_effective: false,
    }
  }

  #[test]
  fn new_usage_event_writes_timestamp_ms() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let timestamps = ["2026-07-10T10:00:00+08:00"];

    insert_usage_events(
      &conn,
      timestamps.iter().copied(),
      |_| Some(event("session-1", "gpt-5.4", 10)),
    )
    .expect("insert usage event");

    let persisted = conn
      .query_row(
        "SELECT timestamp, timestamp_ms FROM usage_events",
        [],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
      )
      .expect("load usage event");
    assert_eq!(persisted.0, timestamps[0]);
    assert_eq!(
      persisted.1,
      parse_epoch_millis(timestamps[0]).expect("parse expected timestamp")
    );
  }

  #[test]
  fn usage_event_batch_parses_mixed_offsets_by_instant() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let timestamps = ["2026-07-10T10:00:00+08:00", "2026-07-10T02:00:01Z"];

    insert_usage_events(
      &conn,
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    )
    .expect("insert usage events");

    let epochs = conn
      .prepare("SELECT timestamp_ms FROM usage_events ORDER BY id")
      .expect("prepare epoch query")
      .query_map([], |row| row.get::<_, i64>(0))
      .expect("query epochs")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect epochs");
    assert_eq!(epochs.len(), 2);
    assert_eq!(epochs[1] - epochs[0], 1_000);
  }

  #[test]
  fn malformed_new_usage_batch_writes_nothing() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let timestamps = ["2026-07-10T02:00:00Z", "not-an-rfc3339-timestamp"];

    let result = insert_usage_events(
      &conn,
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    );

    assert!(result.is_err());
    let count: i64 = conn
      .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))
      .expect("count usage events");
    assert_eq!(count, 0);
  }

  #[test]
  fn repeated_session_usage_replace_writes_nothing_and_preserves_ids() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let timestamps = ["2026-07-10T02:00:00Z", "2026-07-10T02:01:00Z"];
    replace_session_usage_events(
      &conn,
      "session-1",
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    )
    .expect("insert initial usage");
    let ids_before = usage_ids(&conn, "session-1");
    let changes_before = conn.total_changes();

    let stats = replace_session_usage_events(
      &conn,
      "session-1",
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    )
    .expect("repeat usage");

    assert_eq!(stats.inserted, 0);
    assert_eq!(stats.deleted, 0);
    assert!(!stats.rebuilt);
    assert_eq!(usage_ids(&conn, "session-1"), ids_before);
    assert_eq!(conn.total_changes(), changes_before);
  }

  #[test]
  fn appended_session_usage_preserves_prefix_ids() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let initial = ["2026-07-10T02:00:00Z", "2026-07-10T02:01:00Z"];
    replace_session_usage_events(&conn, "session-1", initial.iter().copied(), |index| {
      Some(event("session-1", "gpt-5.4", index as i64 + 1))
    })
    .expect("insert initial usage");
    let ids_before = usage_ids(&conn, "session-1");
    let appended = [
      "2026-07-10T02:00:00Z",
      "2026-07-10T02:01:00Z",
      "2026-07-10T02:02:00Z",
    ];

    let stats = replace_session_usage_events(
      &conn,
      "session-1",
      appended.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    )
    .expect("append usage");
    let ids_after = usage_ids(&conn, "session-1");

    assert_eq!(stats.inserted, 1);
    assert_eq!(stats.deleted, 0);
    assert!(!stats.rebuilt);
    assert_eq!(&ids_after[..ids_before.len()], ids_before.as_slice());
    assert_eq!(ids_after.len(), 3);
  }

  #[test]
  fn changed_session_usage_prefix_rebuilds_safely() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let timestamps = ["2026-07-10T02:00:00Z", "2026-07-10T02:01:00Z"];
    replace_session_usage_events(
      &conn,
      "session-1",
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    )
    .expect("insert initial usage");
    let ids_before = usage_ids(&conn, "session-1");

    let stats = replace_session_usage_events(
      &conn,
      "session-1",
      timestamps.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 10)),
    )
    .expect("rebuild changed usage");
    let ids_after = usage_ids(&conn, "session-1");

    assert_eq!(stats.inserted, 2);
    assert_eq!(stats.deleted, 2);
    assert!(stats.rebuilt);
    assert_ne!(ids_after, ids_before);
  }

  #[test]
  fn malformed_session_usage_replace_preserves_existing_rows() {
    let conn = Connection::open_in_memory().expect("open database");
    init_db(&conn).expect("initialize database");
    let initial = ["2026-07-10T02:00:00Z"];
    replace_session_usage_events(&conn, "session-1", initial.iter().copied(), |_| {
      Some(event("session-1", "gpt-5.4", 1))
    })
    .expect("insert initial usage");
    let ids_before = usage_ids(&conn, "session-1");
    let malformed = ["2026-07-10T02:00:00Z", "invalid-timestamp"];

    let result = replace_session_usage_events(
      &conn,
      "session-1",
      malformed.iter().copied(),
      |index| Some(event("session-1", "gpt-5.4", index as i64 + 1)),
    );

    assert!(result.is_err());
    assert_eq!(usage_ids(&conn, "session-1"), ids_before);
  }

  fn usage_ids(conn: &Connection, session_id: &str) -> Vec<i64> {
    conn
      .prepare("SELECT id FROM usage_events WHERE session_id = ?1 ORDER BY id")
      .expect("prepare usage ids")
      .query_map([session_id], |row| row.get(0))
      .expect("query usage ids")
      .collect::<rusqlite::Result<Vec<_>>>()
      .expect("collect usage ids")
  }
}

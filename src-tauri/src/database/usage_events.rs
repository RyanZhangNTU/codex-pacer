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

pub fn insert_usage_events<'a, Timestamps, EventAt>(
  conn: &Connection,
  timestamps: Timestamps,
  mut event_at: EventAt,
) -> rusqlite::Result<usize>
where
  Timestamps: ExactSizeIterator<Item = &'a str> + Clone,
  EventAt: FnMut(usize) -> Option<NewUsageEvent<'a>>,
{
  let mut timestamp_epochs = Vec::with_capacity(timestamps.len());
  for timestamp in timestamps.clone() {
    let timestamp_ms = parse_epoch_millis(timestamp).map_err(|error| {
      rusqlite::Error::ToSqlConversionFailure(Box::new(IoError::new(
        ErrorKind::InvalidData,
        format!("Invalid usage event timestamp {timestamp:?}: {error}"),
      )))
    })?;
    timestamp_epochs.push(timestamp_ms);
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
  for (index, (timestamp, timestamp_ms)) in timestamps.zip(timestamp_epochs).enumerate() {
    let Some(event) = event_at(index) else {
      continue;
    };
    statement.execute(params![
      event.session_id,
      timestamp,
      timestamp_ms,
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

#[cfg(test)]
mod tests {
  use rusqlite::Connection;

  use crate::database::{init_db, parse_epoch_millis};

  use super::{insert_usage_events, NewUsageEvent};

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
}

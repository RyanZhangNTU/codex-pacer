CREATE INDEX IF NOT EXISTS idx_usage_events_session_id ON usage_events(session_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp ON usage_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp_ms
  ON usage_events(timestamp_ms, id)
  WHERE timestamp_ms IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp_value
  ON usage_events(timestamp_ms, value_usd)
  WHERE timestamp_ms IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_usage_events_missing_timestamp_ms
  ON usage_events(id)
  WHERE timestamp_ms IS NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_root_session_id ON sessions(root_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_parent_session_id ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_source_state ON sessions(source_state);
CREATE INDEX IF NOT EXISTS idx_import_state_session_id ON import_state(session_id);
CREATE INDEX IF NOT EXISTS idx_import_state_source_bucket ON import_state(source_bucket);
CREATE INDEX IF NOT EXISTS idx_import_state_incomplete_archived_tail
  ON import_state(source_path)
  WHERE source_bucket = 'archived'
    AND parser_completed_offset < file_size;
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_bucket_window
  ON rate_limit_samples(bucket, window_start, resets_at, sample_timestamp);
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_window_ms
  ON rate_limit_samples(bucket, window_start_ms, resets_at_ms, sample_timestamp_ms, id)
  WHERE window_start_ms IS NOT NULL AND resets_at_ms IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_limit_samples_dedupe
  ON rate_limit_samples(
    bucket, sample_timestamp, source_kind, source_session_id, limit_id, window_start, resets_at
  );
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_owner
  ON rate_limit_samples(source_kind, source_session_id, bucket, sample_timestamp_ms, id);
CREATE INDEX IF NOT EXISTS idx_latest_rate_limits_lookup
  ON latest_rate_limits(bucket, source_kind, sample_timestamp_ms DESC, source_session_id);

CREATE INDEX IF NOT EXISTS idx_usage_events_session_id ON usage_events(session_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp ON usage_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_sessions_root_session_id ON sessions(root_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_parent_session_id ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_source_state ON sessions(source_state);
CREATE INDEX IF NOT EXISTS idx_import_state_session_id ON import_state(session_id);
CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_bucket_window
  ON rate_limit_samples(bucket, window_start, resets_at, sample_timestamp);
CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_limit_samples_dedupe
  ON rate_limit_samples(
    bucket, sample_timestamp, source_kind, source_session_id, limit_id, window_start, resets_at
  );
CREATE INDEX IF NOT EXISTS idx_subscription_records_service
  ON subscription_records(service_start, service_end);

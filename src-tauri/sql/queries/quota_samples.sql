SELECT sample_timestamp, used_percent, window_start, resets_at
FROM rate_limit_samples
WHERE bucket = ?1
ORDER BY sample_timestamp ASC

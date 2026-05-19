SELECT window_start, resets_at
FROM rate_limit_samples
WHERE bucket = ?1
GROUP BY window_start, resets_at
ORDER BY window_start DESC, resets_at DESC

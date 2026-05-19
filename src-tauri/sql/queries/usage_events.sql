SELECT session_id, timestamp, model_id, input_tokens, cached_input_tokens,
       output_tokens, reasoning_output_tokens, total_tokens, value_usd,
       fast_mode_auto, fast_mode_effective
FROM usage_events
ORDER BY timestamp ASC, id ASC

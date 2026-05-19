SELECT usage_events.session_id, usage_events.timestamp, usage_events.model_id,
       usage_events.input_tokens, usage_events.cached_input_tokens,
       usage_events.output_tokens, usage_events.reasoning_output_tokens,
       usage_events.total_tokens, usage_events.value_usd,
       usage_events.fast_mode_auto, usage_events.fast_mode_effective
FROM usage_events
INNER JOIN sessions ON sessions.session_id = usage_events.session_id
WHERE sessions.root_session_id = ?1
ORDER BY usage_events.timestamp ASC, usage_events.id ASC

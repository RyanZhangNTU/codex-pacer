SELECT session_id, root_session_id, parent_session_id, title, source_state, source_path,
       started_at, updated_at, agent_nickname, agent_role
FROM sessions
WHERE root_session_id = ?1

-- ClipVault Trae hook store. Dedicated DuckDB file, not clipflow.db.
-- Table lives in main so Quack ATTACH writers can INSERT INTO remote.hook_events.

CREATE TABLE IF NOT EXISTS hook_events (
    event_id VARCHAR PRIMARY KEY,
    ts TIMESTAMP NOT NULL,
    ingested_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    instance_id VARCHAR NOT NULL,
    session_id VARCHAR,
    hook_event VARCHAR NOT NULL,
    source VARCHAR NOT NULL,
    cwd VARCHAR,
    workspace_roots VARCHAR,
    tool_name VARCHAR,
    llm_tool_name VARCHAR,
    tool_use_id VARCHAR,
    prompt VARCHAR,
    last_assistant_message VARCHAR,
    notification_type VARCHAR,
    notification_message VARCHAR,
    stop_hook_active BOOLEAN,
    loop_count INTEGER,
    tool_input VARCHAR,
    tool_response VARCHAR,
    raw_json VARCHAR NOT NULL,
    raw_hash VARCHAR NOT NULL UNIQUE,
    host VARCHAR,
    pid INTEGER
);

CREATE INDEX IF NOT EXISTS idx_hook_session_ts ON hook_events(session_id, ts);
CREATE INDEX IF NOT EXISTS idx_hook_event_ts ON hook_events(hook_event, ts);
CREATE INDEX IF NOT EXISTS idx_hook_ts ON hook_events(ts DESC);

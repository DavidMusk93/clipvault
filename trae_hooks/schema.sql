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

-- Local session pins. Trae-only; not clip pinned_at / wall pin rail.
CREATE TABLE IF NOT EXISTS session_pins (
    session_id VARCHAR PRIMARY KEY,
    pinned_at TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- Metrics plane. Content lives in hook_events; money/speed/context live here.
-- Grain = one assistant message (one LLM response). Join on session_id + ts.
-- Written two ways, both idempotent (deterministic id + ON CONFLICT DO NOTHING):
--   hot path  : pi/clipvault-session.ts -> UsageReport/ContextReport -> Quack INSERT
--   cold path : pi_session_ingest.py -> pi session JSONL -> Quack INSERT
-- Trae cannot feed this: its hook stdin has no usage/model/cost (verified).
-- ---------------------------------------------------------------------------

-- Economic + speed facts per LLM response.
CREATE TABLE IF NOT EXISTS llm_usage (
    usage_id VARCHAR PRIMARY KEY,          -- <session_id>:<message_id>
    ts TIMESTAMP NOT NULL,                 -- completion time of the response
    ingested_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    session_id VARCHAR,
    instance_id VARCHAR,
    source VARCHAR,                        -- pi / trae
    model VARCHAR,
    provider VARCHAR,
    api VARCHAR,
    message_id VARCHAR,
    turn_index INTEGER,                    -- 0-based assistant message index in session
    input_tokens BIGINT,                   -- uncached prompt tokens
    output_tokens BIGINT,
    cache_read_tokens BIGINT,              -- prefix hit: cheap, this is the lever
    cache_write_tokens BIGINT,
    reasoning_tokens BIGINT,
    total_tokens BIGINT,
    cost_input DOUBLE,
    cost_output DOUBLE,
    cost_cache_read DOUBLE,
    cost_cache_write DOUBLE,
    cost_total DOUBLE,
    ttft_ms BIGINT,                        -- hot path only; NULL after cold ingest
    elapsed_ms BIGINT,
    decode_ms BIGINT,                      -- elapsed - ttft
    tok_s_decode DOUBLE,                   -- output / decode
    tok_s_e2e DOUBLE,                      -- output / elapsed
    stop_reason VARCHAR,
    response_id VARCHAR,
    host VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_usage_session_ts ON llm_usage(session_id, ts);
CREATE INDEX IF NOT EXISTS idx_usage_model ON llm_usage(model);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON llm_usage(ts DESC);

-- Context composition per LLM response. Token counts are estimates
-- (chars / est_chars_per_token); prompt_total_tokens is the estimate that
-- should track llm_usage.input_tokens + cache_read_tokens.
CREATE TABLE IF NOT EXISTS turn_context (
    ctx_id VARCHAR PRIMARY KEY,            -- <session_id>:<message_id>
    ts TIMESTAMP NOT NULL,
    ingested_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    session_id VARCHAR,
    instance_id VARCHAR,
    source VARCHAR,
    model VARCHAR,
    message_id VARCHAR,
    turn_index INTEGER,
    system_tokens BIGINT,                  -- sum of the section_* below
    preamble_tokens BIGINT,
    tools_tokens BIGINT,                   -- tool schema definitions
    rules_tokens BIGINT,                   -- ~/.pi/agent/AGENTS.md rules block
    docs_tokens BIGINT,
    project_tokens BIGINT,                 -- project AGENTS.md / context
    skills_tokens BIGINT,                  -- available_skills index (bytedcli-class)
    prompt_tokens BIGINT,                  -- current user prompt
    history_tokens BIGINT,                 -- accumulated prior messages
    tool_result_tokens BIGINT,             -- accumulated tool payloads
    prompt_total_tokens BIGINT,            -- system + prompt + history
    est_chars_per_token DOUBLE,
    sections_json VARCHAR,                 -- raw section char counts
    skill_names VARCHAR,                   -- comma list of skills loaded this turn
    skill_loaded_tokens VARCHAR,           -- JSON map skill -> tokens it dumped into context
    memory_ids VARCHAR,                    -- nowledgemem memory ids retrieved this turn
    tool_schema_names VARCHAR,
    host VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_ctx_session_ts ON turn_context(session_id, ts);
CREATE INDEX IF NOT EXISTS idx_ctx_ts ON turn_context(ts DESC);

-- Idempotent migration for stores whose turn_context predates skill attribution.
ALTER TABLE turn_context ADD COLUMN IF NOT EXISTS skill_loaded_tokens VARCHAR;

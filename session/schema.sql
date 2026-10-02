-- ClipVault session store (PostgreSQL 18).
--
-- Replaces the embedded DuckDB file. One corpus lives on the primary backend
-- (d2); a logical-CDC replica lives on cc. See docs/design-session-backends.md.
--
-- Timestamps are timestamptz. Writers set TimeZone=UTC on the session and store
-- naive-UTC values; readers normalise back to naive-UTC on the wire (INV-5).
-- raw_json is kept in v1 to preserve the search / bundle read paths byte-for-byte;
-- dropping it (and promoting agent_type / agent_id / text_content) is a later,
-- measured optimisation.

CREATE TABLE IF NOT EXISTS hook_events (
    event_id TEXT PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    instance_id TEXT NOT NULL,
    session_id TEXT,
    hook_event TEXT NOT NULL,
    source TEXT NOT NULL,
    cwd TEXT,
    workspace_roots TEXT,
    tool_name TEXT,
    llm_tool_name TEXT,
    tool_use_id TEXT,
    prompt TEXT,
    last_assistant_message TEXT,
    notification_type TEXT,
    notification_message TEXT,
    stop_hook_active BOOLEAN,
    loop_count INTEGER,
    tool_input TEXT,
    tool_response TEXT,
    raw_json TEXT NOT NULL,
    raw_hash TEXT NOT NULL UNIQUE,
    host TEXT,
    pid INTEGER
);

CREATE INDEX IF NOT EXISTS idx_hook_session_ts ON hook_events (session_id, ts);
CREATE INDEX IF NOT EXISTS idx_hook_event_ts ON hook_events (hook_event, ts);
CREATE INDEX IF NOT EXISTS idx_hook_ts ON hook_events (ts DESC);

-- Local session pins. Trae-only; not the clip pinned_at / wall pin rail.
CREATE TABLE IF NOT EXISTS session_pins (
    session_id TEXT PRIMARY KEY,
    pinned_at TIMESTAMPTZ NOT NULL
);

-- ---------------------------------------------------------------------------
-- Metrics plane. Content lives in hook_events; money / speed / context here.
-- Grain = one assistant message (one LLM response). Join on session_id + ts.
-- Written two ways, both idempotent (deterministic id + ON CONFLICT DO NOTHING):
--   hot path  : pi/clipvault-session.ts -> UsageReport/ContextReport
--   cold path : pi_session_ingest.py -> pi session JSONL
-- Trae cannot feed this: its hook stdin has no usage/model/cost (verified).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS llm_usage (
    usage_id TEXT PRIMARY KEY,             -- <session_id>:<message_id>
    ts TIMESTAMPTZ NOT NULL,               -- completion time of the response
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    session_id TEXT,
    instance_id TEXT,
    source TEXT,                           -- pi / trae
    model TEXT,
    provider TEXT,
    api TEXT,
    message_id TEXT,
    turn_index INTEGER,
    input_tokens BIGINT,
    output_tokens BIGINT,
    cache_read_tokens BIGINT,
    cache_write_tokens BIGINT,
    reasoning_tokens BIGINT,
    total_tokens BIGINT,
    cost_input DOUBLE PRECISION,
    cost_output DOUBLE PRECISION,
    cost_cache_read DOUBLE PRECISION,
    cost_cache_write DOUBLE PRECISION,
    cost_total DOUBLE PRECISION,
    ttft_ms BIGINT,
    elapsed_ms BIGINT,
    decode_ms BIGINT,
    tok_s_decode DOUBLE PRECISION,
    tok_s_e2e DOUBLE PRECISION,
    stop_reason TEXT,
    response_id TEXT,
    host TEXT
);

CREATE INDEX IF NOT EXISTS idx_usage_session_ts ON llm_usage (session_id, ts);
CREATE INDEX IF NOT EXISTS idx_usage_model ON llm_usage (model);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON llm_usage (ts DESC);

CREATE TABLE IF NOT EXISTS turn_context (
    ctx_id TEXT PRIMARY KEY,               -- <session_id>:<message_id>
    ts TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    session_id TEXT,
    instance_id TEXT,
    source TEXT,
    model TEXT,
    message_id TEXT,
    turn_index INTEGER,
    system_tokens BIGINT,
    preamble_tokens BIGINT,
    tools_tokens BIGINT,
    rules_tokens BIGINT,
    docs_tokens BIGINT,
    project_tokens BIGINT,
    skills_tokens BIGINT,
    prompt_tokens BIGINT,
    history_tokens BIGINT,
    tool_result_tokens BIGINT,
    prompt_total_tokens BIGINT,
    est_chars_per_token DOUBLE PRECISION,
    sections_json TEXT,
    skill_names TEXT,
    skill_loaded_tokens TEXT,
    memory_ids TEXT,
    tool_schema_names TEXT,
    host TEXT
);

CREATE INDEX IF NOT EXISTS idx_ctx_session_ts ON turn_context (session_id, ts);
CREATE INDEX IF NOT EXISTS idx_ctx_ts ON turn_context (ts DESC);

-- Idempotent migration for stores whose turn_context predates skill attribution.
ALTER TABLE turn_context ADD COLUMN IF NOT EXISTS skill_loaded_tokens TEXT;

-- Agent analysis write-back (L3 loop). Latest status per (scope, session, finding)
-- wins; replaying an ack is idempotent (INV-8).
CREATE TABLE IF NOT EXISTS analysis_acks (
    ack_id TEXT PRIMARY KEY,          -- <scope>:<session_id|->:<finding_id>
    ts TIMESTAMPTZ NOT NULL,
    instance_id TEXT,
    scope TEXT NOT NULL,              -- session | recent
    session_id TEXT,
    finding_id TEXT NOT NULL,
    status TEXT NOT NULL,             -- applied | dismissed
    note TEXT,
    metric_id TEXT,
    metric_now DOUBLE PRECISION,
    target DOUBLE PRECISION
);

CREATE INDEX IF NOT EXISTS idx_acks_scope_session ON analysis_acks (scope, session_id, ts DESC);

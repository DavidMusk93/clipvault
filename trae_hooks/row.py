"""Normalize a Trae hook stdin payload into a hook_events row."""

from __future__ import annotations

import hashlib
import json
import os
import socket
import uuid
from datetime import datetime, timezone
from typing import Any


OFFICIAL_EVENTS = (
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Notification",
)


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def dumps(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def payload_hash(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def row_from_payload(
    payload: dict[str, Any],
    *,
    hook_event: str | None = None,
    instance_id: str,
    source: str = "trae",
) -> dict[str, Any]:
    event = (
        hook_event
        or payload.get("hook_event_name")
        or payload.get("hookEventName")
        or "Unknown"
    )
    raw_hash = payload_hash(payload)
    event_id = raw_hash[:32]
    ts = utc_now()
    return {
        "event_id": event_id,
        "ts": ts,
        "instance_id": instance_id,
        "session_id": payload.get("session_id"),
        "hook_event": str(event),
        "source": source,
        "cwd": payload.get("cwd"),
        "workspace_roots": dumps(payload.get("workspace_roots")),
        "tool_name": payload.get("tool_name"),
        "llm_tool_name": payload.get("llm_tool_name"),
        "tool_use_id": payload.get("tool_use_id"),
        "prompt": payload.get("prompt"),
        "last_assistant_message": payload.get("last_assistant_message"),
        "notification_type": payload.get("notification_type"),
        "notification_message": payload.get("message")
        if event == "Notification"
        else None,
        "stop_hook_active": payload.get("stop_hook_active"),
        "loop_count": payload.get("loop_count"),
        "tool_input": dumps(payload.get("tool_input")),
        "tool_response": dumps(payload.get("tool_response")),
        "raw_json": json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        "raw_hash": raw_hash,
        "host": socket.gethostname(),
        "pid": os.getpid(),
    }


def parse_stdin(raw: str, hook_event: str | None) -> dict[str, Any]:
    text = (raw or "").strip()
    if not text:
        return {
            "hook_event_name": hook_event or "Unknown",
            "empty_stdin": True,
            "client_event_id": str(uuid.uuid4()),
        }
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {
            "hook_event_name": hook_event or "Unknown",
            "raw_text": text[:20000],
            "parse_error": True,
            "client_event_id": str(uuid.uuid4()),
        }
    if not isinstance(data, dict):
        return {
            "hook_event_name": hook_event or "Unknown",
            "raw_text": text[:20000],
            "parse_error": True,
            "client_event_id": str(uuid.uuid4()),
        }
    if hook_event and not data.get("hook_event_name"):
        data["hook_event_name"] = hook_event
    return data

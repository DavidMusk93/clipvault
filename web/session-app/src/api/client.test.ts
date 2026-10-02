import { describe, expect, it } from "vitest";
import { schemas } from "./client";

// Contract tests: the shapes the backend must satisfy. If a Rust change breaks
// one of these, the panel fails in CI instead of rendering half-empty.
describe("SA-v1 schemas", () => {
  it("parses a sessions payload", () => {
    const parsed = schemas.sessions.parse({
      sessions: [
        {
          session_id: "s1",
          event_count: 3,
          last_ts: "2026-10-02 14:56:27",
          instance_id: "mac-home",
          source: "pi",
          backend_id: "d2",
        },
      ],
    });
    expect(parsed.sessions[0]?.session_id).toBe("s1");
  });

  it("rejects a sessions payload without session_id", () => {
    expect(() => schemas.sessions.parse({ sessions: [{ event_count: 1 }] })).toThrow();
  });

  it("parses an events payload", () => {
    const parsed = schemas.events.parse({
      events: [{ event_id: "e1", ts: "2026-10-02 14:56:27", hook_event: "Stop" }],
      view: "full",
    });
    expect(parsed.events).toHaveLength(1);
  });
});

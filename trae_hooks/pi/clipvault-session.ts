/**
 * clipvault-session.ts — mirror pi sessions into ClipVault's Trae session store.
 *
 * pi has no hooks.json. This extension is the adapter: it maps pi lifecycle
 * events to the ClipVault hook contract and pipes them through the existing
 * Trae wrapper (`clipvault_hook.sh`), which spools then Quack-INSERTs into the
 * Mac DuckDB and pings the local SSE hub. Nothing is awaited, so pi never
 * blocks on the store.
 *
 *   pi event                 ClipVault hook_event   notes
 *   -----------------------  ---------------------  ---------------------------
 *   session_start            SessionStart           startup/new/resume/fork
 *   before_agent_start       UserPromptSubmit       prompt (source-guarded)
 *   tool_execution_start     PreToolUse             tool name/input
 *   tool_result              PostToolUse            wall time + isError->exit
 *   message_end (assistant)  UsageReport            tok in/out/cache/cost + ttft
 *   agent_settled            Stop                   last assistant message
 *   ui_prompt_start          Notification           pi waiting on the human
 *
 * UsageReport is the metrics plane: hook_client routes it to DuckDB llm_usage,
 * never to hook_events. It is the only writer that can supply ttft_ms (the JSONL
 * backfill in pi_session_ingest.py has no ttft). Key is <session_id>:<message.timestamp>,
 * identical to the JSONL backfill, so the two writers upsert one row per turn.
 *
 * Tool names are normalised to the ones mine.py understands: bash->RunCommand,
 * read/write/edit stay, grep/find/ls become RunCommand with a shell-shaped cmd,
 * and pi's nmem_* tools become mcp__nowledge-mem__* so the MCP analysis works.
 *
 * Config via env (all optional):
 *   CLIPVAULT_PI_HOOK      wrapper path  (default ~/.trae-cn/hooks_env/clipvault_hook.sh)
 *   CLIPVAULT_PI_HOOK_ENV  env override  (default ~/.trae-cn/hooks_env/pi-hooks.env)
 *
 * instance_id stays the Trae env's (e.g. mac-work); pi sessions are told apart
 * by source=pi. Disable per session:  CLIPVAULT_PI_SESSION_HOOK=0 pi
 */

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const HOOK =
	process.env.CLIPVAULT_PI_HOOK ?? `${homedir()}/.trae-cn/hooks_env/clipvault_hook.sh`;
const HOOK_ENV =
	process.env.CLIPVAULT_PI_HOOK_ENV ?? `${homedir()}/.trae-cn/hooks_env/pi-hooks.env`;
const ENABLED = process.env.CLIPVAULT_PI_SESSION_HOOK !== "0";

/** Normalise pi tool name -> the name mine.py's session analysis expects. */
function mapToolName(name: string): string {
	switch (name) {
		case "bash":
			return "RunCommand";
		case "powershell":
			return "RunCommand";
		case "grep":
		case "find":
		case "ls":
			return "RunCommand";
		case "read":
			return "Read";
		case "write":
			return "Write";
		case "edit":
			return "Edit";
		default:
			// pi's Nowledge Mem extension: nmem_memory_search -> mcp__nowledge-mem__memory_search
			if (name.startsWith("nmem_")) return `mcp__nowledge-mem__${name.slice("nmem_".length)}`;
			return name;
	}
}

/** Shape tool args so parse_head() in mine.py finds cmd / file_path. */
function mapToolInput(name: string, args: unknown): Record<string, unknown> {
	const a = (args ?? {}) as Record<string, any>;
	switch (name) {
		case "bash":
		case "powershell":
			return { cmd: a.command, command: a.command };
		case "grep":
			return { cmd: ["rg", a.pattern, a.path].filter(Boolean).join(" ") };
		case "find":
			return { cmd: ["find", a.path ?? ".", a.pattern].filter(Boolean).join(" ") };
		case "ls":
			return { cmd: ["ls", a.path ?? "."].filter(Boolean).join(" ") };
		case "read":
		case "write":
		case "edit":
			return { file_path: a.path };
		default:
			return a;
	}
}

/** Flatten a message/tool content payload to text (bounded by the caller). */
function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const part of content) {
		if (part && typeof part === "object" && (part as any).type === "text") {
			parts.push(String((part as any).text ?? ""));
		}
	}
	return parts.join("\n");
}

export default function (pi: ExtensionAPI) {
	if (!ENABLED) {
		console.log("[clipvault-session] disabled by CLIPVAULT_PI_SESSION_HOOK=0");
		return;
	}

	const starts = new Map<string, number>();
	let pendingPrompt: string | undefined;
	let lastAssistant = "";
	// UsageReport state: message.timestamp is the request start (pi sets it before
	// the LLM call), so elapsed = now - start and ttft = first delta - start.
	let streamStartedAt: number | undefined;
	let streamFirstTokenAt: number | undefined;
	let turnIndex = -1;

	const base = (ctx: ExtensionContext) => ({
		session_id: ctx.sessionManager.getSessionId(),
		cwd: ctx.cwd,
		workspace_roots: [ctx.cwd],
	});

	/** Fire-and-forget: spool + Quack + SSE all live in the wrapper. */
	const emit = (event: string, payload: Record<string, unknown>): void => {
		try {
			const child = spawn(HOOK, ["--event", event], {
				env: { ...process.env, CLIPVAULT_HOOK_ENV: HOOK_ENV },
				stdio: ["pipe", "ignore", "ignore"],
			});
			child.on("error", () => {});
			child.stdin.on("error", () => {});
			child.stdin.end(JSON.stringify(payload));
			child.unref();
		} catch {
			/* never block pi on the store */
		}
	};

	pi.on("session_start", (_event, ctx) => {
		// Resume/fork: continue the assistant-message index the JSONL backfill uses.
		turnIndex = ctx.sessionManager
			.getEntries()
			.filter((e: any) => e?.type === "message" && e?.message?.role === "assistant").length - 1;
		emit("SessionStart", base(ctx));
	});

	pi.on("input", (event) => {
		if (event.source === "extension") return; // don't record injected messages as user prompts
		pendingPrompt = event.text;
	});

	pi.on("before_agent_start", (event, ctx) => {
		const prompt = pendingPrompt ?? event.prompt;
		pendingPrompt = undefined;
		emit("UserPromptSubmit", { ...base(ctx), prompt });
	});

	pi.on("tool_execution_start", (event, ctx) => {
		starts.set(event.toolCallId, Date.now());
		emit("PreToolUse", {
			...base(ctx),
			tool_use_id: event.toolCallId,
			tool_name: mapToolName(event.toolName),
			llm_tool_name: event.toolName,
			tool_input: mapToolInput(event.toolName, event.args),
		});
	});

	pi.on("tool_result", (event, ctx) => {
		const t0 = starts.get(event.toolCallId);
		starts.delete(event.toolCallId);
		const wall = t0 ? Math.max(0, (Date.now() - t0) / 1000) : 0;
		emit("PostToolUse", {
			...base(ctx),
			tool_use_id: event.toolCallId,
			tool_name: mapToolName(event.toolName),
			llm_tool_name: event.toolName,
			tool_input: mapToolInput(event.toolName, event.input),
			tool_response: {
				wall_time_seconds: wall,
				exit_code: event.isError ? 1 : 0,
				output: textOf(event.content).slice(0, 400),
			},
		});
	});

	pi.on("message_start", (event) => {
		if ((event.message as { role?: string })?.role !== "assistant") return;
		streamStartedAt = Date.now();
		streamFirstTokenAt = undefined;
	});

	pi.on("message_update", (event) => {
		if (streamStartedAt === undefined || streamFirstTokenAt !== undefined) return;
		const type = (event.assistantMessageEvent as { type?: string } | undefined)?.type;
		if (type === "text_delta" || type === "thinking_delta" || type === "toolcall_delta") {
			streamFirstTokenAt = Date.now();
		}
	});

	pi.on("message_end", (event, ctx) => {
		const msg = event.message as {
			role?: string;
			content?: unknown;
			model?: string;
			provider?: string;
			api?: string;
			usage?: unknown;
			stopReason?: string;
			responseId?: string;
			timestamp?: number;
		};
		if (msg?.role !== "assistant") return;
		const text = textOf(msg.content);
		if (text) lastAssistant = text;

		const now = Date.now();
		const elapsed = streamStartedAt !== undefined ? Math.max(0, now - streamStartedAt) : undefined;
		const ttft =
			streamStartedAt !== undefined && streamFirstTokenAt !== undefined
				? Math.max(0, streamFirstTokenAt - streamStartedAt)
				: undefined;
		turnIndex += 1;
		// message.timestamp (unix ms) is the join key shared with the JSONL backfill.
		const messageId =
			typeof msg.timestamp === "number"
				? String(msg.timestamp)
				: `${ctx.sessionManager.getSessionId()}:${turnIndex}`;
		emit("UsageReport", {
			...base(ctx),
			message_id: messageId,
			ts: new Date(now).toISOString(),
			turn_index: turnIndex,
			model: msg.model,
			provider: msg.provider,
			api: msg.api,
			usage: msg.usage,
			stop_reason: msg.stopReason,
			response_id: msg.responseId,
			elapsed_ms: elapsed,
			ttft_ms: ttft,
		});
		streamStartedAt = undefined;
		streamFirstTokenAt = undefined;
	});

	pi.on("agent_settled", (_event, ctx) => {
		emit("Stop", { ...base(ctx), last_assistant_message: lastAssistant.slice(0, 4000) });
	});

	pi.on("ui_prompt_start", (event, ctx) => {
		emit("Notification", {
			...base(ctx),
			notification_type: "ask_user_question",
			message: event.title || `pi ${event.kind}`,
		});
	});

	pi.on("session_shutdown", () => {
		starts.clear();
		pendingPrompt = undefined;
		lastAssistant = "";
		streamStartedAt = undefined;
		streamFirstTokenAt = undefined;
	});

	console.log(`[clipvault-session] pi -> ClipVault sessions via ${HOOK}`);
}

import { localDateTime, recencyTone, relLocalTime, volumeBand } from "@render";
import type { SessionT } from "../../api/client";
import { cn } from "../../lib/cn";

const PIN_ICON = `<svg class="pin-off" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M14.5 4.5v7.2l1.7 1.7V15h-3.4v5.5h-1.6V15H8v-1.6l1.7-1.7V4.5H8V3h8v1.5h-1.5z" opacity=".55"/></svg><svg class="pin-on" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M16 3H8v1.7h1.2V11l-2 2.2V15h4.2v6h1.2v-6H18v-1.8L16 11V4.7H17.2V3H16z"/></svg>`;

const SOURCE_LABEL: Record<string, string> = {
  trae: "Trae",
  pi: "pi",
  grok: "Grok",
  codex: "Codex",
  claude: "Claude",
  cursor: "Cursor",
};

export const sourceLabel = (raw: string) =>
  SOURCE_LABEL[raw] || (raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : "");

const sessionTitle = (s: SessionT): string => {
  const p = String(s.last_prompt || "")
    .trim()
    .split(/\n/)[0];
  if (p) return p.slice(0, 56);
  const cwd = String(s.cwd || "").replace(/\/$/, "");
  const base = cwd.split("/").filter(Boolean).pop();
  if (base) return base;
  const id = String(s.session_id || "");
  return id ? `${id.slice(0, 10)}…` : "无会话";
};

const sessionCwd = (s: SessionT) => String(s.cwd || "").replace(/\/$/, "");

export function RailCard({
  s,
  active,
  onSelect,
  onPin,
  onCopy,
}: {
  s: SessionT;
  active: boolean;
  onSelect: (id: string) => void;
  onPin: (id: string, pinned: boolean) => void;
  onCopy: (id: string) => void;
}) {
  const raw = String(s.source || "")
    .trim()
    .toLowerCase();
  const label = sourceLabel(raw);
  const host = String(s.instance_id || "").trim();
  const cwd = sessionCwd(s);
  const title = sessionTitle(s);

  return (
    <div
      className={cn(
        "card",
        `tone-${recencyTone(s.last_ts)}`,
        `vol-${volumeBand(s.event_count)}`,
        s.pinned_at && "is-pinned",
        active && "active",
      )}
      data-id={s.session_id}
      data-title={title}
      onClick={() => onSelect(s.session_id)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onSelect(s.session_id);
      }}
      role="button"
      tabIndex={0}
    >
      <div className="id-row">
        <div className="title" title={s.session_id}>
          {title}
        </div>
        <button
          type="button"
          className="pin-btn"
          title="置顶"
          aria-label="置顶"
          onClick={(e) => {
            e.stopPropagation();
            onPin(s.session_id, !s.pinned_at);
          }}
          dangerouslySetInnerHTML={{ __html: PIN_ICON }}
        />
        <button
          type="button"
          className="copy-id"
          data-copy-sid={s.session_id}
          title="复制 session id"
          aria-label="复制 session id"
          onClick={(e) => {
            e.stopPropagation();
            onCopy(s.session_id);
          }}
        >
          复制
        </button>
      </div>
      <div className="meta">
        <span className="chip time" title={relLocalTime(s.last_ts)}>
          {localDateTime(s.last_ts) || "—"}
        </span>
        <span
          className="chip source"
          data-src={raw || undefined}
          hidden={!label}
          title={raw ? `agent 来源：${raw}` : undefined}
        >
          {label || "—"}
        </span>
        <span className="chip host" hidden={!host}>
          {host || "—"}
        </span>
        <span className="chip vol">{s.event_count ?? 0} 条</span>
      </div>
      <div className="where" hidden={!cwd} title={cwd}>
        {cwd}
      </div>
    </div>
  );
}

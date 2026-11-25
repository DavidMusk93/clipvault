#!/usr/bin/env python3
"""D0d: lark 聊天 → corpus/lark_messages.jsonl（中间层）+ corpus/lark.txt（编译）。

范围（用户裁决 2026-11-24）：lark-cli 采集用户相关的所有聊天信息统一建模。
- 身份：lark-cli user token（孙明强），199 个群聊+p2p。
- 拉取：每 chat 单游标分页（--page-all --page-limit 1000 = 单次≤5万条），
  断点续传（watermark: lark_progress[chat_id] = page_token | "done"）。
- 中间层 lark_messages.jsonl：一行一条 {message_id, chat_id, chat_name, ts, sender, type, text}，
  message_id 去重 → 编译步可反复重跑。
- 编译：doc = chat×天，行 = "{YYYY-MM-DD} {sender}: {text}"；msg_type 只留
  text/post（post 递归抽文本）；secret 清洗复用 common.clean_text。

用法:
  .venv/bin/python data/export_lark.py fetch     # 拉取（断点续传，可反复跑）
  .venv/bin/python data/export_lark.py compile   # jsonl → corpus/lark.txt
"""
import json
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "corpus"
WATERMARK = OUT / "watermark.json"
JSONL = OUT / "lark_messages.jsonl"
LARK = "lark-cli"
KEEP_TYPES = {"text", "post"}


def wm_read() -> dict:
    return json.loads(WATERMARK.read_text()) if WATERMARK.exists() else {}


def wm_write(wm: dict) -> None:
    WATERMARK.write_text(json.dumps(wm, ensure_ascii=False, indent=1))


def lark_cli_json(args: list[str], timeout: int = 900) -> dict:
    r = subprocess.run([LARK] + args, capture_output=True, text=True, timeout=timeout)
    for stream in (r.stdout, r.stderr):
        out = (stream or "").strip()
        if out and out.lstrip().startswith("{"):
            try:
                return json.loads(out)   # 失败响应也是 JSON（{ok:false,error}），交给调用方分类
            except Exception:
                continue
    raise RuntimeError(f"lark-cli {args[:3]}: rc={r.returncode} {(r.stderr or '')[-200:]}")


def list_chats() -> list[dict]:
    d = lark_cli_json(["im", "+chat-list", "--types=p2p,group", "--page-all"])
    return d.get("data", {}).get("chats", [])


def post_text(content) -> str:
    """post 富文本 → 纯文本行。content 可能是 str(JSON) 或 dict。"""
    try:
        obj = json.loads(content) if isinstance(content, str) else content
    except Exception:
        return str(content or "")
    lines_out = []
    title = obj.get("title")
    if title:
        lines_out.append(str(title))

    def walk(nodes):
        out = []
        for n in nodes or []:
            if not isinstance(n, dict):
                continue
            tag = n.get("tag")
            if tag == "text":
                out.append(n.get("text", ""))
            elif tag == "a":
                out.append(f"{n.get('text','')}({n.get('href','')})" if n.get("href") else n.get("text", ""))
            elif tag == "at":
                out.append(f"@{n.get('user_name','')}")
            elif tag in ("img", "media", "emotion", "file"):
                pass
            elif tag == "br":
                pass
        return "".join(out)

    for block in obj.get("content", []):
        line = walk(block)
        if line.strip():
            lines_out.append(line.strip())
    return "\n".join(lines_out)


def fetch_chat(chat: dict, wm: dict) -> str:
    """单个 chat 全量拉取（断点续传）。返回状态 done|partial|error"""
    chat_id = chat["chat_id"]
    prog = wm.setdefault("lark_progress", {}).setdefault(chat_id, {})
    token = prog.get("token")
    w = JSONL.open("a", encoding="utf-8")
    n_total = 0
    try:
        while True:
            args = ["im", "+chat-messages-list", "--chat-id", chat_id,
                    "--order", "asc", "--page-all", "--page-limit", "200",
                    "--page-delay", "150"]   # 200 页≈1 万条/批：单次子进程 <3min，游标由 watermark 续
            if token:
                args += ["--page-token", token]
            d = lark_cli_json(args)
            if not d.get("ok", True):
                err = d.get("error") or {}
                if err.get("code") == 231203:   # 受限模式群（禁止复制/转发）→ 跳过
                    prog["status"] = "restricted"
                    return "restricted"
                raise RuntimeError(f"api {err.get('code')}: {err.get('message','')[:150]}")
            msgs = d.get("data", {}).get("messages", [])
            token = d.get("data", {}).get("page_token")
            has_more = bool(d.get("data", {}).get("has_more")) and bool(token)
            for m in msgs:
                if m.get("deleted"):
                    continue
                mt = m.get("msg_type")
                if mt not in KEEP_TYPES:
                    continue
                content = m.get("content")
                text = post_text(content) if mt == "post" else (
                    content if isinstance(content, str) else "")
                if not text.strip():
                    continue
                sender = ((m.get("sender") or {}).get("name") or "").strip() or "?"
                ts = m.get("create_time") or ""
                w.write(json.dumps({
                    "message_id": m.get("message_id"), "chat_id": chat_id,
                    "chat_name": chat.get("name") or "", "ts": ts,
                    "sender": sender, "msg_type": mt, "text": text,
                }, ensure_ascii=False) + "\n")
            n_total += len(msgs)
            w.flush()   # 逐批落盘：进程被杀不丢整批（message_id 去重兑底）
            prog["last_count"] = prog.get("last_count", 0) + len(msgs)
            if not has_more:
                prog["token"] = None
                prog["status"] = "done"
                return "done"
            prog["token"] = token
            prog["status"] = "partial"
            wm_write(wm)   # 每轮存档游标，进程被杀可续
    finally:
        w.close()
        wm_write(wm)


def fetch() -> dict:
    wm = wm_read()
    chats = list_chats()
    stats = {"chats": len(chats), "done": 0, "partial": 0, "error": 0,
             "restricted": 0, "skipped": 0, "errors": []}
    for i, chat in enumerate(chats):
        cid = chat["chat_id"]
        prog = wm.get("lark_progress", {}).get(cid, {})
        if prog.get("status") == "done":
            stats["skipped"] += 1
            continue
        try:
            st = fetch_chat(chat, wm)
            stats[st] = stats.get(st, 0) + 1
        except Exception as e:
            stats["error"] += 1
            stats["errors"].append(f"{cid}: {e}")
            wm.setdefault("lark_progress", {}).setdefault(cid, {})["status"] = "error"
        if (i + 1) % 10 == 0:
            wm_write(wm)
            print(f"[{i+1}/{len(chats)}] {chat.get('name','')[:20]} done={stats['done']} err={stats['error']}", flush=True)
    wm_write(wm)
    print("fetch stats:", json.dumps({k: v for k, v in stats.items() if k != 'errors'}, ensure_ascii=False), flush=True)
    for e in stats["errors"][:10]:
        print("err:", e, flush=True)
    return stats


def compile_corpus() -> dict:
    """jsonl → doc=chat×天 → corpus/lark.txt"""
    by_doc = defaultdict(list)
    seen = set()
    n_lines = 0
    for line in JSONL.open(encoding="utf-8"):
        try:
            m = json.loads(line)
        except Exception:
            continue
        mid = m.get("message_id")
        if mid and mid in seen:
            continue
        seen.add(mid)
        text = clean_text(m["text"])
        if not text.strip():
            continue
        day = (m.get("ts") or "")[:10]
        doc_key = f"{m.get('chat_name') or m['chat_id']} · {day}"
        body = text if "\n" not in text else text
        by_doc[doc_key].append(f"{day} {m['sender']}: {body}")
        n_lines += 1
    docs = []
    for key, lines in sorted(by_doc.items()):
        doc = f"## {key}\n" + "\n".join(lines)
        if len(doc) >= 20:
            docs.append(clean_text(doc))
    (OUT / "lark.txt").write_text(docs_to_corpus(docs), encoding="utf-8")
    return {"messages": n_lines, "docs": len(docs),
            "bytes": (OUT / "lark.txt").stat().st_size}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "fetch"
    print(json.dumps(fetch() if cmd == "fetch" else compile_corpus(),
                     ensure_ascii=False, indent=1, default=str))

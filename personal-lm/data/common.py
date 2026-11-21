"""personal-lm 语料清洗公共库。

铁律（见 ../PRIVACY.md）：
- 剪贴板/nmem 常含密码、token、内网凭据 → 行级 secret 过滤后再进语料。
- 语料文件只落本地 corpus/，绝不入库。
"""
import re
import unicodedata
from datetime import datetime, timezone

# ---- secret 正则（行级过滤：命中即丢弃该行）----
SECRET_PATTERNS = [
    re.compile(r"(?i)\b(pass(word|wd)?|pwd|secret|api[_-]?key|access[_-]?key|token|cred(ential)?s?)\b\s*[:=＝]\s*\S"),
    re.compile(r"\bsk-[A-Za-z0-9]{16,}\b"),                # openai/通用 sk-
    re.compile(r"\bgh[pouhr]_[A-Za-z0-9]{20,}\b"),          # github
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),                    # aws
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),        # slack
    re.compile(r"\bnmem_[A-Za-z0-9]{20,}\b"),               # nmem key（记忆 ID 带下划线，不误伤）
    re.compile(r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\b"),  # JWT
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=|-]{20,}\b"),
    re.compile(r"(?im)^-----BEGIN [A-Z ]*PRIVATE KEY-----$"),
    re.compile(r"(?i)\bpostgres(ql)?://[^\s]*:[^\s@]*@"),
    re.compile(r"(?i)\bmysql://[^\s]*:[^\s@]*@"),
    re.compile(r"(?i)\bpw(or)?d\s*[:=＝]\s*\S"),
    re.compile(r"(?i)\b密(码|钥)\s*[:=：]\s*\S"),
    re.compile(r"\b[Bb]earer\s+[A-Za-z0-9._~+/=|-]{20,}\b"),
]
SECRET_PLACEHOLDER = "[filtered]"

# ---- 结构噪声（整行丢弃）----
NOISE_PATTERNS = [
    re.compile(r"(?i)^\s*(cookie|set-cookie|authorization|x-api-key)\s*:"),  # header
    re.compile(r"^\s*\[?filtered\]?\s*$"),
]


def clean_line(line: str) -> str | None:
    """返回清洗后的行；None 表示丢弃。"""
    for pat in SECRET_PATTERNS:
        if pat.search(line):
            # 不整行丢：保留结构感，替换命中段
            line = pat.sub(SECRET_PLACEHOLDER, line)
    for pat in NOISE_PATTERNS:
        if pat.search(line):
            return None
    return line


def clean_text(text: str) -> str:
    """文档级清洗：NFC 归一 → 逐行过滤 → 压缩 >2 连续空行。"""
    if not text:
        return ""
    text = unicodedata.normalize("NFC", text)
    out_lines = []
    for raw in text.splitlines():
        line = raw.replace("\t", " ").rstrip()
        kept = clean_line(line)
        if kept is not None and kept.strip():
            out_lines.append(kept)
    # 压缩 3+ 连续空行为 1 空行
    collapsed = []
    blank = 0
    for ln in out_lines:
        if ln.strip() == "":
            blank += 1
            if blank <= 1:
                collapsed.append("")
        else:
            blank = 0
            collapsed.append(ln)
    return "\n".join(collapsed).strip()


def is_promising(text: str, min_chars: int = 12) -> bool:
    """太短的碎片（复制按钮文字、单个 URL 等）训练价值低。"""
    return len(text) >= min_chars


DOC_SEPARATOR = "\n\n<|doc|>\n\n"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def docs_to_corpus(docs: list[str]) -> str:
    return DOC_SEPARATOR.join(d for d in docs if d)

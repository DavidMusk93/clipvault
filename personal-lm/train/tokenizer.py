#!/usr/bin/env python3
"""D1: personal-lm BPE tokenizer —— 从零实现（无 HF 依赖）。

设计：
- byte-level BPE，base 256 + special tokens
- 预切分（pre-tokenize）：中文 run 按 2 字一切（限制 merge 跨度、加速训练），
  拉丁字母 run 整体一块，数字 3 位一块，空白/标点一块
- 训练优化：unique chunk 去重 + pair→chunk 倒排索引 + lazy heap，
  只重扫含当前最大 pair 的 chunk（比 minbpe 教学版快 ~100x）
- 词表 ~16384：<|doc|> 文档分隔符是 special token id=256

CLI：
  train    --corpus corpus/all.txt --vocab-size 16384
  encode   --text "..." | --corpus corpus/all.txt --out corpus/tokens.bin
  test     # roundtrip 自测
"""
import argparse
import base64
import heapq
import json
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import regex

HERE = Path(__file__).resolve().parent
TOKENIZER_JSON = HERE.parent / "corpus" / "tokenizer.json"

SPECIALS = ["<|doc|>"]  # id 从 256 依次分配

# ---- 预切分 ----
SPLIT_RE = regex.compile(
    r"(\p{Han}+)"                 # 1 中文 run
    r"|([\p{L}\p{M}]+)"           # 2 拉丁/字母 run
    r"|(\p{N}{1,3})"              # 3 数字 1-3 位
    r"|( ?[^\s\p{L}\p{N}\p{Han}]+[\r\n]*)"  # 4 标点/符号（可带前导空格）
    r"|(\s+)"                     # 5 空白
)


def pretokenize(text: str) -> list[str]:
    """文本 → chunk 字符串列表。中文 run 每 2 字一块（尾单字一块）。"""
    chunks: list[str] = []
    for m in SPLIT_RE.finditer(text):
        kind = m.lastindex
        s = m.group(0)
        if kind == 1:  # Han run → 2字块
            for i in range(0, len(s) - 1, 2):
                chunks.append(s[i : i + 2])
            if len(s) % 2:
                chunks.append(s[-1])
        else:
            chunks.append(s)
    return chunks


class BPETokenizer:
    def __init__(self):
        self.vocab: dict[int, bytes] = {}       # id -> bytes
        self.ranks: dict[tuple[int, int], int] = {}  # (a,b) -> merge_id
        self.special_ids: dict[str, int] = {}

    # ---------- 训练 ----------
    def train(self, text: str, vocab_size: int = 16384, verbose: bool = True):
        t0 = time.time()
        chunks = pretokenize(text)
        counts = Counter(chunks)
        if verbose:
            print(f"[tok] {len(chunks)} chunks, {len(counts)} unique "
                  f"({time.time()-t0:.1f}s)")

        # id 分配：0-255 bytes，specials，然后 merges
        for i in range(256):
            self.vocab[i] = bytes([i])
        next_id = 256
        for sp in SPECIALS:
            self.special_ids[sp] = next_id
            self.vocab[next_id] = sp.encode("utf-8")
            next_id += 1

        # unique chunk → token 序列（加权）
        weights: dict[int, int] = {}
        seqs: dict[int, list[int]] = {}
        key2id: dict[str, int] = {}
        for ck, w in counts.items():
            cid = len(key2id)
            key2id[ck] = cid
            seqs[cid] = list(ck.encode("utf-8"))
            weights[cid] = w

        pair_counts: Counter = Counter()
        pair_index: defaultdict[tuple[int, int], set[int]] = defaultdict(set)

        def add_seq(cid: int, seq: list[int], sign: int):
            w = weights[cid] * sign
            for a, b in zip(seq, seq[1:]):
                pair_counts[(a, b)] += w
                if sign > 0:
                    pair_index[(a, b)].add(cid)

        for cid, seq in seqs.items():
            add_seq(cid, seq, +1)

        heap = [(-c, p) for p, c in pair_counts.items() if c > 1]
        heapq.heapify(heap)

        while len(self.vocab) < vocab_size and heap:
            negc, pair = heapq.heappop(heap)
            cnt = pair_counts.get(pair, 0)
            if cnt < 2 or -negc != cnt:      # 过期条目：真值已在堆里
                continue
            a, b = pair
            new_id = len(self.vocab)
            self.vocab[new_id] = self.vocab[a] + self.vocab[b]
            self.ranks[pair] = new_id
            if verbose and (new_id - 256) % 1000 == 0:
                print(f"[tok] merge {new_id-256}: {self.vocab[a]!r}+{self.vocab[b]!r} "
                      f"(count={cnt}, {time.time()-t0:.1f}s)")
            touched = pair_index.pop(pair, set())
            dirty: set[tuple[int, int]] = set()
            for cid in touched:
                seq = seqs[cid]
                # 重扫：先扣除旧 pair 统计，再合并，再加新统计
                old = list(zip(seq, seq[1:]))
                for p in old:
                    pair_counts[p] -= weights[cid]
                    if pair_counts[p] <= 0:
                        del pair_counts[p]
                    dirty.add(p)
                out, i = [], 0
                n = len(seq)
                while i < n:
                    if seq[i] == a and i + 1 < n and seq[i + 1] == b:
                        out.append(new_id)
                        i += 2
                    else:
                        out.append(seq[i])
                        i += 1
                seqs[cid] = out
                new_pairs = list(zip(out, out[1:]))
                for p in new_pairs:
                    pair_counts[p] += weights[cid]
                    pair_index[p].add(cid)
                    dirty.add(p)
            # 本轮变化的 pair 重新入堆（lazy，弹出时校验真值）
            for p in dirty:
                c = pair_counts.get(p, 0)
                if c >= 2 and p not in self.ranks:
                    heapq.heappush(heap, (-c, p))
        if verbose:
            print(f"[tok] done: vocab={len(self.vocab)}, merges={len(self.ranks)}, "
                  f"{time.time()-t0:.1f}s")

    # ---------- 编解码 ----------
    def _encode_chunk(self, chunk_bytes: bytes) -> list[int]:
        ids = list(chunk_bytes)
        while len(ids) >= 2:
            # 找当前 chunk 中 rank 最小的 pair
            best, best_rank = None, None
            for pair in zip(ids, ids[1:]):
                r = self.ranks.get(pair)
                if r is not None and (best_rank is None or r < best_rank):
                    best, best_rank = pair, r
            if best is None:
                break
            a, b = best
            new_id = self.ranks[best]
            out, i = [], 0
            while i < len(ids):
                if ids[i] == a and i + 1 < len(ids) and ids[i + 1] == b:
                    out.append(new_id)
                    i += 2
                else:
                    out.append(ids[i])
                    i += 1
            ids = out
        return ids

    def encode(self, text: str, allow_special: bool = True) -> list[int]:
        ids: list[int] = []
        if allow_special:
            # special token 作为整体边界
            parts = re.split("(" + "|".join(re.escape(s) for s in self.special_ids) + ")", text)
        else:
            parts = [text]
        for part in parts:
            if not part:
                continue
            if part in self.special_ids:
                ids.append(self.special_ids[part])
                continue
            for ck in pretokenize(part):
                ids.extend(self._encode_chunk(ck.encode("utf-8")))
        return ids

    def decode(self, ids: list[int]) -> str:
        data = b"".join(self.vocab[int(i)] for i in ids)
        return data.decode("utf-8", errors="replace")

    # ---------- 存取 ----------
    def save(self, path: Path):
        payload = {
            "format": "personal-lm-bpe-v1",
            "specials": self.special_ids,
            "vocab": {str(k): base64.b64encode(v).decode() for k, v in self.vocab.items()},
            "ranks": [[a, b, r] for (a, b), r in self.ranks.items()],
        }
        path.write_text(json.dumps(payload, ensure_ascii=False))

    @classmethod
    def load(cls, path: Path) -> "BPETokenizer":
        t = cls()
        d = json.loads(path.read_text())
        assert d["format"] == "personal-lm-bpe-v1"
        t.special_ids = d["specials"]
        t.vocab = {int(k): base64.b64decode(v) for k, v in d["vocab"].items()}
        t.ranks = {(a, b): r for a, b, r in d["ranks"]}
        return t


def cmd_train(args):
    text = Path(args.corpus).read_text(encoding="utf-8")
    # 采样 ~4MB：按文档抽，保留结构（逐字符 stride 会打碎文本）
    if len(text) > 4_000_000:
        docs = [d for d in text.split("<|doc|>") if d.strip()]
        step = max(1, len(docs) * 6 // 4_000_000 * 1_000_000)  # 粗略
        # 改为直接均匀抽文档至 ~4MB
        total = sum(len(d) for d in docs)
        keep_ratio = 4_000_000 / total
        step = max(1, int(1 / keep_ratio))
        picked, acc = [], 0
        for i, d in enumerate(docs):
            if i % step == 0 and acc < 4_400_000:
                picked.append(d)
                acc += len(d)
        text = "<|doc|>".join(picked)
    tok = BPETokenizer()
    tok.train(text, vocab_size=args.vocab_size)
    TOKENIZER_JSON.parent.mkdir(parents=True, exist_ok=True)
    tok.save(TOKENIZER_JSON)
    print(f"[tok] saved → {TOKENIZER_JSON} ({TOKENIZER_JSON.stat().st_size//1024}KB)")
    # 自测 roundtrip
    cmd_test(args)


def cmd_test(args):
    tok = BPETokenizer.load(TOKENIZER_JSON)
    samples = [
        "我在clipvault 中记录了大量的文字，截图、笔记、对话。",
        "TUDP Cube relax_stream recovery: WAL COMMIT write/lseek not pwrite64.",
        "# clipvault &语言模型\n- 打字自动补全 & 生成个人风格文字 <|doc|> 下一文档",
        "def train(model, opt): loss.backward(); opt.step()",
        "2026-11-21 15:53:00 INFO access_log.go:58 ti.observe.backend",
    ]
    for s in samples:
        ids = tok.encode(s)
        back = tok.decode(ids)
        assert back == s, f"roundtrip 失败: {s!r} != {back!r}"
        print(f"[tok test] OK len={len(ids):4d} compression={len(s.encode('utf-8'))/len(ids):.2f}B/tok | {s[:30]!r}")
    # special token 往返
    ids = tok.encode("a<|doc|>b")
    assert tok.decode(ids) == "a<|doc|>b"
    print("[tok test] special roundtrip OK")


def cmd_encode(args):
    tok = BPETokenizer.load(TOKENIZER_JSON)
    if args.text:
        ids = tok.encode(args.text)
        print(ids[:64], "...", f"total={len(ids)}")
        return
    # 全语料 → tokens.bin（uint16，按 <|doc|> 分隔）
    text = Path(args.corpus).read_text(encoding="utf-8")
    docs = text.split("<|doc|>")
    t0 = time.time()
    cache: dict[str, list[int]] = {}
    out = bytearray()
    import numpy as np
    n_tok = 0
    with open(args.out, "wb") as f:
        buf = []
        for di, doc in enumerate(docs):
            if di:
                buf.append(tok.special_ids["<|doc|>"])
            for ck in pretokenize(doc):
                got = cache.get(ck)
                if got is None:
                    got = tok._encode_chunk(ck.encode("utf-8"))
                    cache[ck] = got
                buf.extend(got)
            if len(buf) > 4_000_000:
                arr = np.asarray(buf, dtype=np.uint16)
                f.write(arr.tobytes()); n_tok += len(buf); buf = []
        if buf:
            arr = np.asarray(buf, dtype=np.uint16)
            f.write(arr.tobytes()); n_tok += len(buf)
    print(f"[tok] {args.out}: {n_tok} tokens ({time.time()-t0:.0f}s)")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("train"); t.add_argument("--corpus", required=True)
    t.add_argument("--vocab-size", type=int, default=16384)
    e = sub.add_parser("encode"); e.add_argument("--corpus"); e.add_argument("--text"); e.add_argument("--out", default="corpus/tokens.bin")
    sub.add_parser("test")
    args = ap.parse_args()
    {"train": cmd_train, "encode": cmd_encode, "test": cmd_test}[args.cmd](args)


if __name__ == "__main__":
    main()

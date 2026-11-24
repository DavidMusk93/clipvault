#!/usr/bin/env python3
"""serve_mlx.py — personal-lm 的 MLX 推理服务（替代 candle 的 dispatch 开销瓶颈）。

背景（2026-11-23 实测）：candle 逐 token 前向 ≈500 次 op dispatch，Metal/CPU 都只有
~46 tok/s（sys 时间 > 墙钟，内核同步自旋），98M 理论上应数百 tok/s。
MLX 惰性图 + 单次 eval：没有逐 op 开销。

架构：模型即标准 GPT-2（learned pos_emb、ln→attn→res、gelu-erf、ln_f→head），
权重 (out,in) 与 mlx nn.Linear 一致，零转置；tokenizer 复用 train/tokenizer.py。

  .venv/bin/python personal-lm/mlx/serve_mlx.py --port 8787 [--fp16/--fp32]
  curl :8787/complete -d '{"prefix":"...","max_tokens":16}'
  curl :8787/metrics

语义与 cv-lm ghost 对齐：贪心、行尾即停（标点+\n 合体 token 先吐后停）、
特殊 token 截停、首 token 置信度门控（CVLM_GHOST_MIN_CONF，默认 0.55）、
生成中途低置信截断（token 概率 < 0.15 → 停在该 token 前，不输出半截胡话），
前缀 KV 复用（连续请求只 prefill 增量）。

metrics：每请求追加 JSONL 到 Keepsake/logs/cv-lm-mlx.jsonl，/metrics 聚合。
日志化而非打点探测（发现劣化靠 tail/grep 日志与 /metrics，不靠主动探针）。

线程模型：MLX 的 stream/device 上下文是 thread-local —— 加载与全部计算固定在
一个 worker 线程，HTTP handler 只投递任务（天然串行化，不互踩 KV cache）。
"""
import argparse
import json
import math
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "train"))
from tokenizer import BPETokenizer  # noqa: E402

DEFAULT_BUNDLE = Path.home() / "Library/Application Support/Keepsake/models/personal-lm"
LOG_PATH = Path.home() / "Library/Application Support/Keepsake/logs/cv-lm-mlx.jsonl"


# ---------------- 模型 ----------------
class Block(nn.Module):
    def __init__(self, d: int, heads: int):
        super().__init__()
        self.d, self.h = d, heads
        self.ln1 = nn.LayerNorm(d, eps=1e-5)
        self.qkv = nn.Linear(d, 3 * d, bias=True)
        self.proj = nn.Linear(d, d, bias=True)
        self.ln2 = nn.LayerNorm(d, eps=1e-5)
        self.fc = nn.Linear(d, 4 * d, bias=True)
        self.mlpproj = nn.Linear(4 * d, d, bias=True)

    def __call__(self, x, cache, pos0):
        T = x.shape[1]
        h = self.ln1(x)
        q, k, v = self.qkv(h).split(3, axis=-1)
        dh = self.d // self.h
        q = q.reshape(1, T, self.h, dh).transpose(0, 2, 1, 3)
        k = k.reshape(1, T, self.h, dh).transpose(0, 2, 1, 3)
        v = v.reshape(1, T, self.h, dh).transpose(0, 2, 1, 3)
        kc = k if cache[0] is None else mx.concatenate([cache[0], k], axis=2)
        vc = v if cache[1] is None else mx.concatenate([cache[1], v], axis=2)
        cache[0], cache[1] = kc, vc
        total = kc.shape[2]
        mask = None
        if T > 1:
            # 屏蔽"未来"位置（j > pos0+i）→ -1e9；允许位保持 0。
            # （曾写反成 <=：把允许位乘 -1e9、放行未来 → attention 只看未来，输出垃圾）
            blocked = mx.arange(total)[None, :] > (pos0 + mx.arange(T))[:, None]
            mask = (blocked * -1e9).astype(x.dtype)  # decode(T=1) 全历史可见，无需 mask
        y = mx.fast.scaled_dot_product_attention(q, kc, vc, scale=1 / math.sqrt(dh), mask=mask)
        y = y.transpose(0, 2, 1, 3).reshape(1, T, self.d)
        x = x + self.proj(y)
        x = x + self.mlpproj(nn.gelu(self.fc(self.ln2(x))))
        return x


class GPT(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        d = cfg["d_model"]
        self.cfg = cfg
        self.tok_emb = nn.Embedding(cfg["vocab_size"], d)
        self.pos_emb = nn.Embedding(cfg["block_size"], d)
        self.blocks = [Block(d, cfg["n_head"]) for _ in range(cfg["n_layer"])]
        self.ln_f = nn.LayerNorm(d, eps=1e-5)
        self.head = nn.Linear(d, cfg["vocab_size"], bias=False)

    def __call__(self, ids, pos0, caches):
        x = self.tok_emb(ids) + self.pos_emb(mx.arange(pos0, pos0 + ids.shape[1]))[None]
        for blk, c in zip(self.blocks, caches):
            x = blk(x, c, pos0)
        return self.head(self.ln_f(x))  # (1,T,V)


# ---------------- 服务 ----------------
class Svc:
    def __init__(self, bundle: Path, fp16: bool):
        self._bundle = bundle
        self.stats = {"req": 0, "empty": 0, "tokens": 0}
        # MLX 的 stream/device 上下文是 thread-local：加载与全部计算固定在同一
        # worker 线程，handler 线程只投递任务（天然串行化，不互踩 KV cache）
        self._q = queue.Queue()
        self._ready = threading.Event()
        self._load_err = None
        self._worker = threading.Thread(target=self._work, daemon=True)
        self._worker.start()
        ch = queue.Queue()
        self._q.put((self._load_impl, (bundle, fp16), ch))
        kind, val = ch.get()
        if kind == "err":
            raise val
        self._ready.set()
        print(f"[cv-lm-mlx] bundle={bundle} fp16={self.fp16} loaded", flush=True)

    def _work(self):
        # 前段：等待加载任务；加载成功后进入常驻服务循环
        while not self._ready.is_set():
            fn, args, ch = self._q.get()
            try:
                ch.put(("ok", fn(*args)))
            except BaseException as e:  # noqa: BLE001
                ch.put(("err", e))
                self._load_err = e
                return
        while True:
            fn, args, ch = self._q.get()
            try:
                ch.put(("ok", fn(*args)))
            except BaseException as e:  # noqa: BLE001
                ch.put(("err", e))

    def _load_impl(self, bundle: Path, fp16: bool):
        cfgd = json.load(open(bundle / "config.json"))["model"]
        self.tok = BPETokenizer.load(bundle / "tokenizer.json")
        self.specials = set(json.load(open(bundle / "tokenizer.json")).get("specials", {}).keys())
        remap = {"attn.qkv": "qkv", "attn.proj": "proj", "mlp.fc": "fc", "mlp.proj": "mlpproj"}
        params = []
        for k, w in mx.load(str(bundle / "model.safetensors")).items():
            for a, b in remap.items():
                k = k.replace(a, b)
            w = mx.array(w)
            if fp16:
                w = w.astype(mx.float16)
            params.append((k, w))
        self.model = GPT(cfgd)
        self.model.load_weights(params)
        mx.eval(self.model.tok_emb.weight)  # 实际完成加载
        self.block_size = cfgd["block_size"]
        self.nl = cfgd["n_layer"]
        self.ctx = None  # (ids, caches)
        self.fp16 = fp16

    def new_caches(self):
        return [[None, None] for _ in range(self.nl)]

    def complete(self, prefix: str, max_tokens: int, min_conf: float):
        if not self._ready.wait(timeout=60):
            raise RuntimeError(f"model load failed: {self._load_err}")
        ch = queue.Queue()
        self._q.put((self._complete_impl, (prefix, max_tokens, min_conf), ch))
        kind, val = ch.get()
        if kind == "err":
            raise val
        return val

    def _q_sync(self, fn):
        ch = queue.Queue()
        self._q.put((fn, (), ch))
        kind, val = ch.get()
        if kind == "err":
            raise val
        return val

    def _debug_top(self, prefix):
        ids = self.tok.encode(prefix)
        caches = self.new_caches()
        logits = self._forward(ids, 0, caches)
        lv = logits.astype(mx.float32)
        top = mx.argsort(-lv)[:8]
        return [(int(i), float(lv[i])) for i in top]

    def _forward(self, ids_list, pos0, caches):
        ids = mx.array([ids_list])
        logits = self.model(ids, pos0, caches)
        return logits[0, -1]

    def _complete_impl(self, prefix: str, max_tokens: int, min_conf: float):
        t0 = time.time()
        ids = self.tok.encode(prefix)
        keep = self.block_size - max_tokens
        if len(ids) > keep:
            ids = ids[len(ids) - keep:]
        caches = self.new_caches()
        start = 0
        if self.ctx is not None:
            prev_ids, prev_caches = self.ctx
            common = 0
            for a, b in zip(prev_ids, ids):
                if a != b:
                    break
                common += 1
            # 与上次 prompt 完全相同（无增量）→ 冷路径；缓存里没有"下一 token"logits
            if common >= 16 and common < len(ids) and common + max_tokens < self.block_size:
                caches = [[pk[:, :, :common, :], pv[:, :, :common, :]] for pk, pv in prev_caches]
                start = common
        out_ids = []
        stop = "max_tokens"
        conf = None
        probs = []
        logits = self._forward(ids, start, caches)  # 冷全量 / 热增量，同一入口
        t_prefill = time.time() - t0
        for _ in range(max_tokens):
            lv = logits.astype(mx.float32)
            top = mx.argmax(lv).item()
            p = mx.softmax(lv).max().item()
            if conf is None:
                conf = p
                if p < min_conf:
                    stop = "low_conf"
                    self.stats["empty"] += 1
                    break
            # 中途门控：贪心也会在句中骑墙（概率骤降=模型不知道接什么），
            # 在吐出该 token 前截断 → 宁短勿错，不输出后半截胡话
            probs.append(p)
            if p < 0.15:
                stop = "mid_conf"
                break
            if top == 0:
                stop = "eos"
                break
            piece = self.tok.decode([top])
            if "<|" in piece or piece in self.specials:
                stop = "special"
                break
            out_ids.append(top)
            self.stats["tokens"] += 1
            if "\n" in piece:
                stop = "newline"
                break
            # pos0 = cache 长度：prefill 覆盖 [0, len(ids))，out_ids.append 后已有
            # len(out_ids) 个已生成 token → 下一个 token 位置 = len(ids)+len(out_ids)-1
            # （曾差一 → 位置漂移 → 输出垃圾）
            logits = self._forward([top], len(ids) + len(out_ids) - 1, caches)
        self.ctx = (ids + out_ids, caches)
        dt = time.time() - t0
        text = self.tok.decode(out_ids)
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "prefix_chars": len(prefix), "prompt_tokens": len(ids),
               "reuse": start > 0, "tokens": len(out_ids), "conf": round(conf or 0, 3),
               "stop": stop, "latency_ms": round(dt * 1000),
               "prefill_ms": round(t_prefill * 1000), "fp16": self.fp16}
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.stats["req"] += 1
        return text, rec


# ---------------- HTTP ----------------
class Handler(BaseHTTPRequestHandler):
    svc = None
    min_conf = 0.55

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-headers", "content-type")
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        if self.path.startswith("/metrics"):
            self._send(200, {"stats": Handler.svc.stats, "log": str(LOG_PATH)})
        elif self.path.startswith("/debug"):
            import urllib.parse
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            prefix = qs.get("prefix", [""])[0]
            ids = Handler.svc.tok.encode(prefix)
            res = Handler.svc._q_sync(lambda: Handler.svc._debug_top(prefix))
            self._send(200, {"prompt_tokens": len(ids),
                             "top8": [(int(i), round(float(v), 2)) for i, v in res]})
        elif self.path.startswith("/health"):
            self._send(200, {"status": "ok", "server": "cv-lm-mlx", "fp16": Handler.svc.fp16})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/complete"):
            self._send(404, {"error": "not found"})
            return
        n = int(self.headers.get("content-length") or 0)
        v = json.loads(self.rfile.read(n) or b"{}")
        prefix = v.get("prefix") or v.get("prompt") or ""
        if not prefix.strip():
            self._send(400, {"error": "prefix required"})
            return
        mt = int(v.get("max_tokens") or 16)
        text, rec = Handler.svc.complete(prefix, max(1, min(mt, 60)), Handler.min_conf)
        self._send(200, {"completion": text, "source": "lm-mlx",
                         "version": f"mlx-v20000-fp{16 if Handler.svc.fp16 else 32}",
                         "meta": rec})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--bundle", default=str(DEFAULT_BUNDLE))
    ap.add_argument("--fp16", action="store_true", default=True)
    ap.add_argument("--fp32", dest="fp16", action="store_false")
    ap.add_argument("--min-conf", type=float,
                    default=float(os.environ.get("CVLM_GHOST_MIN_CONF", "0.55")))
    args = ap.parse_args()
    Handler.svc = Svc(Path(args.bundle), args.fp16)
    Handler.min_conf = args.min_conf
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

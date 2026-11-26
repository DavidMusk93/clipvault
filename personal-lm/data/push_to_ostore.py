#!/usr/bin/env python3
"""push_to_ostore.py — 把本地文件分片并行推 ostore（PUT /api/files/，回读校验）。

用法: .venv/bin/python data/push_to_ostore.py <local> <remote_dir> [workers=4]
remote 文件 = <remote_dir>/<basename>.partNN；Colab 侧 cat 拼回。
token 每次经 ssh cc 临时读取，不落盘。
"""
import hashlib
import json
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PUB = "https://xyz69.top/ostore"
CHUNK = 8 * 1024 * 1024


def token() -> str:
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "cc",
                        "grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip()


def put_chunk(t: str, path: str, data: bytes) -> tuple[str, int, bool]:
    req = urllib.request.Request(f"{PUB}/api/files/{path}", data=data, method="PUT",
                                 headers={"Authorization": f"Bearer {t}", "User-Agent": "curl/8.7.1"})
    with urllib.request.urlopen(req, timeout=300) as r:
        ok = r.status == 200
    # 回读校验（PUT 200≠到齐）
    with urllib.request.urlopen(urllib.request.Request(
            f"{PUB}/api/files/{path}", headers={"Authorization": f"Bearer {t}", "User-Agent": "curl/8.7.1"}),
            timeout=300) as r:
        back = r.read()
    return path, len(back), ok and len(back) == len(data)


def put_chunk_retry(t: str, path: str, data: bytes, retries: int = 4) -> tuple[str, int, bool]:
    import time as _t
    delay = 5
    last = None
    for _ in range(retries):
        try:
            return put_chunk(t, path, data)
        except Exception as e:
            last = e
            _t.sleep(delay)
            delay = min(delay * 2, 60)
    raise RuntimeError(f"put {path} failed after {retries} retries: {last}")


def push(local: Path, remote_dir: str, workers: int = 4) -> dict:
    t = token()
    name = local.name
    data = local.read_bytes()
    total_md5 = hashlib.md5(data).hexdigest()
    chunks = [(data[i:i + CHUNK], idx) for idx, i in enumerate(range(0, len(data), CHUNK))]
    jobs = []
    for idx, (c, i) in enumerate(chunks):
        jobs.append((f"{remote_dir}/{name}.part{i:03d}", c))
    t0 = time.time()
    done = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(put_chunk_retry, t, p, c): (p, len(c)) for p, c in jobs}
        for fut in futs:
            pass
        for fut in list(futs):
            path, size, ok = fut.result()
            if not ok:
                raise RuntimeError(f"push verify failed: {path}")
            done += 1
            if done % 10 == 0 or done == len(jobs):
                print(f"[push] {done}/{len(jobs)} parts "
                      f"({done * CHUNK // 1024 // 1024}MB, {time.time()-t0:.0f}s)", flush=True)
    manifest = {"file": name, "bytes": len(data), "md5": total_md5,
                "parts": len(jobs), "chunk": CHUNK, "remote_dir": remote_dir}
    # 清单
    body = json.dumps(manifest).encode()
    put_chunk(t, f"{remote_dir}/{name}.manifest.json", body)
    return manifest


if __name__ == "__main__":
    local = Path(sys.argv[1])
    remote_dir = sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    print(json.dumps(push(local, remote_dir, workers), ensure_ascii=False))

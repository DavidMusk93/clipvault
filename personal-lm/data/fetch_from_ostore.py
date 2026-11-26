#!/usr/bin/env python3
"""fetch_from_ostore.py — Colab VM 上从 ostore 并行拉分片拼装（md5 校验）。

用法: python fetch_from_ostore.py <remote_dir>/<name> <local_out> [workers=8]
清单 = <name>.manifest.json（bytes/md5/parts/chunk）。
"""
import hashlib
import json
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PUB = "https://xyz69.top/ostore"
UA = "Mozilla/5.0"


def get(url: str, retries: int = 4) -> bytes:
    delay = 5
    for _ in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except Exception as e:
            last = e
            time.sleep(delay)
            delay = min(delay * 2, 60)
    raise last


def main():
    remote_path = sys.argv[1]          # clipvault/.../train.jsonl
    local = sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    man = json.loads(get(f"{PUB}/api/files/{remote_path}.manifest.json"))
    t0 = time.time()
    base = f"{PUB}/api/files/{remote_path}"

    def one(i):
        return i, get(f"{base}.part{i:03d}")

    parts = {}
    done = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, data in ex.map(one, range(man["parts"])):
            parts[i] = data
            done += 1
            if done % 20 == 0 or done == man["parts"]:
                print(f"[fetch] {done}/{man['parts']} "
                      f"({done * man['chunk'] // 1048576}MB, {time.time()-t0:.0f}s)", flush=True)
    blob = b"".join(parts[i] for i in range(man["parts"]))
    md5 = hashlib.md5(blob).hexdigest()
    assert len(blob) == man["bytes"], f"size {len(blob)} != {man['bytes']}"
    assert md5 == man["md5"], f"md5 {md5} != {man['md5']}"
    open(local, "wb").write(blob)
    print(f"[fetch] OK {local} {len(blob)}B md5={md5} ({time.time()-t0:.0f}s)", flush=True)


if __name__ == "__main__":
    main()

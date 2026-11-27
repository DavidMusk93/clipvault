#!/usr/bin/env python3
"""fetch_from_ostore.py — Colab VM 从 ostore 并行拉分片拼装（md5 校验）。

分片名从 list API 动态发现（兼容 partNNN / part<offset> 两种命名），
按数字后缀排序拼装。用法:
  %%run fetch_from_ostore.py  <remote_dir>/<name>  <local_out>  [workers]
"""
import hashlib
import json
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PUB = "https://xyz69.top/ostore"
UA = "Mozilla/5.0"
import os as _os
TOKEN = _os.environ.get("OSTORE_TOKEN") or (
    open("/content/.ostoken").read().strip() if _os.path.exists("/content/.ostoken") else "")


def get(url: str, retries: int = 4) -> bytes:
    delay = 5
    last = None
    for _ in range(retries):
        try:
            hdrs = {"User-Agent": UA}
            if TOKEN:
                hdrs["Authorization"] = f"Bearer {TOKEN}"
            req = urllib.request.Request(url, headers=hdrs)
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except Exception as e:
            last = e
            time.sleep(delay)
            delay = min(delay * 2, 60)
    raise last


def main():
    remote_path = sys.argv[1]
    local = sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    t0 = time.time()
    base = f"{PUB}/api/files/{remote_path}"
    man = json.loads(get(f"{base}.manifest.json"))
    # 发现真实分片名（同目录下 <name>.part* ）
    d = remote_path.rsplit("/", 1)
    listing = json.loads(get(f"{PUB}/api/list?path={d[0]}"))
    names = [e["name"] for e in listing.get("entries", [])
             if e["name"].startswith(d[1] + ".part") and "manifest" not in e["name"]]
    parts_sorted = sorted(names, key=lambda n: int(re.search(r"part(\d+)$", n).group(1)))
    if len(parts_sorted) != man["parts"]:
        raise RuntimeError(f"remote has {len(parts_sorted)} parts, manifest says {man['parts']}")
    print(f"[fetch] {man['parts']} parts, {man['bytes']//1048576}MB, md5={man['md5'][:8]}…", flush=True)

    dir_url = f"{PUB}/api/files/{d[0]}"
    urls = [f"{dir_url}/{n}" for n in parts_sorted]

    def one(i):
        return i, get(urls[i])

    chunks = {}
    done = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, data in ex.map(one, range(man["parts"])):
            chunks[i] = data
            done += 1
            if done % 40 == 0 or done == man["parts"]:
                print(f"[fetch] {done}/{man['parts']} "
                      f"({done * man['chunk'] // 1048576}MB, {time.time()-t0:.0f}s)", flush=True)
    blob = b"".join(chunks[i] for i in range(man["parts"]))
    md5 = hashlib.md5(blob).hexdigest()
    assert len(blob) == man["bytes"], f"size {len(blob)} != {man['bytes']}"
    assert md5 == man["md5"], f"md5 {md5} != {man['md5']}"
    open(local, "wb").write(blob)
    print(f"[fetch] OK {local} {len(blob)}B md5={md5} ({time.time()-t0:.0f}s)", flush=True)


if __name__ == "__main__":
    main()

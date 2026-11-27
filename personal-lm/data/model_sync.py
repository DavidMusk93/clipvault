#!/usr/bin/env python3
"""model_sync.py — robust 模型同步：mac ⇄ ostore（gdrive 自动镜像）。

设计原则（此前 push 太儿戏的教训）：
- 目录级：一个模型 = 一个目录（safetensors + config + tokenizer 全套），
  manifest 记录每个文件的 bytes/md5/parts，最后原子写 manifest
- 每片 PUT 后回读校验大小；文件级 md5；目录级 manifest 读回验证
- latest.json 指针最后写（其他 agent 通过它发现最新版本）
- pull：manifest → 并行拉片 → 片级 md5 → 文件级 md5 → 临时目录拼装
  → 全部校验通过才原子安装（mv），绝不半成品

用法:
  .venv/bin/python data/model_sync.py push  <local_dir>  <name>   # 推模型
  .venv/bin/python data/model_sync.py pull  <name> [dest_dir]     # 拉并安装
  .venv/bin/python data/model_sync.py latest                      # 看指针
  .venv/bin/python data/model_sync.py versions <name>             # 列版本
"""
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from push_to_ostore import token, CHUNK, put_chunk_retry  # noqa: E402

PUB = "https://xyz69.top/ostore"
ROOT = "clipvault/models/personal-lm/model_versions"


def get_bytes(remote_file: str, retries: int = 4) -> bytes:
    delay = 5
    last = None
    for _ in range(retries):
        try:
            req = urllib.request.Request(f"{PUB}/api/files/{remote_file}",
                headers={"Authorization": f"Bearer {token()}", "User-Agent": "curl/8.7.1"})
            with urllib.request.urlopen(req, timeout=600) as r:
                return r.read()
        except Exception as e:
            last = e
            time.sleep(delay)
            delay = min(delay * 2, 120)
    raise last


def push(local_dir: Path, name: str, workers: int = 6) -> dict:
    files = sorted(p for p in local_dir.rglob("*") if p.is_file())
    if not files:
        raise SystemExit(f"no files in {local_dir}")
    version = time.strftime("%Y%m%d-%H%M%S")
    base = f"{ROOT}/{name}/{version}"
    t = token()
    t0 = time.time()
    entries = []
    for p in files:
        rel = p.relative_to(local_dir).as_posix()
        data = p.read_bytes()
        n = (len(data) + CHUNK - 1) // CHUNK
        parts_meta = []
        # 分片（并行 worker 内部再串行各文件 → 直接并行所有分片）
        jobs = []
        for i in range(n):
            c = data[i * CHUNK:(i + 1) * CHUNK]
            part_path = f"{base}/{rel}.part{i:03d}"
            jobs.append((part_path, c, hashlib.md5(c).hexdigest()))
        with ThreadPoolExecutor(max_workers=workers) as ex:
            for _ in ex.map(lambda j: put_chunk_retry(t, j[0], j[1]), jobs):
                pass  # put_chunk_retry 内含回读校验，异常会抛
        for (part_path, c, md5) in jobs:
            parts_meta.append({"path": part_path.rsplit("/", 1)[-1], "bytes": len(c), "md5": md5})
        entries.append({"path": rel, "bytes": len(data), "md5": hashlib.md5(data).hexdigest(),
                        "chunk": CHUNK, "parts": parts_meta})
        print(f"[push] {rel}: {len(data)//1024//1024}MB / {n} parts", flush=True)
    manifest = {"name": name, "version": version, "pushed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "local": str(local_dir), "files": entries,
                "total_bytes": sum(e["bytes"] for e in entries)}
    body = json.dumps(manifest, ensure_ascii=False).encode()
    put_chunk_retry(t, f"{base}/manifest.json", body)
    # 读回验证 manifest
    back = json.loads(get_bytes(f"{base}/manifest.json"))
    assert back["version"] == version, "manifest read-back mismatch"
    # latest 指针（原子：先写版本文件，再写 latest）
    put_chunk_retry(t, f"{ROOT}/{name}/latest.json", json.dumps(
        {"version": version, "manifest": f"{base}/manifest.json",
         "total_bytes": manifest["total_bytes"],
         "pushed_at": manifest["pushed_at"]}, ensure_ascii=False).encode())
    latest = get_bytes(f"{ROOT}/{name}/latest.json")
    assert json.loads(latest)["version"] == version
    return {"name": name, "version": version, "files": len(entries),
            "total_bytes": manifest["total_bytes"], "seconds": round(time.time() - t0)}


def pull(name: str, dest: Path | None = None, workers: int = 8) -> dict:
    latest = json.loads(get_bytes(f"{ROOT}/{name}/latest.json"))
    print(f"[pull] {name} version={latest['version']}", flush=True)
    man = json.loads(get_bytes(latest["manifest"]))
    t0 = time.time()
    tmp = Path(f"/tmp/model_sync/{name}-{man['version']}")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    all_jobs = []   # (file_entry, tmp_path, [(part_rel, md5)])
    for e in man["files"]:
        ftmp = tmp / e["path"]
        ftmp.parent.mkdir(parents=True, exist_ok=True)
        if e["bytes"] <= e["chunk"]:
            all_jobs.append((e, ftmp, [(f"{e['path']}.part000", None)]))
        else:
            all_jobs.append((e, ftmp, [(f"{e['path']}.part{i:03d}", p["md5"])
                                        for i, p in enumerate(e["parts"])]))
    # 并行下载所有分片（按片）
    def dl(job):
        part_rel, md5 = job
        data = get_bytes(f"{ROOT}/{name}/{man['version']}/{part_rel}")
        if md5:
            assert hashlib.md5(data).hexdigest() == md5, f"part md5 {part_rel}"
        return job, data

    buf = {}
    done = 0
    total_parts = sum(len(j[2]) for j in all_jobs)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for job, data in ex.map(dl, [x for j in all_jobs for x in j[2]]):
            buf[job[0]] = data
            done += 1
            if done % 20 == 0 or done == total_parts:
                print(f"[pull] {done}/{total_parts} parts ({time.time()-t0:.0f}s)", flush=True)
    for e, ftmp, parts in all_jobs:
        blob = b"".join(buf[pr] for pr, _md5 in parts)
        assert hashlib.md5(blob).hexdigest() == e["md5"], f"file md5 {e['path']}"
        ftmp.write_bytes(blob)
        print(f"[pull] {e['path']}: {e['bytes']//1024//1024}MB md5 ok", flush=True)
    # 文件级校验全部通过 → 原子安装
    dest = dest or (Path.home() / "Library/Application Support/Keepsake/models" / name)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.move(str(dest), str(dest) + f".bak-{man['version']}")
    shutil.move(str(tmp), str(dest))
    return {"name": name, "version": man["version"], "installed": str(dest),
            "seconds": round(time.time() - t0)}


def latest_info() -> dict:
    names = set()
    # 简单列出：尝试已知 model 名（无 list API 权限枚举父目录时退化）
    for name in ["personal-mlx-v3", "personal-mlx-v2", "personal-mlx"]:
        try:
            names.add((name, json.loads(get_bytes(f"{ROOT}/{name}/latest.json"))["version"]))
        except Exception:
            pass
    return {n: v for n, v in sorted(names)}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "latest"
    if cmd == "push":
        print(json.dumps(push(Path(sys.argv[2]), sys.argv[3],
              int(sys.argv[4]) if len(sys.argv) > 4 else 6), ensure_ascii=False, indent=1))
    elif cmd == "pull":
        dest = Path(sys.argv[3]) if len(sys.argv) > 3 else None
        print(json.dumps(pull(sys.argv[2], dest,
              int(sys.argv[4]) if len(sys.argv) > 4 else 8), ensure_ascii=False, indent=1))
    elif cmd == "latest":
        print(json.dumps(latest_info(), ensure_ascii=False, indent=1))
    else:
        raise SystemExit(__doc__)

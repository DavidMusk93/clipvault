#!/usr/bin/env python3
"""D0g: 构建纠错资产 → bundle/spell_words.txt + bundle/pinyin_map.json。

- spell_words.txt：历史词表（retrieval_lines）∪ macOS 系统英语词典，
  行 = "<word> <weight>"；weight = 历史出现次数（词典词 = 1，历史词 ≥2 加成）。
- pinyin_map.json：语料中出现过的 CJK 单字 → 无调拼音（pypinyin），
  供 CJK 同音字纠错候选生成。

用法: .venv/bin/python data/build_spell.py
"""
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = Path.home() / "Library/Application Support/Keepsake/models/personal-lm"
RETRIEVAL = BUNDLE / "retrieval_lines.jsonl"
DICTS = [Path("/usr/share/dict/words")]


def latin_words(s: str) -> list[str]:
    out, cur = [], []
    for ch in s:
        if ch.isascii() and (ch.isalnum() or ch in "_-"):
            cur.append(ch)
        else:
            if cur:
                out.append("".join(cur).strip("_-").lower())
                cur = []
    if cur:
        out.append("".join(cur).strip("_-").lower())
    return [w for w in out if len(w) >= 3 and not w.isdigit()]


def main() -> None:
    hist = Counter()
    cjk_chars = set()
    for line in RETRIEVAL.read_text(encoding="utf-8", errors="ignore").splitlines():
        for w in latin_words(line):
            hist[w] += 1
        for ch in line:
            if "\u4e00" <= ch <= "\u9fff":
                cjk_chars.add(ch)

    with (BUNDLE / "spell_words.txt").open("w", encoding="utf-8") as f:
        for w, n in hist.most_common():
            f.write(f"{w} {n}\n")
        n_dict = 0
        for d in DICTS:
            if not d.exists():
                continue
            for w in d.read_text(encoding="utf-8", errors="ignore").split():
                w = w.strip().lower()
                if w.isascii() and w.isalpha() and len(w) >= 3 and "'" not in w:
                    if w not in hist:
                        f.write(f"{w} 1\n")
                        n_dict += 1
    print(f"spell_words: hist={len(hist)} +dict={n_dict}")

    from pypinyin import lazy_pinyin, Style
    # 全量常用字（GB2312 一二级 + 语料字）：错字本身常不在语料里，必须有它的拼音才能纠
    pmap = {}
    chars = set(cjk_chars)
    for cp in range(0x4E00, 0x9FFF + 1):
        chars.add(chr(cp))
    for ch in sorted(chars):
        py = lazy_pinyin(ch, style=Style.NORMAL, errors="ignore")
        if py and py[0].isascii():
            pmap[ch] = py[0]
    (BUNDLE / "pinyin_map.json").write_text(
        json.dumps(pmap, ensure_ascii=False), encoding="utf-8")
    print(f"pinyin_map: {len(pmap)} chars")


if __name__ == "__main__":
    main()

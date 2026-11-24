//! 行级检索索引：给"懂意图"用的本地召回层。
//! 索引 = corpus/retrieval_lines.jsonl（私有，12MB，~15万行）。
//! 查询 = prefix 末尾 ~100 字符的 CJK bigram + 拉丁词 → 倒排计数 → 精确 substring 校验。
//! 命中阈值以上 → 补全直接返回"你上次写的那一行"（相关性远高于小模型采样）。

use crate::anyhow_result::{err, Result};
use std::collections::{HashMap, HashSet};
use std::path::Path;

pub struct Retrieval {
    pub lines: Vec<String>,
    postings: HashMap<u64, Vec<u32>>,
    /// 拉丁词频表（小写→出现次数）：词级补全（英文体验）的词典源
    words: HashMap<String, u32>,
}

fn fnv64(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 查询/索引的词元：CJK 字符 bigram + 拉丁小写词；跳过纯数字（时间戳/ID 噪声）。
fn tokens_of(s: &str) -> Vec<String> {
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_alphabetic() {
            if is_cjk(c) {
                if i + 1 < chars.len() && is_cjk(chars[i + 1]) {
                    out.push(chars[i].to_string() + &chars[i + 1].to_string());
                }
                i += 1;
            } else {
                // 拉丁词
                let start = i;
                while i < chars.len() && chars[i].is_alphanumeric() && !is_cjk(chars[i]) {
                    i += 1;
                }
                let w: String = chars[start..i].iter().collect::<String>().to_lowercase();
                if w.len() >= 3 && !w.chars().all(|c| c.is_ascii_digit()) {
                    out.push(w);
                }
            }
        } else {
            i += 1;
        }
    }
    out.sort();
    out.dedup();
    out
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x2E80..=0x303F | 0x3040..=0x30FF | 0x31C0..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0xFF00..=0xFFEF)
}

/// 行内拉丁词（小写，保留内部数字/下划线，如 arrow2、recall_fs），len>=3
fn latin_words(s: &str) -> impl Iterator<Item = String> {
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_alphabetic() {
            let start = i;
            while i < chars.len()
                && (chars[i].is_ascii_alphanumeric() || chars[i] == '_' || chars[i] == '-')
            {
                i += 1;
            }
            let w: String = chars[start..i].iter().collect::<String>().to_lowercase();
            // 去掉首尾的 '-'/'_'，纯分隔符不算字符
            let core = w.trim_matches(|c| c == '-' || c == '_');
            if core.chars().count() >= 3 && !core.chars().all(|c| c.is_ascii_digit()) {
                out.push(core.to_string());
            }
        } else {
            i += 1;
        }
    }
    out.into_iter()
}

impl Retrieval {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)?;
        let lines: Vec<String> = raw.lines().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        let mut postings: HashMap<u64, Vec<u32>> = HashMap::new();
        let mut words: HashMap<String, u32> = HashMap::new();
        for (i, line) in lines.iter().enumerate() {
            for t in tokens_of(line) {
                postings.entry(fnv64(&t)).or_default().push(i as u32);
            }
            // 词表：只用原始行（不重复去 bigram 顺序影响）里的拉丁词
            for w in latin_words(line) {
                *words.entry(w).or_insert(0) += 1;
            }
        }
        Ok(Self { lines, postings, words })
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// 行级对齐召回（ghost 的正确语义）：用户正在打的这一行（cur）如果恰好是
    /// 索引里某行的前缀 → 返回那行的剩余部分。构造上保证相关性：
    /// 「你在重打一行自己写过的字」→ 补全那行的结尾。
    /// （旧版用 prefix 末尾 100 字符做模糊 bigram 召回 + 0.3 阈值：上一行的内容
    ///  会主导匹配，主题相似就硬塞整行 —— 「应该用」后面被塞进无关 MR 流水账。）
    pub fn query_line(&self, cur: &str) -> Option<String> {
        let cur_trim = cur.trim();
        if cur_trim.chars().count() < 3 {
            return None; // 行首刚起头，信号不足
        }
        let q = tokens_of(cur);
        if q.is_empty() {
            return None;
        }
        // 倒排取候选（足够即可，精确校验在 starts_with）
        let mut cand: HashMap<u32, u32> = HashMap::new();
        for t in &q {
            if let Some(idxs) = self.postings.get(&fnv64(t)) {
                for &i in idxs.iter().take(400) {
                    *cand.entry(i).or_insert(0) += 1;
                }
            }
        }
        let mut best: Option<&String> = None;
        for (i, _) in cand.iter() {
            let line = &self.lines[*i as usize];
            // 命中行必须以"正在打的行"开头（容忍行首空白差异）
            let hit = line.starts_with(cur)
                || line.trim_start().starts_with(cur_trim)
                    && cur.starts_with('-'); // 列表行：索引行可能有 "- " 前缀差异
            if hit {
                let rest = if line.starts_with(cur) {
                    &line[cur.len()..]
                } else {
                    match line.find(cur_trim) {
                        Some(pos) => &line[pos + cur_trim.len()..],
                        None => continue,
                    }
                };
                if !rest.trim().is_empty() {
                    best = Some(line);
                    break;
                }
            }
        }
        best.and_then(|line| {
            let rest = if line.starts_with(cur) {
                line[cur.len()..].to_string()
            } else {
                let pos = line.find(cur_trim)?;
                line[pos + cur_trim.len()..].to_string()
            };
            if rest.trim().is_empty() { None } else { Some(rest) }
        })
    }

    /// 词级补全（英文体验）：partial = 正在打的行尾部未完成的拉丁词（≥2字符）。
    /// 从历史词表里找以它为前缀、频次最高的词，返回剩余部分（保留原词大小写风格）。
    /// 例：`please send me the dep` → `loyment`（deployment）
    pub fn query_word(&self, partial: &str) -> Option<String> {
        let p = partial.to_lowercase();
        if p.chars().count() < 2 {
            return None;
        }
        let mut best: Option<(&String, u32)> = None;
        for (w, n) in self.words.iter() {
            // 必须比 partial 长（补全才有意义），且大小写不敏感前缀匹配
            if w.chars().count() > p.chars().count() && w.starts_with(&p) {
                if best.map(|(_, bn)| *n > bn).unwrap_or(true) {
                    best = Some((w, *n));
                }
            }
        }
        // 词频太低（只出现过 1 次）的噪声不推
        let (w, _n) = best?;
        if self.words.get(w).copied().unwrap_or(0) < 2 {
            return None;
        }
        // 保留用户已打部分的原始大小写：只返回剩余部分（一律小写，
        // 与用户已输入部分拼接后自然呈现，避免大小写错乱）
        Some(w[p.chars().count()..].to_string())
    }

    /// tail = prefix 末尾 ~100 字符。返回 (最佳行, 分数) 或 None。
    /// 分数 = 命中查询词元的候选行比例（精确 substring 校验）。
    #[allow(dead_code)]
    pub fn query(&self, tail: &str) -> Option<(String, f32)> {
        let q = tokens_of(tail);
        if q.len() < 3 {
            return None;
        }
        // 倒排计数取候选
        let mut cand: HashMap<u32, u32> = HashMap::new();
        for t in &q {
            if let Some(idxs) = self.postings.get(&fnv64(t)) {
                for &i in idxs.iter().take(400) {
                    *cand.entry(i).or_insert(0) += 1;
                }
            }
        }
        let mut top: Vec<(u32, u32)> = cand.into_iter().collect();
        top.sort_by(|a, b| b.1.cmp(&a.1));
        top.truncate(24);
        // 精确校验 + 评分
        let qset: HashSet<&String> = q.iter().collect();
        let mut best: Option<(String, f32)> = None;
        for (i, _) in top {
            let line = &self.lines[i as usize];
            let mut hits = 0;
            for t in &q {
                if line.contains(t.as_str()) {
                    hits += 1;
                }
            }
            let score = hits as f32 / qset.len() as f32;
            if best.as_ref().map(|(_, s)| score > *s).unwrap_or(true) {
                best = Some((line.clone(), score));
            }
        }
        best.filter(|(_, s)| *s >= 0.3)
    }
}

pub fn load_optional(path: Option<&Path>) -> Option<Retrieval> {
    let p = path?;
    match Retrieval::load(p) {
        Ok(r) if !r.is_empty() => Some(r),
        Ok(_) => None,
        Err(e) => {
            eprintln!("[cv-lm] retrieval load failed: {e}");
            None
        }
    }
}

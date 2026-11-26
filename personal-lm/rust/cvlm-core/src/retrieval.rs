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
    /// 纠错词表（词→权重）：历史词 + 系统英语词典
    spell_words: HashMap<String, u32>,
    /// CJK 单字 → 无调拼音（同音字纠错候选）
    pinyin: HashMap<char, String>,
    /// 拼音 → 字列表（按语料出现顺/频率近似排序）
    pinyin_chars: HashMap<String, Vec<char>>,
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

fn edit_distance(a: &str, b: &str) -> usize {
    let x: Vec<char> = a.chars().collect();
    let y: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=y.len()).collect();
    let mut cur: Vec<usize> = vec![0; y.len() + 1];
    for i in 1..=x.len() {
        cur[0] = i;
        for j in 1..=y.len() {
            let cost = if x[i - 1] == y[j - 1] { 0 } else { 1 };
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[y.len()]
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
        // 纠错资产（可选，缺失不影响主功能）
        let dir = path.parent();
        let mut spell_words = HashMap::new();
        let mut pinyin = HashMap::new();
        let mut pinyin_chars: HashMap<String, Vec<char>> = HashMap::new();
        if let Some(dir) = dir {
            if let Ok(raw) = std::fs::read_to_string(dir.join("spell_words.txt")) {
                for ln in raw.lines() {
                    if let Some((w, n)) = ln.rsplit_once(' ') {
                        if let Ok(n) = n.parse::<u32>() {
                            spell_words.insert(w.to_string(), n);
                        }
                    }
                }
            }
            if let Ok(raw) = std::fs::read_to_string(dir.join("pinyin_map.json")) {
                if let Ok(json) = serde_json::from_str::<HashMap<String, String>>(&raw) {
                    for (ch, py) in json {
                        if let Some(c) = ch.chars().next() {
                            pinyin.insert(c, py.clone());
                            pinyin_chars.entry(py).or_default().push(c);
                        }
                    }
                }
            }
        }
        Ok(Self { lines, postings, words, spell_words, pinyin, pinyin_chars })
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

    /// 输入纠错：word = 刚打完的词（行尾词，拼写未知/有误）。
    /// 返回 (建议, 置信度 0..1)。英语 = 编辑距离 ≤2 的词表最近邻；
    /// CJK = 同音单字替换 + 语料 bigram 链验证。永不改用户文本，只给候选。
    pub fn query_spell(&self, word: &str) -> Option<(String, f32)> {
        let trimmed = word.trim();
        let chars: Vec<char> = trimmed.chars().collect();
        if chars.is_empty() || chars.len() > 12 {
            return None;
        }
        if chars.iter().all(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-') {
            self.spell_latin(trimmed)
        } else {
            self.spell_cjk(trimmed)
        }
    }

    fn spell_latin(&self, word: &str) -> Option<(String, f32)> {
        let w = word.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-')).to_lowercase();
        if w.chars().count() < 4 || w.chars().all(|c| c.is_ascii_digit()) {
            return None; // 过短/纯数字不可靠
        }
        if self.spell_words.contains_key(&w) {
            return None; // 拼写正确（在词表中）→ 不建议
        }
        let wl = w.chars().count();
        let first = w.chars().next()?;
        let mut best: Option<(String, u32, usize)> = None;
        for (cand, weight) in self.spell_words.iter() {
            if cand.chars().next() != Some(first) {
                continue; // 首字母过滤：拼写错误极少换首字母
            }
            let cl = cand.chars().count();
            if cl.abs_diff(wl) > 2 {
                continue;
            }
            let d = edit_distance(&w, cand);
            if d <= 2 && d < wl {
                let score = weight.saturating_mul(100)
                    + 1000 * (3 - d as u32)  // 距离优先
                    + if cand.starts_with(&w[..wl.min(3)]) { 500 } else { 0 };
                if best.as_ref().map(|(_, s, _)| score > *s).unwrap_or(true) {
                    best = Some((cand.clone(), score, d));
                }
            }
        }
        let (cand, _score, d) = best?;
        // 距离 1 → 高置信；距离 2 → 中置信（只在词长 ≥6 时给）
        if d == 2 && wl < 6 {
            return None;
        }
        let conf = if d == 1 { 0.8 } else { 0.5 };
        Some((cand, conf))
    }

    fn spell_cjk(&self, word: &str) -> Option<(String, f32)> {
        let chars: Vec<char> = word.chars().collect();
        if chars.len() < 2 || chars.len() > 4 {
            return None;
        }
        if self.pinyin.is_empty() {
            return None;
        }
        // 用户词任意 bigram 在语料中存在 → 视为拼写正确
        if self.bigram_exists(&chars[0], &chars[1]) {
            return None;
        }
        // 单字同音替换：对每个位置，用同音字替换后验证整词 bigram 链在语料中存在
        let mut best: Option<(String, u64)> = None;
        for pos in 0..chars.len() {
            let py = match self.pinyin.get(&chars[pos]) {
                Some(p) => p.clone(),
                None => continue,
            };
            for cand_ch in self.pinyin_chars.get(&py).into_iter().flatten() {
                if *cand_ch == chars[pos] {
                    continue;
                }
                let mut cand = chars.clone();
                cand[pos] = *cand_ch;
                // 整词 bigram 链验证
                let mut ok = true;
                let mut freq: u64 = u64::MAX;
                for w in cand.windows(2) {
                    if let Some(post) = self.postings.get(&fnv64(&w.iter().collect::<String>())) {
                        freq = freq.min(post.len() as u64);
                    } else {
                        ok = false;
                        break;
                    }
                }
                if ok {
                    let s = format!("{}", cand.iter().collect::<String>());
                    let score = freq.saturating_mul(10)
                        + if pos == chars.len() - 1 { 5 } else { 0 };  // 末字错更常见（同音输入法）
                    if best.as_ref().map(|(_, b)| score > *b).unwrap_or(true) {
                        best = Some((s, score));
                    }
                }
            }
        }
        let (cand, freq) = best?;
        if freq < 2 {
            return None; // 语料频次太低的同音替换不可信
        }
        Some((cand, 0.75))
    }

    fn bigram_exists(&self, a: &char, b: &char) -> bool {
        let mut s = String::new();
        s.push(*a);
        s.push(*b);
        self.postings.contains_key(&fnv64(&s))
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
